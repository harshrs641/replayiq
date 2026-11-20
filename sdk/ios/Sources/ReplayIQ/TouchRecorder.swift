import UIKit

/// 3+ taps within 700 ms and 48 pt of each other (recording API v1).
struct RageDetector {
    static let window: Int64 = 700
    static let radius: CGFloat = 48
    private var taps: [(CGPoint, Int64)] = []
    private var fired = false

    /// Returns true on the tap that makes a burst a rage click (once per burst).
    mutating func tap(_ p: CGPoint, at ts: Int64) -> Bool {
        taps = taps.filter { ts - $0.1 <= RageDetector.window && hypot($0.0.x - p.x, $0.0.y - p.y) <= RageDetector.radius }
        if taps.isEmpty { fired = false }
        taps.append((p, ts))
        if taps.count >= 3 && !fired {
            fired = true
            return true
        }
        return false
    }
}

/// Builds `role:"label"` selectors from accessibility info.
enum ElementSelector {
    static func role(of view: UIView) -> String {
        if view is UITextField { return (view as? UITextField)?.isSecureTextEntry == true ? "password" : "textfield" }
        if let tv = view as? UITextView, tv.isEditable { return "textarea" }
        if view is UISwitch { return "switch" }
        if view is UISlider { return "slider" }
        if view is UISegmentedControl { return "segmented" }
        if view is UIButton { return "button" }
        if view is UITableViewCell || view is UICollectionViewCell { return "cell" }
        if view is UIImageView { return "image" }
        if view is UILabel { return "text" }
        return role(traits: view.accessibilityTraits, fallback: view is UIControl ? "control" : "view")
    }

    static func role(traits t: UIAccessibilityTraits, fallback: String) -> String {
        if t.contains(.button) { return "button" }
        if t.contains(.link) { return "link" }
        if t.contains(.searchField) { return "search" }
        if t.contains(.adjustable) { return "slider" }
        if t.contains(.tabBar) { return "tab" }
        if t.contains(.header) { return "header" }
        if t.contains(.image) { return "image" }
        if t.contains(.staticText) { return "text" }
        return fallback
    }

    static func label(of view: UIView) -> String? {
        if let tf = view as? UITextField { // never the value
            return clean(tf.accessibilityLabel) ?? clean(tf.placeholder)
        }
        if view is UITextView { return clean(view.accessibilityLabel) }
        if let b = view as? UIButton {
            return clean(b.accessibilityLabel) ?? clean(b.currentTitle) ?? clean(b.titleLabel?.text)
        }
        if let s = view as? UISegmentedControl, s.selectedSegmentIndex >= 0 {
            return clean(s.titleForSegment(at: s.selectedSegmentIndex))
        }
        return clean(view.accessibilityLabel)
    }

    static func format(_ role: String, _ label: String?) -> String {
        guard let label else { return role }
        return "\(role):\"\(label.replacingOccurrences(of: "\"", with: "'"))\""
    }

    /// The selector for a tap at `point` (window coordinates) on `view`.
    static func selector(for view: UIView, at point: CGPoint, in window: UIWindow, masked: Bool) -> String {
        // UIKit: the nearest view (or ancestor) that names itself.
        var v: UIView? = view
        var depth = 0
        while let cur = v, depth < 8 {
            if !(cur is UIWindow), let l = label(of: cur) {
                return format(role(of: cur), masked && !(cur is UITextField) ? nil : l)
            }
            v = cur.superview
            depth += 1
        }
        // SwiftUI and custom drawing: the accessibility element under the finger.
        let global: UICoordinateSpace = window.screen.coordinateSpace
        let p = window.coordinateSpace.convert(point, to: global)
        var container: UIView? = view
        depth = 0
        while let c = container, depth < 6 {
            if let el = element(at: p, in: c, depth: 0), let l = clean(el.accessibilityLabel) {
                return format(role(traits: el.accessibilityTraits, fallback: "view"), masked ? nil : l)
            }
            container = c.superview
            depth += 1
        }
        return format(role(of: view), nil)
    }

    static func element(at p: CGPoint, in obj: NSObject, depth: Int) -> NSObject? {
        guard depth < 12 else { return nil }
        let children: [NSObject]
        if let els = obj.accessibilityElements as? [NSObject], !els.isEmpty {
            children = els
        } else if let view = obj as? UIView {
            children = view.subviews.filter { !$0.isHidden }
        } else {
            children = []
        }
        // Deepest, front-most first.
        for child in children.reversed() {
            if let view = child as? UIView, view.isHidden { continue }
            if child.isAccessibilityElement {
                if child.accessibilityFrame.contains(p) { return child }
                continue
            }
            if let hit = element(at: p, in: child, depth: depth + 1) { return hit }
        }
        return nil
    }

    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t.count > 80 ? String(t.prefix(80)) : t
    }
}

/// Records touches from every event the app dispatches (UIApplication.sendEvent).
final class TouchRecorder {
    static let moveInterval: Int64 = 50
    private static var installed = false
    private static var options = ReplayIQOptions()

    // Main thread only.
    private static var primary: UITouch?
    private static var downPoint: CGPoint = .zero
    private static var downAt: Int64 = 0
    private static var lastMove: Int64 = 0
    private static var rage = RageDetector()
    private static var second: UITouch?
    private static var pinchStart: CGFloat = 0
    private static var pinchLast: CGFloat = 0
    private static var lastTap: (CGPoint, Int64)?

    static func install(options: ReplayIQOptions) {
        self.options = options
        guard !installed else { return }
        installed = true
        riqSwizzle(UIApplication.self, #selector(UIApplication.sendEvent(_:)), #selector(UIApplication.riq_sendEvent(_:)))
    }

    static func handle(_ event: UIEvent) {
        guard event.type == .touches, let recorder = Recorder.shared, recorder.isRecording,
              let touches = event.allTouches else { return }
        recorder.activity()
        for touch in touches {
            guard let window = touch.window, window === ScreenRecorder.keyWindow() else { continue }
            let p = touch.location(in: window)
            let ts = RIQ.now()
            switch touch.phase {
            case .began:
                guard primary == nil else {
                    if second == nil, let first = primary {
                        second = touch
                        pinchStart = TouchRecorder.distance(first, touch, window)
                        pinchLast = pinchStart
                    }
                    continue
                }
                primary = touch
                downPoint = p
                downAt = ts
                lastMove = ts
                emit(p, "down", ts)
            case .moved:
                if let first = primary, let sec = second, touch === first || touch === sec {
                    pinchLast = TouchRecorder.distance(first, sec, window)
                }
                guard touch === primary, ts - lastMove >= moveInterval else { continue }
                lastMove = ts
                emit(p, "move", ts)
            case .ended, .cancelled:
                if touch === second { second = nil; continue }
                guard touch === primary else { continue }
                primary = nil
                emit(p, "up", ts)
                guard touch.phase == .ended else { second = nil; continue }
                gesture(touch, at: p, in: window, ts: ts)
            default:
                continue
            }
        }
    }

    static func distance(_ a: UITouch, _ b: UITouch, _ w: UIWindow) -> CGFloat {
        let p = a.location(in: w), q = b.location(in: w)
        return hypot(p.x - q.x, p.y - q.y)
    }

    /// Classifies a finished touch: tap (also `click`), double tap, long
    /// press, swipe, pan or pinch (recording API v1.1 `gesture`).
    private static func gesture(_ touch: UITouch, at p: CGPoint, in window: UIWindow, ts: Int64) {
        let dx = p.x - downPoint.x, dy = p.y - downPoint.y
        let dist = hypot(dx, dy)
        let duration = ts - downAt
        let view = touch.view ?? window
        var g: [String: Any] = ["type": 5, "subtype": "gesture", "timestamp": ts,
                                "x": Double(downPoint.x.rounded()), "y": Double(downPoint.y.rounded())]
        let wasPinch = pinchStart > 0 && second != nil || (pinchStart > 0 && abs(pinchLast - pinchStart) > 12)
        if wasPinch {
            g["kind"] = "pinch"
            g["scale"] = Double((pinchLast / max(1, pinchStart) * 100).rounded() / 100)
        } else if dist < 12 {
            if duration >= 500 {
                g["kind"] = "long_press"
            } else {
                tapped(view, at: p, in: window, ts: ts)
                if let (lp, lt) = lastTap, ts - lt < 300, hypot(lp.x - p.x, lp.y - p.y) < 40 {
                    g["kind"] = "double_tap"
                    lastTap = nil
                } else {
                    g["kind"] = "tap"
                    lastTap = (p, ts)
                }
            }
        } else {
            g["kind"] = duration < 300 && dist >= 30 ? "swipe" : "pan"
            g["dx"] = Double(dx.rounded())
            g["dy"] = Double(dy.rounded())
        }
        second = nil
        pinchStart = 0
        pinchLast = 0
        let masked = Masking.isInsideMask(view, maskTextInputs: false, maskAllText: options.maskAllText)
        g["selector"] = ElementSelector.selector(for: view, at: downPoint, in: window, masked: masked)
        Recorder.shared?.record(g, bytes: 140)
    }

    private static func emit(_ p: CGPoint, _ phase: String, _ ts: Int64) {
        Recorder.shared?.record(["type": 5, "subtype": "touch", "timestamp": ts,
                                 "x": Double(p.x.rounded()), "y": Double(p.y.rounded()), "phase": phase], bytes: 90)
    }

    private static func tapped(_ view: UIView, at p: CGPoint, in window: UIWindow, ts: Int64) {
        let masked = Masking.isInsideMask(view, maskTextInputs: false, maskAllText: options.maskAllText)
        let selector = ElementSelector.selector(for: view, at: p, in: window, masked: masked)
        Recorder.shared?.record(["type": 5, "subtype": "click", "timestamp": ts, "selector": selector], bytes: 120)
        if rage.tap(p, at: ts) {
            Recorder.shared?.record(["type": 5, "subtype": "rage_click", "timestamp": ts, "selector": selector,
                                     "x": Double(p.x.rounded()), "y": Double(p.y.rounded())], bytes: 120)
        }
    }
}

extension UIApplication {
    @objc func riq_sendEvent(_ event: UIEvent) {
        TouchRecorder.handle(event)
        riq_sendEvent(event) // the original implementation
    }
}

/// `input` events when a text field is edited (never its value), at most
/// once per field per second.
enum InputTracker {
    private static var installed = false
    private static var last: [ObjectIdentifier: Int64] = [:]

    static func install() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        for name in [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification] {
            _ = nc.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let view = n.object as? UIView, Recorder.shared?.isRecording == true else { return }
                if let tv = view as? UITextView, !tv.isEditable { return }
                let id = ObjectIdentifier(view)
                let ts = RIQ.now()
                if let prev = last[id], ts - prev < 1000 { return }
                last[id] = ts
                if last.count > 64 { last = [id: ts] }
                let sel = ElementSelector.format(ElementSelector.role(of: view), ElementSelector.label(of: view))
                Recorder.shared?.record(["type": 5, "subtype": "input", "timestamp": ts, "selector": sel], bytes: 120)
            }
        }
    }
}
