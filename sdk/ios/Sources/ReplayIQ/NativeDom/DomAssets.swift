import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Asset hashes the server already has (per ingest key), remembered on disk,
/// plus the ones queued for upload in this run.
final class AssetRegistry {
    private let url: URL
    private var known: Set<String>
    private var pending = Set<String>()
    private let lock = NSLock()

    init(dir: URL, key: String) {
        let safe = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        url = dir.appendingPathComponent("assets-\(safe).txt")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        known = Set(text.split(separator: "\n").map(String.init))
    }

    var dirForTests: URL { url.deletingLastPathComponent() }

    func isKnown(_ hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return known.contains(hash)
    }

    /// True when the caller should queue the upload (not known, not queued).
    func claim(_ hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if known.contains(hash) || pending.contains(hash) { return false }
        pending.insert(hash)
        return true
    }

    func markUploaded(_ hash: String) {
        lock.lock()
        let isNew = known.insert(hash).inserted
        pending.remove(hash)
        lock.unlock()
        guard isNew else { return }
        if let h = FileHandle(forWritingAtPath: url.path) {
            h.seekToEndOfFile()
            h.write(Data((hash + "\n").utf8))
            h.closeFile()
        } else {
            try? Data((hash + "\n").utf8).write(to: url)
        }
    }
}

/// Turns walker pixels into asset hashes, encoding and queueing each new
/// image once. Runs on the DOM queue only.
final class DomAssets {
    struct Encoded {
        let hash: String
        let type: String
        let data: Data
    }

    private var byImage: [ObjectIdentifier: (image: CGImage, hash: String)] = [:]
    private var byOrder: [ObjectIdentifier] = []
    private var byPixels: [String: String] = [:]
    private let registry: AssetRegistry?
    private let upload: (Encoded) -> Void
    private(set) var uploadedBytes = 0
    private(set) var uploadedCount = 0

    init(registry: AssetRegistry?, upload: @escaping (Encoded) -> Void) {
        self.registry = registry
        self.upload = upload
    }

    /// The asset hash for a node's pixels; queues the upload when new.
    /// `points` is the node size: images are sent at ≤ 1x of it.
    func hash(_ pixels: DomNode.Pixels, points: CGSize) -> String? {
        switch pixels {
        case let .hash(h):
            return h
        case let .image(img):
            let key = ObjectIdentifier(img)
            if let c = byImage[key], c.image === img { return c.hash }
            let scaled = DomAssets.downscale(img, to: points)
            guard let enc = DomAssets.encode(scaled) else { return nil }
            remember(img, enc.hash)
            send(enc)
            return enc.hash
        case let .rendered(img):
            let key = ObjectIdentifier(img)
            if let c = byImage[key], c.image === img { return c.hash }
            let raw = DomAssets.pixelHash(img)
            if let raw, let h = byPixels[raw] {
                remember(img, h)
                return h
            }
            guard let enc = DomAssets.encode(img) else { return nil }
            if let raw { byPixels[raw] = enc.hash }
            if byPixels.count > 2000 { byPixels.removeAll() }
            remember(img, enc.hash)
            send(enc)
            return enc.hash
        }
    }

    private func remember(_ img: CGImage, _ hash: String) {
        let key = ObjectIdentifier(img)
        if byImage[key] == nil { byOrder.append(key) }
        // Holding the image keeps its identity from being reused.
        byImage[key] = (img, hash)
        if byOrder.count > 400 {
            for k in byOrder.prefix(100) { byImage.removeValue(forKey: k) }
            byOrder.removeFirst(100)
        }
    }

    private func send(_ enc: Encoded) {
        if let registry, !registry.claim(enc.hash) { return }
        uploadedBytes += enc.data.count
        uploadedCount += 1
        upload(enc)
    }

    static func pixelHash(_ img: CGImage) -> String? {
        guard let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        var h = SHA256()
        h.update(bufferPointer: UnsafeRawBufferPointer(start: ptr, count: CFDataGetLength(data)))
        withUnsafeBytes(of: (img.width, img.height)) { h.update(bufferPointer: $0) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Scales an image down to `points` pixels (1x), never up.
    static func downscale(_ img: CGImage, to points: CGSize) -> CGImage {
        let tw = Int(points.width.rounded(.up)), th = Int(points.height.rounded(.up))
        guard tw > 0, th > 0, img.width > tw || img.height > th else { return img }
        let s = min(CGFloat(tw) / CGFloat(img.width), CGFloat(th) / CGFloat(img.height))
        let w = max(1, Int((CGFloat(img.width) * s).rounded())), h = max(1, Int((CGFloat(img.height) * s).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: (hasAlpha(img) ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// PNG for images with transparency or small ones, JPEG otherwise; ≤ 2 MB.
    static func encode(_ img: CGImage) -> Encoded? {
        let png = hasAlpha(img) || img.width * img.height <= 128 * 128
        var data = write(img, type: png ? UTType.png : UTType.jpeg, quality: 0.8)
        var type = png ? "image/png" : "image/jpeg"
        if let d = data, d.count > 1_900_000 {
            data = write(img, type: .jpeg, quality: 0.5)
            type = "image/jpeg"
        }
        guard let d = data, d.count <= 2_000_000 else { return nil }
        return Encoded(hash: sha256(d), type: type, data: d)
    }

    private static func write(_ img: CGImage, type: UTType, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
