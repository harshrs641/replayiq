import SwiftUI
import UIKit

private var screenNameKey: UInt8 = 0
private var willAppearKey: UInt8 = 0

public extension UIViewController {
    /// The name sent as this screen's `navigate` event (default: the class name).
    @objc var replayIQScreenName: String? {
        get { objc_getAssociatedObject(self, &screenNameKey) as? String }
        set { objc_setAssociatedObject(self, &screenNameKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    @objc internal func riq_viewDidAppear(_ animated: Bool) {
        riq_viewDidAppear(animated) // the original implementation
        NavigationTracker.didAppear(self)
    }

    @objc internal func riq_viewWillAppear(_ animated: Bool) {
        objc_setAssociatedObject(self, &willAppearKey, NSNumber(value: RIQ.now()), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        riq_viewWillAppear(animated)
    }
}

public extension View {
    /// Sends a `navigate` event for this screen when it appears.
    func replayIQScreen(_ name: String) -> some View {
        onAppear { ReplayIQ.screen(name) }
    }
}

/// `navigate` events when the app's own view controllers appear.
enum NavigationTracker {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        riqSwizzle(UIViewController.self, #selector(UIViewController.viewDidAppear(_:)),
                   #selector(UIViewController.riq_viewDidAppear(_:)))
        riqSwizzle(UIViewController.self, #selector(UIViewController.viewWillAppear(_:)),
                   #selector(UIViewController.riq_viewWillAppear(_:)))
    }

    static func didAppear(_ vc: UIViewController) {
        guard Recorder.shared?.isRecording == true, let name = screenName(vc) else { return }
        Recorder.shared?.screen(name, auto: true)
        if let start = objc_getAssociatedObject(vc, &willAppearKey) as? NSNumber {
            Signals.shared?.screenLoaded(name, duration: max(0, RIQ.now() - start.int64Value))
        }
    }

    static func screenName(_ vc: UIViewController) -> String? {
        if let n = vc.replayIQScreenName { return n }
        if vc is UINavigationController || vc is UITabBarController || vc is UISplitViewController
            || vc is UIPageViewController || vc is UIAlertController { return nil }
        // Only the app's own classes: system and SwiftUI hosting controllers
        // have no meaningful names (use ReplayIQ.screen for SwiftUI).
        let cls: AnyClass = type(of: vc)
        let path = Bundle(for: cls).bundlePath
        guard path.hasPrefix(Bundle.main.bundlePath) else { return nil }
        let name = String(describing: cls)
        if name.contains("<") || name.hasPrefix("_") { return nil }
        return name
    }
}
