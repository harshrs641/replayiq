import SwiftUI
import UIKit

private var maskedKey: UInt8 = 0

public extension UIView {
    /// Paint this view (and everything inside it) over in recordings. The
    /// pixels are covered on the device, before the screenshot is encoded.
    @objc var replayIQMasked: Bool {
        get {
            if let flag = (objc_getAssociatedObject(self, &maskedKey) as? NSNumber)?.boolValue { return flag }
            return ReplayIQ.maskPredicate?(self) ?? false
        }
        set { objc_setAssociatedObject(self, &maskedKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

public extension View {
    /// Paint this view over in ReplayIQ recordings (masked on the device).
    func replayIQMask() -> some View {
        overlay(ReplayIQMaskMarker().allowsHitTesting(false).accessibilityHidden(true))
    }
}

/// An invisible UIKit view covering the SwiftUI content it overlays; the
/// screen recorder masks its frame.
struct ReplayIQMaskMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = MaskMarkerView()
        v.replayIQMasked = true
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class MaskMarkerView: UIView {}

/// Finds the areas to paint over in a window.
enum Masking {
    /// Whether `view` is masked by itself (not by an ancestor).
    static func isMasked(_ view: UIView, maskTextInputs: Bool, maskAllText: Bool) -> Bool {
        if view.replayIQMasked { return true }
        if let tf = view as? UITextField {
            return tf.isSecureTextEntry || maskTextInputs
        }
        if let tv = view as? UITextView {
            return tv.isSecureTextEntry || (tv.isEditable && maskTextInputs) || maskAllText
        }
        if maskAllText, view is UILabel { return true }
        // Web content cannot be masked field by field: mask it all unless the app opts in.
        if maskAllText, NSStringFromClass(type(of: view)) == "WKWebView" { return true }
        return false
    }

    /// Masked rectangles in window coordinates, as currently on screen
    /// (presentation layers, so masks follow running animations).
    static func rects(in window: UIWindow, maskTextInputs: Bool, maskAllText: Bool) -> [CGRect] {
        var out: [CGRect] = []
        let windowLayer = window.layer.presentation() ?? window.layer
        let bounds = window.bounds
        func visit(_ view: UIView) {
            if view !== window, view.isHidden || view.alpha < 0.01 { return }
            if isMasked(view, maskTextInputs: maskTextInputs, maskAllText: maskAllText) {
                let layer = view.layer.presentation() ?? view.layer
                var r = layer.convert(layer.bounds, to: windowLayer)
                if r.isNull || r.isInfinite { r = view.convert(view.bounds, to: window) }
                r = r.insetBy(dx: -2, dy: -2).intersection(bounds)
                if !r.isNull, r.width > 0, r.height > 0 { out.append(r) }
                return
            }
            for sub in view.subviews { visit(sub) }
        }
        visit(window)
        return out
    }

    /// Whether `view` or an ancestor is masked (labels from it are not sent).
    static func isInsideMask(_ view: UIView?, maskTextInputs: Bool, maskAllText: Bool) -> Bool {
        var v = view
        while let cur = v {
            if isMasked(cur, maskTextInputs: maskTextInputs, maskAllText: maskAllText) { return true }
            v = cur.superview
        }
        return false
    }
}
