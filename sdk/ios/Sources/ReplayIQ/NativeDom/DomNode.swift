import CoreGraphics
import Foundation

/// A node of the Native DOM (recording API v1.1 §1), built on the main thread
/// by `DomWalker` and serialised off it.
struct DomNode {
    enum Kind: String {
        case view, text, image, input, island, scroll, web, mask
    }

    /// Where an image or island's pixels come from; resolved to an asset
    /// hash off the main thread.
    enum Pixels {
        /// An immutable image (layer contents, UIImageView). Keyed by identity.
        case image(CGImage)
        /// Pixels rendered this walk (islands).
        case rendered(CGImage)
        /// Already resolved (unchanged island).
        case hash(String)
    }

    var id: Int
    var kind: Kind
    var frame: CGRect
    var style = DomStyle()
    var role: String?
    var label: String?
    var text: DomText?
    var pixels: Pixels?
    var fit: String?
    var input: DomInput?
    var scrollOffset: CGPoint?
    var hint: String?
    var children: [DomNode] = []
}

struct DomStyle: Equatable {
    var bg: UInt32?
    var radii: [CGFloat]?
    var borderWidth: CGFloat = 0
    var borderColor: UInt32?
    var shadow: (dx: CGFloat, dy: CGFloat, blur: CGFloat, color: UInt32)?
    var opacity: CGFloat = 1
    var transform: CGAffineTransform = .identity
    var clip = false
    var gradient: DomGradient?

    static func == (a: DomStyle, b: DomStyle) -> Bool {
        a.bg == b.bg && a.radii == b.radii && a.borderWidth == b.borderWidth && a.borderColor == b.borderColor
            && a.shadow?.dx == b.shadow?.dx && a.shadow?.dy == b.shadow?.dy && a.shadow?.blur == b.shadow?.blur
            && a.shadow?.color == b.shadow?.color && a.opacity == b.opacity && a.transform == b.transform
            && a.clip == b.clip && a.gradient == b.gradient
    }

    /// Draws nothing by itself.
    var isEmpty: Bool {
        (bg == nil || bg! >> 24 == 0) && borderWidth == 0 && shadow == nil && gradient == nil
    }

    func json() -> [String: Any]? {
        var s: [String: Any] = [:]
        if let bg, bg >> 24 != 0 { s["bg"] = DomColor.hex(bg) }
        if let radii, radii.contains(where: { $0 > 0 }) { s["r"] = radii.map { DomColor.round($0) } }
        if borderWidth > 0, let borderColor, borderColor >> 24 != 0 {
            s["bw"] = DomColor.round(borderWidth)
            s["bc"] = DomColor.hex(borderColor)
        }
        if let sh = shadow {
            s["sh"] = [DomColor.round(sh.dx), DomColor.round(sh.dy), DomColor.round(sh.blur), 0, DomColor.hex(sh.color)]
        }
        if opacity < 0.999 { s["o"] = DomColor.round(opacity, 100) }
        if transform != .identity {
            let t = transform
            s["t"] = [t.a, t.b, t.c, t.d, t.tx, t.ty].map { DomColor.round($0, 1000) }
        }
        if clip { s["clip"] = true }
        if let gradient { s["grad"] = gradient.json() }
        return s.isEmpty ? nil : s
    }
}

struct DomGradient: Equatable {
    var radial: Bool
    var angle: CGFloat
    var stops: [(UInt32, CGFloat)]

    static func == (a: DomGradient, b: DomGradient) -> Bool {
        a.radial == b.radial && a.angle == b.angle && a.stops.map(\.0) == b.stops.map(\.0) && a.stops.map(\.1) == b.stops.map(\.1)
    }

    func json() -> [String: Any] {
        ["type": radial ? "radial" : "linear", "angle": DomColor.round(angle),
         "stops": stops.map { [DomColor.hex($0.0), DomColor.round($0.1, 1000)] as [Any] }]
    }
}

struct DomText: Equatable {
    var value: String
    var font: String
    var size: CGFloat
    var weight: Int
    var italic: Bool
    var color: UInt32
    var align: String
    var lineHeight: CGFloat
    var maxLines: Int

    func json() -> [String: Any] {
        var t: [String: Any] = ["v": value, "font": font, "size": DomColor.round(size), "w": weight,
                                "col": DomColor.hex(color), "al": align]
        if italic { t["i"] = true }
        if lineHeight > 0 { t["lh"] = DomColor.round(lineHeight) }
        if maxLines > 0 { t["ml"] = maxLines }
        return t
    }
}

struct DomInput: Equatable {
    var type: String
    var placeholder: String?
    var length: Int?
    var focus: Bool
    /// How the field draws its text (its value is left empty).
    var style: DomText? = nil
    /// Placeholder colour.
    var placeholderColor: UInt32? = nil
    /// A secure field has content (its length is never sent).
    var filled = false
    /// Text insets within the frame: left, right.
    var pad: (CGFloat, CGFloat)? = nil

    static func == (a: DomInput, b: DomInput) -> Bool {
        a.type == b.type && a.placeholder == b.placeholder && a.length == b.length && a.focus == b.focus
            && a.style == b.style && a.placeholderColor == b.placeholderColor
            && a.filled == b.filled && a.pad?.0 == b.pad?.0 && a.pad?.1 == b.pad?.1
    }

    func json() -> [String: Any] {
        var i: [String: Any] = ["type": type]
        if let placeholder, !placeholder.isEmpty { i["ph"] = placeholder }
        if let length { i["len"] = length }
        if focus { i["focus"] = true }
        if let style {
            var t = style.json()
            t.removeValue(forKey: "v")
            t.removeValue(forKey: "lh")
            t.removeValue(forKey: "ml")
            i["tx"] = t
        }
        if let placeholderColor { i["pc"] = DomColor.hex(placeholderColor) }
        if filled { i["filled"] = true }
        if let pad { i["pad"] = [DomColor.round(pad.0), DomColor.round(pad.1)] }
        return i
    }
}

enum DomColor {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `#AARRGGBB` as a packed integer, or nil for no colour.
    private static var cache: [ObjectIdentifier: (CGColor, UInt32?)] = [:]
    private static let cacheLock = NSLock()

    /// Cached by colour identity (UI colours are long-lived objects).
    static func argb(_ c: CGColor?) -> UInt32? {
        guard let c else { return nil }
        let key = ObjectIdentifier(c)
        cacheLock.lock()
        if let hit = cache[key], hit.0 === c { cacheLock.unlock(); return hit.1 }
        cacheLock.unlock()
        let v = convert(c)
        cacheLock.lock()
        if cache.count > 1024 { cache.removeAll() }
        cache[key] = (c, v)
        cacheLock.unlock()
        return v
    }

    private static func convert(_ c: CGColor) -> UInt32? {
        var comps = c.components ?? []
        let name = c.colorSpace?.name
        let direct = c.colorSpace?.model == .rgb && (name == CGColorSpace.sRGB || name == CGColorSpace.extendedSRGB)
        if comps.count == 2, c.colorSpace?.model == .monochrome { // grey + alpha: common, skip a conversion
            comps = [comps[0], comps[0], comps[0], comps[1]]
        } else if !direct || comps.count < 4 {
            comps = c.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? []
        }
        guard comps.count >= 4 else { return nil }
        func b(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return b(comps[3]) << 24 | b(comps[0]) << 16 | b(comps[1]) << 8 | b(comps[2])
    }

    static func hex(_ v: UInt32) -> String { String(format: "#%08X", v) }

    /// Rounds to 1/`scale` so float noise doesn't produce updates.
    static func round(_ v: CGFloat, _ scale: CGFloat = 10) -> Double {
        guard v.isFinite else { return 0 }
        return Double((v * scale).rounded() / scale)
    }
}
