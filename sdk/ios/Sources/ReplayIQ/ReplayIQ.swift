import Foundation
import UIKit

/// Log level of `ReplayIQ.log(_:level:)`, sent as a `console` event.
@objc(ReplayIQLogLevel)
public enum ReplayIQLogLevel: Int {
    case log = 0
    case warn = 1
    case error = 2

    var name: String {
        switch self {
        case .log: return "log"
        case .warn: return "warn"
        case .error: return "error"
        }
    }
}

/// How screens are recorded.
@objc(ReplayIQRecordingMode)
public enum ReplayIQRecordingMode: Int {
    /// Native DOM, falling back to screenshots for screens that are mostly
    /// maps, video or custom drawing.
    case auto = 0
    /// The UI as a tree of nodes plus changes (recording API v1.1).
    case nativeDom = 1
    /// Masked screenshots (recording API v1).
    case screenshot = 2
}

/// Recording options. Every property has a safe default; pass `nil` to
/// `ReplayIQ.start` to use them all.
@objc(ReplayIQOptions)
public final class ReplayIQOptions: NSObject {
    /// Share of sessions recorded, 0–1. Decided once per session.
    @objc public var sampleRate: Double = 1.0
    /// Paint over every UITextField / UITextView (SwiftUI TextField, SecureField,
    /// TextEditor). Secure text fields are always masked.
    @objc public var maskAllTextInputs = true
    /// Also paint over every UILabel and read-only text view.
    @objc public var maskAllText = false
    /// Native DOM, screenshots, or Native DOM with a screenshot fallback.
    @objc public var recordingMode: ReplayIQRecordingMode = .auto
    /// Record the screen at all. Off: only app events (navigate, network, ...) are sent.
    @objc public var captureScreens = true
    /// Mobile signals: lifecycle, app start, screen load, jank, hangs,
    /// memory, keyboard, orientation, connectivity, deep links, push opens,
    /// permissions, thermal and power state, focus and blur.
    @objc public var captureSignals = true
    @objc public var captureTouches = true
    @objc public var captureNetwork = true
    @objc public var captureCrashes = true
    /// Send `navigate` when a UIKit view controller appears.
    @objc public var trackViewControllers = true
    /// Frames per second, at most 2.
    @objc public var maxFramesPerSecond: Double = 2
    /// Screenshot scale (pixels per point), at most 2.
    @objc public var imageScale: CGFloat = 1.5
    @objc public var jpegQuality: CGFloat = 0.6
    /// Include query strings in `network` URLs.
    @objc public var networkIncludeQuery = false
    /// Hosts never recorded as `network` events (the ingest host always is).
    @objc public var networkIgnoredHosts: [String] = []
    @objc public var flushInterval: TimeInterval = 5
    /// A session ends after this long in the background (30 min).
    @objc public var sessionTimeout: TimeInterval = 30 * 60
    /// Max bytes of event batches kept on disk while offline (oldest dropped).
    @objc public var maxQueueBytes: Int = 5 * 1024 * 1024
    /// Log SDK problems with NSLog. On in debug builds.
    @objc public var debug: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    /// For wrapper SDKs only (React Native): reported `platform` and `sdk`.
    @objc public var platform = "ios"
    @objc public var sdkName = RIQ.sdkName
    /// Extra string metadata sent with the session.
    @objc public var metadata: [String: String] = [:]

    @objc public override init() { super.init() }
}

/// ReplayIQ session replay for iOS.
///
/// ```swift
/// ReplayIQ.start(key: "<ingest key>", endpoint: "https://ingest.example.com")
/// ```
///
/// Every method is safe to call from any thread, before or after `start`, and
/// never throws into the app.
@objc(ReplayIQ)
public final class ReplayIQ: NSObject {
    private override init() { super.init() }

    /// Starts recording. Call once, early (e.g. in `application(_:didFinishLaunchingWithOptions:)`
    /// or your SwiftUI `App.init`). A second call is ignored.
    @objc(startWithKey:endpoint:options:)
    public static func start(key: String, endpoint: String, options: ReplayIQOptions? = nil) {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            NSLog("[ReplayIQ] invalid endpoint %@", endpoint)
            return
        }
        Recorder.start(key: key, endpoint: url, options: options ?? ReplayIQOptions())
    }

    /// Sets the user for this and later sessions. `traits` values are sent as strings.
    @objc(identify:traits:)
    public static func identify(_ userId: String, traits: [String: Any]? = nil) {
        Recorder.shared?.identify(userId, traits: traits ?? [:])
    }

    /// Records one of the app's own named events.
    @objc(track:properties:)
    public static func track(_ name: String, properties: [String: Any]? = nil) {
        Recorder.shared?.track(name, properties: properties ?? [:])
    }

    /// Records a screen change (`navigate`). Use for SwiftUI screens, or the
    /// `.replayIQScreen("Name")` modifier.
    @objc(screen:)
    public static func screen(_ name: String) {
        Recorder.shared?.screen(name)
    }

    /// Sends a log line to the Console tab.
    @objc(log:level:)
    public static func log(_ message: String, level: ReplayIQLogLevel = .log) {
        Recorder.shared?.log(message, level: level)
    }

    /// Stops recording and drops anything not yet sent. Remembered across launches.
    @objc public static func optOut() {
        UserDefaults.standard.set(true, forKey: Recorder.optOutKey)
        Recorder.shared?.setOptedOut(true)
    }

    /// Allows recording again (starts a new session if `start` was called).
    @objc public static func optIn() {
        UserDefaults.standard.set(false, forKey: Recorder.optOutKey)
        Recorder.shared?.setOptedOut(false)
    }

    @objc public static var isOptedOut: Bool {
        UserDefaults.standard.bool(forKey: Recorder.optOutKey)
    }

    /// Ends the session (starting its analysis) and stops recording for this run.
    @objc public static func stop() {
        Recorder.shared?.stop()
    }

    /// Ends the session and starts a new one (e.g. on logout). Clears the user.
    @objc public static func reset() {
        Recorder.shared?.reset()
    }

    /// Sends buffered events now.
    @objc public static func flush() {
        Recorder.shared?.flush()
    }

    /// Sample rate for sessions started from now on (0–1).
    @objc public static var sampleRate: Double {
        get { Recorder.shared?.options.sampleRate ?? 1 }
        set { Recorder.shared?.setSampleRate(newValue) }
    }

    /// The current session id, or nil when not recording.
    @objc public static var sessionId: String? { Recorder.shared?.currentSessionID }

    /// Records a deep link the app handled itself (links reaching the app or
    /// scene delegate's open-URL methods are recorded automatically).
    @objc(trackDeepLink:)
    public static func trackDeepLink(_ url: URL) {
        Signals.shared?.deeplink(url)
    }

    /// Records that the app was opened from a notification (campaign id only,
    /// never the message). Recorded automatically when the app's
    /// UNUserNotificationCenter delegate handles the open.
    @objc(trackPushOpen:)
    public static func trackPushOpen(_ campaign: String?) {
        Signals.shared?.pushOpen(campaign: campaign)
    }

    /// What the SDK recorded and sent since start: event counts, bytes,
    /// walk/diff times (p50/p95/max ms), asset uploads. For tuning and support.
    @objc public static var diagnostics: [String: Any] { Diagnostics.shared.snapshot() }

    /// Clears `diagnostics` (e.g. before measuring a flow).
    @objc public static func resetDiagnostics() { Diagnostics.shared.reset() }

    /// Whether this session is being recorded (started, sampled, not opted out).
    @objc public static var isRecording: Bool { Recorder.shared?.isRecording ?? false }
}
