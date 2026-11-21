import AVFoundation
import CoreLocation
import Network
import Photos
import QuartzCore
import UIKit
import UserNotifications

/// Mobile signals (recording API v1.1 §2): lifecycle, app start, screen
/// load, jank, hangs, memory, keyboard, orientation, connectivity, deep
/// links, push opens, permissions, thermal and power state, focus and blur.
final class Signals {
    static private(set) var shared: Signals?

    private let options: ReplayIQOptions
    private var observers: [NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()
    private var lastConnectivity: String?
    private var lastOrientation: String?
    private var coldStartPending = true
    private var warmStartAt: CFTimeInterval?
    private var permissions: [String: String] = [:]

    // Screen load: route shown → its first committed frame.
    private let pendingScreen = Locked<(name: String, at: Int64)?>(nil)

    // Jank (main thread).
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var dropped = 0
    private var frozen = 0
    private var worst: CFTimeInterval = 0
    private var interactingUntil: CFTimeInterval = 0

    // Hangs.
    private var watchdog: Thread?
    private let lastPong = Locked(CACurrentMediaTime())
    private let watching = Locked(false)

    static func install(options: ReplayIQOptions) {
        guard shared == nil else { return }
        let s = Signals(options: options)
        shared = s
        s.installObservers()
    }

    private init(options: ReplayIQOptions) {
        self.options = options
    }

    private func emit(_ subtype: String, _ fields: [String: Any]) {
        var e: [String: Any] = ["type": 5, "subtype": subtype, "timestamp": RIQ.now()]
        for (k, v) in fields { e[k] = v }
        Recorder.shared?.record(e, bytes: 120)
        Diagnostics.shared.add("signal_\(subtype)")
    }

    // MARK: - Observers

    private func installObservers() {
        let nc = NotificationCenter.default
        func on(_ name: Notification.Name, _ block: @escaping (Notification) -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main, using: block))
        }
        on(UIApplication.didBecomeActiveNotification) { [weak self] _ in self?.didBecomeActive() }
        on(UIApplication.willEnterForegroundNotification) { [weak self] _ in self?.warmStartAt = CACurrentMediaTime() }
        on(UIApplication.didEnterBackgroundNotification) { [weak self] _ in
            self?.emit("lifecycle", ["state": "background", "cold": false])
            self?.stopWatchdog()
        }
        on(UIApplication.willTerminateNotification) { [weak self] _ in
            self?.emit("lifecycle", ["state": "terminate", "cold": false])
        }
        on(UIApplication.didReceiveMemoryWarningNotification) { [weak self] _ in
            self?.emit("memory", ["level": "warning", "used": Signals.memoryMB()])
        }
        on(UIResponder.keyboardWillShowNotification) { [weak self] n in
            let h = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
            self?.emit("keyboard", ["visible": true, "height": Double(h.rounded())])
            self?.interacting()
        }
        on(UIResponder.keyboardWillHideNotification) { [weak self] _ in
            self?.emit("keyboard", ["visible": false, "height": 0])
            self?.interacting()
        }
        on(UIDevice.orientationDidChangeNotification) { [weak self] _ in self?.orientationChanged() }
        on(ProcessInfo.thermalStateDidChangeNotification) { [weak self] _ in
            self?.emit("thermal", ["state": Signals.thermal(ProcessInfo.processInfo.thermalState)])
        }
        on(Notification.Name.NSProcessInfoPowerStateDidChange) { [weak self] _ in
            self?.emit("power", ["low_power": ProcessInfo.processInfo.isLowPowerModeEnabled])
        }
        for (begin, end) in [(UITextField.textDidBeginEditingNotification, UITextField.textDidEndEditingNotification),
                             (UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification)] {
            on(begin) { [weak self] n in self?.focus(n.object as? UIView, "focus") }
            on(end) { [weak self] n in self?.focus(n.object as? UIView, "blur") }
        }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        pathMonitor.pathUpdateHandler = { [weak self] path in self?.connectivity(path) }
        pathMonitor.start(queue: DispatchQueue(label: "io.replayiq.path", qos: .utility))

        DeepLinks.install()
        permissions = Signals.permissionStates()
        if UIApplication.shared.applicationState == .active { didBecomeActive() }
    }

    private func didBecomeActive() {
        emit("lifecycle", ["state": "foreground", "cold": coldStartPending])
        lastOrientation = nil
        orientationChanged()
        checkPermissions()
        startWatchdog()
        interacting()
    }

    private func focus(_ view: UIView?, _ subtype: String) {
        guard let view else { return }
        emit(subtype, ["selector": ElementSelector.format(ElementSelector.role(of: view), ElementSelector.label(of: view))])
        interacting()
    }

    private func orientationChanged() {
        guard let w = ScreenRecorder.keyWindow() else { return }
        let value = w.bounds.width > w.bounds.height ? "landscape" : "portrait"
        if value != lastOrientation {
            if lastOrientation != nil { emit("orientation", ["value": value]) }
            lastOrientation = value
        }
    }

    private func connectivity(_ path: NWPath) {
        let type: String
        if path.status != .satisfied { type = "none" }
        else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) { type = "wifi" }
        else if path.usesInterfaceType(.cellular) { type = "cellular" }
        else { type = "other" }
        let quality = path.status != .satisfied ? "offline" : path.isConstrained ? "constrained" : path.isExpensive ? "expensive" : "good"
        let key = type + quality
        guard key != lastConnectivity else { return }
        let first = lastConnectivity == nil
        lastConnectivity = key
        if !first || type == "none" { emit("connectivity", ["type": type, "quality": quality]) }
    }

    // MARK: - App start and screen load

    /// The first frame recorded after launch: a cold start.
    func firstFrame() {
        guard coldStartPending else { return }
        coldStartPending = false
        if let start = Signals.processStart() {
            emit("app_start", ["kind": "cold", "duration": Int64((Date().timeIntervalSince1970 - start) * 1000)])
        }
    }

    /// A frame was committed (DOM recorder); finishes pending measurements.
    func frameCommitted(at ts: Int64) {
        if let p = pendingScreen.mutate({ v -> (name: String, at: Int64)? in let p = v; v = nil; return p }) {
            emit("screen_load", ["screen": p.name, "duration": max(0, ts - p.at)])
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.warmStartAt else { return }
            self.warmStartAt = nil
            if !self.coldStartPending {
                self.emit("app_start", ["kind": "warm", "duration": Int64((CACurrentMediaTime() - w) * 1000)])
            }
        }
    }

    /// A manually named screen (`ReplayIQ.screen`) started showing.
    func screenShown(_ name: String) {
        pendingScreen.set((name, RIQ.now()))
    }

    /// A UIKit view controller finished appearing.
    func screenLoaded(_ name: String, duration: Int64) {
        emit("screen_load", ["screen": name, "duration": duration])
    }

    // MARK: - Jank

    /// The user is interacting (touches, keyboard, scrolling): measure frames
    /// for a while. Idle screens don't run a display link.
    func interacting(for seconds: CFTimeInterval = 3) {
        interactingUntil = max(interactingUntil, CACurrentMediaTime() + seconds)
        guard link == nil, UIApplication.shared.applicationState == .active else { return }
        let l = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastFrame = 0
        if windowStart == 0 { windowStart = CACurrentMediaTime() }
    }

    fileprivate func frame(_ l: CADisplayLink) {
        let now = l.timestamp
        if lastFrame > 0 {
            let delta = now - lastFrame
            let expected = max(1.0 / 120, l.targetTimestamp - l.timestamp)
            if delta > max(0.0167, expected * 1.5) { dropped += 1 }
            if delta > 0.7 { frozen += 1 }
            worst = max(worst, delta)
            Diagnostics.shared.sample("frame_ms", delta * 1000)
        }
        lastFrame = now
        if now - windowStart >= 5 { flushJank(now) }
        if CACurrentMediaTime() > interactingUntil {
            flushJank(now)
            l.invalidate()
            link = nil
            windowStart = 0
        }
    }

    private func flushJank(_ now: CFTimeInterval) {
        if dropped > 0 || frozen > 0 {
            emit("jank", ["screen": Recorder.shared?.currentScreen ?? "", "dropped": dropped, "frozen": frozen,
                          "worst": Int((worst * 1000).rounded()), "window": Int(((now - windowStart) * 1000).rounded())])
        }
        dropped = 0
        frozen = 0
        worst = 0
        windowStart = now
    }

    // MARK: - Hangs

    private func startWatchdog() {
        guard !watching.get else { return }
        watching.set(true)
        lastPong.set(CACurrentMediaTime())
        let t = Thread { [weak self] in self?.watchLoop() }
        t.name = "io.replayiq.watchdog"
        t.qualityOfService = .utility
        t.start()
        watchdog = t
    }

    private func stopWatchdog() {
        watching.set(false)
        watchdog = nil
    }

    private func watchLoop() {
        var hangStart: CFTimeInterval?
        while watching.get {
            DispatchQueue.main.async { [weak self] in self?.lastPong.set(CACurrentMediaTime()) }
            Thread.sleep(forTimeInterval: 0.5)
            let blocked = CACurrentMediaTime() - lastPong.get
            if blocked >= 2.0 {
                if hangStart == nil { hangStart = lastPong.get }
            } else if let s = hangStart {
                let duration = Int64((lastPong.get - s) * 1000)
                hangStart = nil
                emit("hang", ["duration": duration, "stack": ""])
            }
        }
    }

    // MARK: - Permissions

    private func checkPermissions() {
        let now = Signals.permissionStates()
        for (name, state) in now where permissions[name] != state {
            if permissions[name] == "not_determined", state != "not_determined" {
                emit("permission", ["name": name, "result": state])
            }
        }
        permissions = now
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            let state = Signals.notificationState(s.authorizationStatus)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.permissions["notifications"] == "not_determined", state != "not_determined" {
                    self.emit("permission", ["name": "notifications", "result": state])
                }
                self.permissions["notifications"] = state
            }
        }
    }

    static func permissionStates() -> [String: String] {
        func av(_ s: AVAuthorizationStatus) -> String {
            switch s {
            case .authorized: return "granted"
            case .notDetermined: return "not_determined"
            default: return "denied"
            }
        }
        var out: [String: String] = [
            "camera": av(AVCaptureDevice.authorizationStatus(for: .video)),
            "microphone": av(AVCaptureDevice.authorizationStatus(for: .audio)),
        ]
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: out["photos"] = "granted"
        case .limited: out["photos"] = "limited"
        case .notDetermined: out["photos"] = "not_determined"
        default: out["photos"] = "denied"
        }
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: out["location"] = "granted"
        case .notDetermined: out["location"] = "not_determined"
        default: out["location"] = "denied"
        }
        return out
    }

    static func notificationState(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "granted"
        case .provisional, .ephemeral: return "limited"
        case .notDetermined: return "not_determined"
        default: return "denied"
        }
    }

    // MARK: - Helpers

    static func thermal(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func memoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }

    /// When this process started (unix seconds).
    static func processStart() -> TimeInterval? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &kinfo, &size, nil, 0) == 0 else { return nil }
        let tv = kinfo.kp_proc.p_un.__p_starttime
        return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
    }

    func deeplink(_ url: URL) {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !NetworkRecorder.includeQuery.get { c?.query = nil }
        emit("deeplink", ["url": c?.string ?? url.absoluteString])
    }

    func pushOpen(campaign: String?) {
        emit("push_open", ["campaign": campaign ?? ""])
    }
}

/// Breaks the display link's retain cycle.
private final class DisplayLinkProxy: NSObject {
    weak var target: Signals?
    init(_ t: Signals) { target = t }
    @objc func tick(_ l: CADisplayLink) {
        guard let target else { l.invalidate(); return }
        target.frame(l)
    }
}

/// Deep links and notification opens, observed by wrapping the app's own
/// delegate methods (only those it implements).
enum DeepLinks {
    private static var done = Set<String>()

    static func install() {
        if let d = UIApplication.shared.delegate { hookAppDelegate(type(of: d)) }
        NotificationCenter.default.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { n in
            if let scene = n.object as? UIScene, let d = scene.delegate { hookSceneDelegate(type(of: d)) }
        }
        for scene in UIApplication.shared.connectedScenes {
            if let d = scene.delegate { hookSceneDelegate(type(of: d)) }
        }
        let center = UNUserNotificationCenter.current()
        if let d = center.delegate { hookNotificationDelegate(type(of: d)) }
        riqSwizzle(UNUserNotificationCenter.self, #selector(setter: UNUserNotificationCenter.delegate),
                   #selector(UNUserNotificationCenter.riq_setDelegate(_:)))
    }

    private static func once(_ cls: AnyClass, _ sel: Selector) -> Bool {
        let key = NSStringFromClass(cls) + NSStringFromSelector(sel)
        return done.insert(key).inserted
    }

    /// Calls `before` and then the original implementation of `sel` on `cls`.
    private static func wrap<Block>(_ cls: AnyClass, _ sel: Selector, _ make: (IMP) -> Block) {
        guard let m = class_getInstanceMethod(cls, sel), once(cls, sel) else { return }
        let imp = imp_implementationWithBlock(make(method_getImplementation(m)) as Any)
        // Add to the class itself so an inherited implementation isn't changed for others.
        if !class_addMethod(cls, sel, imp, method_getTypeEncoding(m)) { method_setImplementation(m, imp) }
    }

    static func hookAppDelegate(_ cls: AnyClass) {
        typealias OpenURL = @convention(c) (AnyObject, Selector, UIApplication, URL, [UIApplication.OpenURLOptionsKey: Any]) -> Bool
        let sel = #selector(UIApplicationDelegate.application(_:open:options:))
        wrap(cls, sel) { (imp: IMP) -> (@convention(block) (AnyObject, UIApplication, URL, [UIApplication.OpenURLOptionsKey: Any]) -> Bool) in
            { obj, app, url, opts in
                Signals.shared?.deeplink(url)
                return unsafeBitCast(imp, to: OpenURL.self)(obj, sel, app, url, opts)
            }
        }
    }

    static func hookSceneDelegate(_ cls: AnyClass) {
        typealias OpenContexts = @convention(c) (AnyObject, Selector, UIScene, Set<UIOpenURLContext>) -> Void
        let sel = #selector(UISceneDelegate.scene(_:openURLContexts:))
        wrap(cls, sel) { (imp: IMP) -> (@convention(block) (AnyObject, UIScene, Set<UIOpenURLContext>) -> Void) in
            { obj, scene, contexts in
                for c in contexts { Signals.shared?.deeplink(c.url) }
                unsafeBitCast(imp, to: OpenContexts.self)(obj, sel, scene, contexts)
            }
        }
    }

    static func hookNotificationDelegate(_ cls: AnyClass) {
        typealias DidReceive = @convention(c) (AnyObject, Selector, UNUserNotificationCenter, UNNotificationResponse, @escaping () -> Void) -> Void
        let sel = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
        wrap(cls, sel) { (imp: IMP) -> (@convention(block) (AnyObject, UNUserNotificationCenter, UNNotificationResponse, @escaping () -> Void) -> Void) in
            { obj, center, response, done in
                if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                    let info = response.notification.request.content.userInfo
                    let campaign = (info["campaign"] ?? info["campaign_id"] ?? info["riq_campaign"]) as? String
                    Signals.shared?.pushOpen(campaign: campaign)
                }
                unsafeBitCast(imp, to: DidReceive.self)(obj, sel, center, response, done)
            }
        }
    }
}

extension UNUserNotificationCenter {
    @objc func riq_setDelegate(_ d: UNUserNotificationCenterDelegate?) {
        if let d { DeepLinks.hookNotificationDelegate(type(of: d)) }
        riq_setDelegate(d)
    }
}
