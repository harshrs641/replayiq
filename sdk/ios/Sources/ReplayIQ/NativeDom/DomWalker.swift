import QuartzCore
import UIKit

private var nodeIDKey: UInt8 = 0
private var auxIDKey: UInt8 = 0

/// Walks the key window's CALayer tree (UIKit and SwiftUI both render into
/// it) and describes it as `DomNode`s. Main thread only; reads properties and
/// renders the few islands that changed, nothing else: hashing, encoding,
/// diffing and serialising happen off the main thread.
final class DomWalker {
    struct Result {
        var root: DomNode
        var width: CGFloat
        var height: CGFloat
        var bg: UInt32
        /// Share of the screen covered by islands (0–1).
        var islandRatio: CGFloat
        /// Something is animating or scrolling: keep walking at full rate.
        var moving: Bool
        /// Islands are waiting to be rendered.
        var deferred: Bool
        var nodeCount: Int
        var duration: CFTimeInterval
    }

    private struct IslandState {
        var contents: ObjectIdentifier?
        var size: CGSize
        var renderedAt: CFTimeInterval
        var image: CGImage?
        var label: String?
    }

    private static var nextID = 1
    private let options: ReplayIQOptions
    private var islands: [Int: IslandState] = [:]
    private var seenIslands = Set<Int>()

    // Per walk.
    private var windowBounds: CGRect = .zero
    private var window: UIWindow?
    private var now: CFTimeInterval = 0
    private var islandArea: CGFloat = 0
    private var moving = false
    private var count = 0
    private var maskRects: [CGRect] = []
    private var contentRects: [(Int, CGRect)] = []
    private var revalidations = 0
    private var renderTime: CFTimeInterval = 0
    private var renders = 0

    /// Islands re-render at most this often (spec: ≤ 2/s per island).
    static let islandInterval: CFTimeInterval = 0.5
    /// Unchanged-looking islands are re-checked after this long (SwiftUI may
    /// redraw a layer's backing store in place).
    static let revalidateAfter: CFTimeInterval = 3
    static let revalidationsPerWalk = 1
    /// Main-thread time per walk for re-rendering changed islands; the rest
    /// wait for the next walk (new islands get up to `newIslandBudget`).
    static let renderBudget: CFTimeInterval = 0.0008
    static let newIslandBudget: CFTimeInterval = 0.004
    /// Set when islands were deferred: the recorder walks again soon.
    private(set) var deferred = false

    init(options: ReplayIQOptions) {
        self.options = options
    }

    // MARK: - Ids

    /// The layer's node id: stable for the layer's lifetime, never reused.
    static func id(_ layer: CALayer, aux: Bool = false) -> Int {
        let key = aux ? UnsafeRawPointer(&auxIDKey) : UnsafeRawPointer(&nodeIDKey)
        if let n = objc_getAssociatedObject(layer, key) as? NSNumber { return n.intValue }
        let id = nextID
        nextID += 1
        objc_setAssociatedObject(layer, key, NSNumber(value: id), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return id
    }

    // MARK: - Walk

    func walk(_ window: UIWindow) -> Result {
        let start = CACurrentMediaTime()
        self.window = window
        windowBounds = window.bounds
        now = start
        islandArea = 0
        moving = false
        count = 0
        maskRects = []
        contentRects = []
        revalidations = 0
        renderTime = 0
        renders = 0
        deferred = false
        seenIslands.removeAll(keepingCapacity: true)

        let layer = window.layer
        var root = DomNode(id: DomWalker.id(layer), kind: .view, frame: CGRect(origin: .zero, size: windowBounds.size))
        root.style.bg = DomColor.argb(layer.backgroundColor)
        for sub in layer.sublayers ?? [] {
            visit(sub, base: .zero, win: .zero, host: window, into: &root.children)
        }
        // Content under a mask (e.g. SwiftUI views under `.replayIQMask()`,
        // which overlays them) is never sent.
        if !maskRects.isEmpty {
            var strip = Set<Int>()
            for (id, r) in contentRects where maskRects.contains(where: { $0.intersects(r) }) { strip.insert(id) }
            if !strip.isEmpty { root = DomWalker.strip(root, strip) }
        }
        islands = islands.filter { seenIslands.contains($0.key) }
        if renders > 0 {
            Diagnostics.shared.sample("island_render_ms", renderTime * 1000)
            Diagnostics.shared.add("island_renders", renders)
        }
        let area = max(1, windowBounds.width * windowBounds.height)
        let bg = DomColor.argb(layer.backgroundColor) ?? 0xFFFF_FFFF
        return Result(root: root, width: windowBounds.width, height: windowBounds.height,
                      bg: bg >> 24 == 0 ? 0xFFFF_FFFF : bg,
                      islandRatio: min(1, islandArea / area), moving: moving, deferred: deferred, nodeCount: count,
                      duration: CACurrentMediaTime() - start)
    }

    private static func strip(_ node: DomNode, _ ids: Set<Int>) -> DomNode {
        var n = node
        n.children = n.children.filter { !ids.contains($0.id) }.map { strip($0, ids) }
        return n
    }

    /// Visits `layer`. `base` is where its superlayer's coordinate space
    /// starts in the emitted parent's content box, `win` the same in window
    /// coordinates. Emits one node, or the layer's children when the layer
    /// draws nothing itself (collapsed).
    private func visit(_ layer: CALayer, base: CGPoint, win: CGPoint, host: UIView, into out: inout [DomNode]) {
        let animated = layer.animationKeys().map { !$0.isEmpty } ?? false
        if animated { moving = true }
        let g = animated ? (layer.presentation() ?? layer) : layer
        if g.isHidden || g.opacity < 0.01 { return }
        if layer.isPortal { return }

        let size = g.bounds.size
        let origin = CGPoint(x: g.position.x - g.anchorPoint.x * size.width, y: g.position.y - g.anchorPoint.y * size.height)
        let frame = CGRect(x: base.x + origin.x, y: base.y + origin.y, width: size.width, height: size.height)
        let winRect = CGRect(x: win.x + origin.x, y: win.y + origin.y, width: size.width, height: size.height)
        let sublayers = layer.sublayers ?? []
        let transform = DomWalker.transform(g, size: size)
        if transform == .identity, !winRect.intersects(windowBounds.insetBy(dx: -40, dy: -40)),
           sublayers.isEmpty || g.masksToBounds { return }
        if size.width <= 0 || size.height <= 0, sublayers.isEmpty || g.masksToBounds { return }

        let view: UIView? = (layer.delegate as? UIView).flatMap { $0.layer === layer ? $0 : nil }
        if let view, DomWalker.isPortal(view) { return }
        let host = view ?? host
        count += 1

        var node = DomNode(id: DomWalker.id(layer), kind: .view, frame: frame)
        node.style = style(g, size: size)
        node.style.transform = transform
        let childBase = CGPoint(x: -g.bounds.origin.x, y: -g.bounds.origin.y)
        let childWin = CGPoint(x: winRect.minX - g.bounds.origin.x, y: winRect.minY - g.bounds.origin.y)

        // Views with their own meaning.
        if let view {
            if view.replayIQMasked {
                node.kind = .mask
                node.style = DomStyle(radii: node.style.radii, opacity: node.style.opacity, transform: transform)
                maskRects.append(winRect)
                out.append(node)
                return
            }
            if let input = DomWalker.input(view) {
                node.kind = .input
                // UIKit draws the rounded border in subviews, which are never
                // walked (they hold the value): describe it here.
                if let tf = view as? UITextField, tf.borderStyle == .roundedRect, node.style.borderWidth == 0 {
                    node.style.radii = [5, 5, 5, 5]
                    node.style.borderWidth = 0.5
                    node.style.borderColor = DomColor.argb(UIColor.separator.resolvedColor(with: tf.traitCollection).cgColor)
                    if node.style.bg == nil {
                        node.style.bg = DomColor.argb(UIColor.systemBackground.resolvedColor(with: tf.traitCollection).cgColor)
                    }
                }
                node.input = input
                node.role = input.type == "password" ? "password" : "textfield"
                node.label = ElementSelector.clean(view.accessibilityLabel)
                contentRects.append((node.id, winRect))
                out.append(node)
                return
            }
            if let label = view as? UILabel {
                if options.maskAllText { node.kind = .mask; maskRects.append(winRect) } else {
                    node.kind = .text
                    node.text = DomWalker.text(label)
                    contentRects.append((node.id, winRect))
                }
                out.append(node)
                return
            }
            if let tv = view as? UITextView {
                if options.maskAllText { node.kind = .mask; maskRects.append(winRect) } else {
                    node.kind = .text
                    node.text = DomWalker.text(tv)
                    contentRects.append((node.id, winRect))
                }
                out.append(node)
                return
            }
            if let hint = DomWalker.islandHint(view: view, layer: layer) {
                specialIsland(view, hint: hint, node: &node, winRect: winRect)
                out.append(node)
                return
            }
            if let iv = view as? UIImageView {
                node.kind = .image
                node.fit = DomWalker.fit(iv.contentMode)
                if let img = iv.image {
                    if img.renderingMode == .alwaysTemplate || img.isSymbolImage || img.cgImage == nil {
                        node.pixels = renderedPixels(layer, id: node.id, size: size, countArea: false, host: host, winRect: winRect)
                    } else if let cg = img.cgImage {
                        node.pixels = .image(cg)
                    }
                }
                contentRects.append((node.id, winRect))
                // Image views may have subviews (badges): keep them.
                if !sublayers.isEmpty {
                    wrapContent(&node, layer: layer)
                    for s in sublayers { visit(s, base: childBase, win: childWin, host: host, into: &node.children) }
                }
                out.append(node)
                return
            }
            if let sv = view as? UIScrollView {
                scroll(sv, g: g, node: &node, winRect: winRect, host: host)
                out.append(node)
                return
            }
            if view.isAccessibilityElement {
                node.role = ElementSelector.role(of: view)
                if node.role == "view" { node.role = nil }
                node.label = ElementSelector.label(of: view)
            }
        } else if let hint = DomWalker.islandHint(view: nil, layer: layer) {
            node.kind = .island
            node.hint = hint
            islandArea += winRect.intersection(windowBounds).area
            out.append(node)
            return
        }

        // Layers that draw content.
        if let t = layer as? CATextLayer {
            node.kind = .text
            node.text = DomWalker.text(t)
            if options.maskAllText { node.kind = .mask; node.text = nil; maskRects.append(winRect) }
            contentRects.append((node.id, winRect))
        } else if let gl = layer as? CAGradientLayer {
            node.style.gradient = DomWalker.gradient(gl)
        } else if layer.isBackdrop {
            // Blur/vibrancy: approximated by a translucent fill.
            let dark = host.traitCollection.userInterfaceStyle == .dark
            if node.style.bg == nil || node.style.bg! >> 24 == 0 { node.style.bg = dark ? 0xD91C_1C1E : 0xD9F2_F2F7 }
        } else if let contents = layer.contents {
            let cf = contents as CFTypeRef
            if CFGetTypeID(cf) == CGImage.typeID {
                node.kind = .image
                node.pixels = .image(contents as! CGImage)
                node.fit = DomWalker.fit(layer.contentsGravity)
            } else {
                let textLike = DomWalker.isDrawingLayer(layer)
                if textLike && options.maskAllText {
                    node.kind = .mask
                    maskRects.append(winRect)
                    out.append(node)
                    return
                }
                node.kind = .island
                node.pixels = renderedPixels(layer, id: node.id, size: size, countArea: true, host: host, winRect: winRect)
                node.label = islands[node.id]?.label
                // Not rendered yet (budget): an empty box until it is.
                if node.pixels == nil { node.kind = .view }
            }
            contentRects.append((node.id, winRect))
        } else if let shape = layer as? CAShapeLayer, shape.path != nil {
            node.kind = .island
            node.pixels = renderedPixels(layer, id: node.id, size: size, countArea: true, host: host, winRect: winRect)
            if node.pixels == nil { node.kind = .view }
            contentRects.append((node.id, winRect))
        }

        if node.kind == .image || node.kind == .island || node.kind == .text {
            if sublayers.isEmpty || node.kind == .text {
                out.append(node)
                return
            }
            wrapContent(&node, layer: layer)
        }

        // A plain layer that draws nothing: hoist its children.
        if node.kind == .view, node.style.isEmpty, node.style.opacity >= 0.999, transform == .identity,
           !g.masksToBounds, g.bounds.origin == .zero, node.role == nil, node.label == nil {
            count -= 1
            let hoistBase = CGPoint(x: frame.minX, y: frame.minY)
            for s in sublayers { visit(s, base: hoistBase, win: CGPoint(x: winRect.minX, y: winRect.minY), host: host, into: &out) }
            return
        }
        for s in sublayers { visit(s, base: childBase, win: childWin, host: host, into: &node.children) }
        out.append(node)
    }

    /// An image/island layer that also has sublayers: the pixels move to a
    /// child (an <img> has no children) and the node becomes a view.
    private func wrapContent(_ node: inout DomNode, layer: CALayer) {
        var content = DomNode(id: DomWalker.id(layer, aux: true), kind: node.kind, frame: CGRect(origin: .zero, size: node.frame.size))
        content.pixels = node.pixels
        content.fit = node.fit
        content.text = node.text
        content.label = node.label
        content.style.radii = node.style.radii
        if content.pixels == nil, content.kind == .island || content.kind == .image { content.kind = .view }
        node.kind = .view
        node.pixels = nil
        node.text = nil
        node.children.insert(content, at: 0)
    }

    private func scroll(_ sv: UIScrollView, g: CALayer, node: inout DomNode, winRect: CGRect, host: UIView) {
        node.kind = .scroll
        node.role = sv is UITableView || sv is UICollectionView ? "list" : "scroll"
        node.label = ElementSelector.clean(sv.accessibilityLabel)
        if sv.isDragging || sv.isDecelerating || sv.isTracking { moving = true }
        let inset = sv.adjustedContentInset
        let offset = g.bounds.origin
        // Browsers can't scroll to negative offsets: content coordinates are
        // shifted by the insets so the offset stays ≥ 0.
        node.scrollOffset = CGPoint(x: max(0, offset.x + inset.left), y: max(0, offset.y + inset.top))
        let shift = CGPoint(x: inset.left, y: inset.top)
        let content = sv.contentSize
        // An empty node as large as the content, so the replay can scroll as far.
        node.children.append(DomNode(id: DomWalker.id(sv.layer, aux: true), kind: .view,
                                     frame: CGRect(x: 0, y: 0, width: max(winRect.width, content.width + inset.left + inset.right),
                                                   height: max(winRect.height, content.height + inset.top + inset.bottom))))
        let childWin = CGPoint(x: winRect.minX - offset.x, y: winRect.minY - offset.y)
        for s in sv.layer.sublayers ?? [] {
            visit(s, base: shift, win: childWin, host: sv, into: &node.children)
        }
    }

    // MARK: - Islands

    /// Pixels of a layer that can't be described (custom drawing, shapes,
    /// SwiftUI text), re-rendered only when its contents change (≤ 2/s).
    private func renderedPixels(_ layer: CALayer, id: Int, size: CGSize, countArea: Bool, host: UIView, winRect: CGRect) -> DomNode.Pixels? {
        seenIslands.insert(id)
        if countArea { islandArea += winRect.intersection(windowBounds).area }
        guard size.width >= 1, size.height >= 1, size.width * size.height <= 4_000_000 else { return nil }
        let contents = layer.contents.map { ObjectIdentifier($0 as AnyObject) }
        if var st = islands[id], let img = st.image {
            let same = st.contents == contents && st.size == size
            let tooSoon = now - st.renderedAt < DomWalker.islandInterval
            let stale = now - st.renderedAt > DomWalker.revalidateAfter && revalidations < DomWalker.revalidationsPerWalk
            if tooSoon || (same && !stale) { return .image(img) }
            if renderTime > DomWalker.renderBudget { deferred = true; return .image(img) }
            if same { revalidations += 1 }
            st.renderedAt = now
            islands[id] = st
        } else if renderTime > DomWalker.newIslandBudget {
            deferred = true
            return nil
        }
        let renderStart = CACurrentMediaTime()
        defer { renderTime += CACurrentMediaTime() - renderStart; renders += 1 }
        // Text-sized islands render at 2x so replays stay legible; larger ones at 1x.
        let scale: CGFloat = size.width * size.height < 40_000 ? min(2, UIScreen.main.scale) : 1
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            layer.render(in: ctx.cgContext)
        }
        guard let cg = image.cgImage else { return nil }
        var label = islands[id]?.label
        if islands[id] == nil || islands[id]?.contents != contents {
            let axStart = CACurrentMediaTime()
            label = DomWalker.axLabel(at: CGPoint(x: winRect.midX, y: winRect.midY), in: host, window: window)
            Diagnostics.shared.sample("ax_ms", (CACurrentMediaTime() - axStart) * 1000)
        }
        islands[id] = IslandState(contents: contents, size: size, renderedAt: now, image: cg, label: label)
        return .rendered(cg)
    }

    /// Maps, video, web and GPU views: captured from the screen (masks painted
    /// over), at most 2/s; a labelled box when nothing can be captured.
    private func specialIsland(_ view: UIView, hint: String, node: inout DomNode, winRect: CGRect) {
        node.kind = .island
        node.hint = hint
        node.label = ElementSelector.clean(view.accessibilityLabel)
        islandArea += winRect.intersection(windowBounds).area
        seenIslands.insert(node.id)
        contentRects.append((node.id, winRect))
        if hint == "camera" { return } // never capture a camera feed
        if let st = islands[node.id], let img = st.image, now - st.renderedAt < DomWalker.islandInterval {
            node.pixels = .image(img)
            return
        }
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1, let window else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let masks = Masking.rects(in: window, maskTextInputs: true, maskAllText: options.maskAllText)
            .filter { $0.intersects(winRect) }
            .map { window.convert($0, to: view) }
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            view.drawHierarchy(in: bounds, afterScreenUpdates: false)
            UIColor.gray.setFill()
            for r in masks { ctx.fill(r) }
        }
        guard let cg = image.cgImage else { return }
        islands[node.id] = IslandState(contents: nil, size: bounds.size, renderedAt: now, image: cg, label: node.label)
        node.pixels = .rendered(cg)
    }

    static func islandHint(view: UIView?, layer: CALayer) -> String? {
        if let view, let h = ClassFlags.of(type(of: view)).islandHint { return h }
        return ClassFlags.of(type(of: layer)).islandHint
    }

    static func isDrawingLayer(_ layer: CALayer) -> Bool { ClassFlags.of(type(of: layer)).drawing }

    static func isPortal(_ view: UIView) -> Bool { ClassFlags.of(type(of: view)).portal }

    /// The accessibility label of the element at a window point (SwiftUI
    /// text drawn into layers has no string otherwise).
    static func axLabel(at point: CGPoint, in host: UIView, window: UIWindow?) -> String? {
        guard let window else { return nil }
        let global: UICoordinateSpace = window.screen.coordinateSpace
        let p = window.coordinateSpace.convert(point, to: global)
        var container: UIView? = host
        var depth = 0
        while let c = container, depth < 4 {
            if let el = ElementSelector.element(at: p, in: c, depth: 0), let l = ElementSelector.clean(el.accessibilityLabel) {
                return l
            }
            container = c.superview
            depth += 1
        }
        return nil
    }

    // MARK: - Properties

    func style(_ g: CALayer, size: CGSize) -> DomStyle {
        var s = DomStyle()
        s.bg = DomColor.argb(g.backgroundColor)
        if g.cornerRadius > 0 {
            let r = min(g.cornerRadius, min(size.width, size.height) / 2)
            let m = g.maskedCorners
            s.radii = [m.contains(.layerMinXMinYCorner) ? r : 0, m.contains(.layerMaxXMinYCorner) ? r : 0,
                       m.contains(.layerMaxXMaxYCorner) ? r : 0, m.contains(.layerMinXMaxYCorner) ? r : 0]
        }
        if g.borderWidth > 0 {
            s.borderWidth = g.borderWidth
            s.borderColor = DomColor.argb(g.borderColor)
        }
        if g.shadowOpacity > 0, let c = DomColor.argb(g.shadowColor) {
            let a = UInt32((Float(c >> 24) * g.shadowOpacity).rounded())
            if a > 0 {
                s.shadow = (g.shadowOffset.width, g.shadowOffset.height, g.shadowRadius * 2, (a << 24) | (c & 0xFF_FFFF))
            }
        }
        s.opacity = CGFloat(g.opacity)
        s.clip = g.masksToBounds
        return s
    }

    /// The layer's 2D transform about its centre (CSS's default origin).
    static func transform(_ g: CALayer, size: CGSize) -> CGAffineTransform {
        if CATransform3DIsIdentity(g.transform) { return .identity }
        var t = CATransform3DGetAffineTransform(g.transform)
        // CA transforms about the anchor point; move that to the centre.
        let dx = (g.anchorPoint.x - 0.5) * size.width
        let dy = (g.anchorPoint.y - 0.5) * size.height
        t.tx += dx - (t.a * dx + t.c * dy)
        t.ty += dy - (t.b * dx + t.d * dy)
        return t
    }

    static func fit(_ mode: UIView.ContentMode) -> String {
        switch mode {
        case .scaleToFill: return "fill"
        case .scaleAspectFit: return "contain"
        case .scaleAspectFill: return "cover"
        default: return "none"
        }
    }

    static func fit(_ gravity: CALayerContentsGravity) -> String {
        switch gravity {
        case .resize: return "fill"
        case .resizeAspect: return "contain"
        case .resizeAspectFill: return "cover"
        default: return "none"
        }
    }

    static func gradient(_ gl: CAGradientLayer) -> DomGradient? {
        let colors = (gl.colors ?? []).compactMap { DomColor.argb(($0 as! CGColor)) }
        guard !colors.isEmpty else { return nil }
        let locs = gl.locations?.map { CGFloat($0.doubleValue) }
            ?? colors.indices.map { colors.count == 1 ? 0 : CGFloat($0) / CGFloat(colors.count - 1) }
        let dx = gl.endPoint.x - gl.startPoint.x
        let dy = gl.endPoint.y - gl.startPoint.y
        let angle = atan2(dx, -dy) * 180 / .pi // CSS: 0deg points up, 90deg right
        return DomGradient(radial: gl.type == .radial, angle: angle < 0 ? angle + 360 : angle,
                           stops: zip(colors, locs).map { ($0, $1) })
    }

    static func input(_ view: UIView) -> DomInput? {
        if let tf = view as? UITextField {
            return DomInput(type: tf.isSecureTextEntry ? "password" : keyboardType(tf.keyboardType),
                            placeholder: tf.placeholder ?? tf.attributedPlaceholder?.string,
                            length: tf.isSecureTextEntry ? nil : (tf.text?.count).flatMap { $0 > 0 ? $0 : nil },
                            focus: tf.isFirstResponder)
        }
        if let tv = view as? UITextView, tv.isEditable {
            return DomInput(type: tv.isSecureTextEntry ? "password" : "textarea", placeholder: nil,
                            length: tv.isSecureTextEntry ? nil : (tv.text.isEmpty ? nil : tv.text.count),
                            focus: tv.isFirstResponder)
        }
        return nil
    }

    static func keyboardType(_ k: UIKeyboardType) -> String {
        switch k {
        case .emailAddress: return "email"
        case .numberPad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad: return "number"
        case .phonePad, .namePhonePad: return "tel"
        case .URL, .webSearch: return "url"
        default: return "text"
        }
    }

    static func text(_ l: UILabel) -> DomText {
        let attributed = l.attributedText
        var font = l.font ?? UIFont.systemFont(ofSize: 17)
        var color = l.textColor ?? .label
        if let a = attributed, a.length > 0 {
            if let f = a.attribute(.font, at: 0, effectiveRange: nil) as? UIFont { font = f }
            if let c = a.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor { color = c }
        }
        if !l.isEnabled { color = .secondaryLabel }
        return text(value: attributed?.string ?? l.text ?? "", font: font,
                    color: color.resolvedColor(with: l.traitCollection).cgColor,
                    alignment: l.textAlignment, rtl: l.effectiveUserInterfaceLayoutDirection == .rightToLeft,
                    lines: l.numberOfLines)
    }

    static func text(_ tv: UITextView) -> DomText {
        let font = tv.font ?? UIFont.preferredFont(forTextStyle: .body)
        return text(value: tv.attributedText?.string ?? tv.text ?? "", font: font,
                    color: (tv.textColor ?? .label).resolvedColor(with: tv.traitCollection).cgColor,
                    alignment: tv.textAlignment, rtl: tv.effectiveUserInterfaceLayoutDirection == .rightToLeft, lines: 0)
    }

    static func text(_ t: CATextLayer) -> DomText {
        let value: String
        if let s = t.string as? String { value = s } else if let a = t.string as? NSAttributedString { value = a.string } else { value = "" }
        var font = UIFont.systemFont(ofSize: t.fontSize)
        if let name = t.font as? String, let f = UIFont(name: name, size: t.fontSize) { font = f }
        let align: NSTextAlignment
        switch t.alignmentMode {
        case .center: align = .center
        case .right: align = .right
        case .justified: align = .justified
        default: align = .left
        }
        return text(value: value, font: font, color: t.foregroundColor ?? UIColor.black.cgColor, alignment: align, rtl: false,
                    lines: t.isWrapped ? 0 : 1)
    }

    static func text(value: String, font: UIFont, color: CGColor, alignment: NSTextAlignment, rtl: Bool, lines: Int) -> DomText {
        let traits = font.fontDescriptor.symbolicTraits
        var weight = traits.contains(.traitBold) ? 700 : 400
        if let t = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any],
           let w = t[.weight] as? CGFloat {
            weight = cssWeight(w)
        }
        let al: String
        switch alignment {
        case .center: al = "center"
        case .right: al = "right"
        case .justified: al = "justify"
        case .natural: al = rtl ? "right" : "left"
        default: al = "left"
        }
        return DomText(value: value, font: font.familyName, size: font.pointSize, weight: weight,
                       italic: traits.contains(.traitItalic), color: DomColor.argb(color) ?? 0xFF00_0000,
                       align: al, lineHeight: font.lineHeight, maxLines: lines)
    }

    /// UIFont.Weight (-1…1) to CSS 100–900.
    static func cssWeight(_ w: CGFloat) -> Int {
        let table: [(CGFloat, Int)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500),
                                       (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)]
        return table.min(by: { abs($0.0 - w) < abs($1.0 - w) })!.1
    }
}

/// Facts about a class, looked up by name once (private classes are never linked).
struct ClassFlags {
    var portal = false
    var backdrop = false
    var drawing = false
    var islandHint: String?

    private static var cache: [ObjectIdentifier: ClassFlags] = [:]

    /// Main thread only.
    static func of(_ cls: AnyClass) -> ClassFlags {
        let key = ObjectIdentifier(cls)
        if let f = cache[key] { return f }
        let name = NSStringFromClass(cls)
        var f = ClassFlags()
        f.portal = name == "CAPortalLayer" || name.contains("PortalView")
        f.backdrop = name == "CABackdropLayer"
        f.drawing = name.contains("DrawingLayer")
        switch name {
        case "MKMapView": f.islandHint = "map"
        case "WKWebView": f.islandHint = "web"
        case "SKView", "SCNView", "MTKView", "ARView", "ARSCNView", "GLKView": f.islandHint = "unknown"
        case "AVPlayerLayer": f.islandHint = "video"
        case "AVCaptureVideoPreviewLayer": f.islandHint = "camera"
        case "CAMetalLayer", "CAEAGLLayer": f.islandHint = "unknown"
        default: if name.hasSuffix("MapView") { f.islandHint = "map" }
        }
        cache[key] = f
        return f
    }
}

private extension CALayer {
    var isPortal: Bool { ClassFlags.of(type(of: self)).portal }
    var isBackdrop: Bool { ClassFlags.of(type(of: self)).backdrop }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
