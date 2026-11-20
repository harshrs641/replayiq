import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Which frames to send: only changed ones, keyframes on the first frame,
/// on a size change and at least every 30 s (recording API v1, `screen`).
struct FramePolicy {
    static let keyframeInterval: Int64 = 30_000
    private(set) var lastHash: Int?
    private(set) var lastSize: CGSize = .zero
    private(set) var lastKeyframeAt: Int64 = 0
    var forceKeyframe = true

    enum Decision: Equatable { case skip, keyframe, delta }

    func decide(hash: Int, size: CGSize, at ts: Int64) -> Decision {
        if forceKeyframe || size != lastSize || ts - lastKeyframeAt >= FramePolicy.keyframeInterval { return .keyframe }
        return hash == lastHash ? .skip : .delta
    }

    mutating func commit(_ d: Decision, hash: Int, size: CGSize, at ts: Int64) {
        guard d != .skip else { return }
        lastHash = hash
        lastSize = size
        if d == .keyframe {
            lastKeyframeAt = ts
            forceKeyframe = false
        }
    }
}

/// Screenshots the key window at most `maxFramesPerSecond`. Snapshot and
/// masking run on the main thread (UIKit requires it); change detection,
/// JPEG encoding and base64 run on a background queue.
final class ScreenRecorder {
    private let options: ReplayIQOptions
    private var timer: Timer?
    private var busy = false // main thread
    private let encodeQueue = DispatchQueue(label: "io.replayiq.encode", qos: .utility)
    private var policy = FramePolicy() // encodeQueue
    private static let maskColor = UIColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1)

    init(options: ReplayIQOptions) {
        self.options = options
    }

    func start() {
        guard timer == nil else { return }
        let fps = min(2, max(0.2, options.maxFramesPerSecond))
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        timer?.invalidate()
        timer = nil
    }

    func resume() {
        requestKeyframe()
        start()
    }

    func requestKeyframe() {
        encodeQueue.async { self.policy.forceKeyframe = true }
    }

    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive } + scenes.filter { $0.activationState != .foregroundActive }
        for scene in ordered {
            if let w = scene.windows.first(where: { $0.isKeyWindow }) { return w }
        }
        return ordered.first?.windows.first { !$0.isHidden }
    }

    private func tick() {
        guard let recorder = Recorder.shared, recorder.isRecording, !busy,
              UIApplication.shared.applicationState == .active,
              let window = ScreenRecorder.keyWindow() else { return }
        let bounds = window.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return }

        let captureStart = CACurrentMediaTime()
        let masks = Masking.rects(in: window, maskTextInputs: options.maskAllTextInputs, maskAllText: options.maskAllText)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(2, max(0.5, min(options.imageScale, window.screen.scale)))
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
            // Mask before anything is encoded.
            ScreenRecorder.maskColor.setFill()
            for r in masks { ctx.fill(r) }
        }
        guard let cg = image.cgImage else { return }
        Diagnostics.shared.sample("capture_ms", (CACurrentMediaTime() - captureStart) * 1000)
        let ts = RIQ.now()
        let size = bounds.size
        let quality = options.jpegQuality
        busy = true
        encodeQueue.async { [weak self] in
            self?.process(cg, size: size, at: ts, quality: quality)
            DispatchQueue.main.async { self?.busy = false }
        }
    }

    private func process(_ image: CGImage, size: CGSize, at ts: Int64, quality: CGFloat) {
        let hash = ScreenRecorder.fingerprint(image)
        let d = policy.decide(hash: hash, size: size, at: ts)
        guard d != .skip else { return }
        var q = quality
        var jpeg = ScreenRecorder.jpeg(image, quality: q)
        while let j = jpeg, j.count > 1_400_000, q > 0.2 { // base64 must fit the 2 MB event limit
            q -= 0.2
            jpeg = ScreenRecorder.jpeg(image, quality: q)
        }
        guard let data = jpeg else { return }
        policy.commit(d, hash: hash, size: size, at: ts)
        let b64 = "data:image/jpeg;base64," + data.base64EncodedString()
        Diagnostics.shared.add("screen_frames")
        Diagnostics.shared.add("screen_bytes", b64.utf8.count)
        Recorder.shared?.record([
            "type": 5, "subtype": "screen", "timestamp": ts,
            "width": Int(size.width.rounded()), "height": Int(size.height.rounded()),
            "image": b64, "keyframe": d == .keyframe,
        ], bytes: b64.utf8.count + 120)
    }

    /// A hash of every pixel: any visible change makes a new frame.
    static func fingerprint(_ image: CGImage) -> Int {
        var h = Hasher()
        h.combine(image.width)
        h.combine(image.height)
        if let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) {
            h.combine(bytes: UnsafeRawBufferPointer(start: ptr, count: CFDataGetLength(data)))
        }
        return h.finalize()
    }

    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
