import Foundation
import UIKit

/// The SDK's core: session lifecycle, the event buffer and batching.
/// All mutable state lives on `q`; capture hooks call `record` from any thread.
final class Recorder {
    private static let instance = Locked<Recorder?>(nil)
    static var shared: Recorder? { instance.get }
    static let optOutKey = "io.replayiq.optout"
    static let userKey = "io.replayiq.user"

    /// Decompressed body limit is 5 MB; stay well under it.
    static let maxBatchBytes = 4 * 1024 * 1024
    /// Flush once this much is buffered. Well under the API's 5 MB because
    /// the server's pipeline (Kafka) rejects converted batches over ~1 MB.
    static let flushBytes = 512 * 1024
    static let maxBatchEvents = 50

    let key: String
    let endpoint: URL
    let options: ReplayIQOptions
    let q = DispatchQueue(label: "io.replayiq.state", qos: .utility)
    let dir: URL
    let store: SessionStore
    let queue: BatchQueue
    let uploader: Uploader

    // State, only touched on `q`.
    private var session: SessionState?
    private var buffer: [[String: Any]] = []
    private var bufferBytes = 0
    private var custom: [[String: Any]] = []
    private var userId: String?
    private var traits: [String: String] = [:]
    private var createPending = false
    private var firstScreen: String?
    private var lastScreen: String?
    private var stopped = false
    private var optedOut = false
    private var halted = false
    private var backgroundedAt: Int64?
    private var flushTimer: DispatchSourceTimer?

    private let recordingFlag = Locked(false)
    private let sessionIDFlag = Locked<String?>(nil)
    var isRecording: Bool { recordingFlag.get }
    var currentSessionID: String? { sessionIDFlag.get }

    let assetRegistry: AssetRegistry
    private let screenName = Locked<String?>(nil)
    /// The last screen name (navigate), for signals.
    var currentScreen: String? { screenName.get }

    // Main-thread components.
    private var screens: ScreenRecorder?
    private var dom: DomRecorder?
    private var observers: [NSObjectProtocol] = []

    static func start(key: String, endpoint: URL, options: ReplayIQOptions) {
        let created: Recorder? = instance.mutate { current in
            if current != nil { return nil }
            RIQ.debug = options.debug
            let r = Recorder(key: key, endpoint: endpoint, options: options)
            current = r
            return r
        }
        if let r = created {
            r.boot()
        } else if let r = shared {
            r.q.async { if r.stopped { r.stopped = false; r.beginSession() } }
        }
    }

    init(key: String, endpoint: URL, options: ReplayIQOptions, dir: URL = RIQ.storageDirectory(),
         client: HTTPClient = URLSessionHTTPClient()) {
        self.key = key
        self.endpoint = endpoint
        self.options = options
        self.dir = dir
        store = SessionStore(dir: dir)
        queue = BatchQueue(dir: dir.appendingPathComponent("queue", isDirectory: true), maxBytes: options.maxQueueBytes)
        let q = self.q
        var onUnauthorized: () -> Void = {}
        uploader = Uploader(queue: queue, client: client, endpoint: endpoint, key: key, onUnauthorized: { onUnauthorized() })
        userId = UserDefaults.standard.string(forKey: Recorder.userKey)
        assetRegistry = AssetRegistry(dir: dir, key: key)
        uploader.registry = assetRegistry
        onUnauthorized = { [weak self] in q.async { self?.halted = true; self?.updateFlags() } }
    }

    private func boot() {
        if Thread.isMainThread { UIScreenInfo.capture() }
        let crashes = options.captureCrashes ? CrashReporter.collect(dir: dir) : []
        if options.captureCrashes { CrashReporter.install(dir: dir) }
        q.async {
            self.optedOut = UserDefaults.standard.bool(forKey: Recorder.optOutKey)
            self.restorePreviousSession()
            if !self.optedOut {
                for c in crashes { self.enqueueCrash(c) }
                self.beginSession()
            }
            self.startFlushTimer()
            self.uploader.kick()
        }
        DispatchQueue.main.async { self.installHooks() }
    }

    // MARK: - Sessions

    private func restorePreviousSession() {
        let now = RIQ.now()
        guard let s = store.load() else { return }
        if !optedOut, s.isLive(now: now, key: key, timeout: options.sessionTimeout) {
            session = s
        } else {
            if s.sampled && !optedOut { enqueueEnd(s) }
            store.save(nil)
        }
    }

    /// Starts a new session, or continues a restored one. Idempotent on the
    /// server, so a continued session sends its create again.
    private func beginSession() {
        guard !optedOut, !stopped else { return }
        if session == nil {
            session = SessionState.new(key: key, now: RIQ.now(), sampleRate: options.sampleRate, random: { Double.random(in: 0..<1) })
            firstScreen = nil
            lastScreen = nil
        }
        store.save(session)
        createPending = session?.sampled == true
        updateFlags()
        DispatchQueue.main.async {
            self.screens?.requestKeyframe()
            self.dom?.requestSnapshot()
        }
        RIQ.log("session \(session!.id) sampled=\(session!.sampled)")
    }

    private func endSession(at: Int64? = nil) {
        guard var s = session else { return }
        flushLocked()
        if let at { s.lastActive = at } else { s.lastActive = RIQ.now() }
        if s.sampled { enqueueEnd(s) }
        session = nil
        store.save(nil)
        updateFlags()
        uploader.kick()
    }

    private func updateFlags() {
        let on = !stopped && !optedOut && !halted && session?.sampled == true
        recordingFlag.set(on)
        sessionIDFlag.set(on ? session?.id : nil)
        CrashReporter.setSession(on ? session?.id : nil)
    }

    // MARK: - Public API (any thread)

    func identify(_ id: String, traits: [String: Any]) {
        q.async {
            self.userId = id
            UserDefaults.standard.set(id, forKey: Recorder.userKey)
            for (k, v) in traits { self.traits[k] = "\(v)" }
            var props: [String: Any] = ["user_id": id]
            for (k, v) in self.traits { props[k] = v }
            self.appendCustom("$identify", props)
        }
    }

    func track(_ name: String, properties: [String: Any]) {
        q.async { self.appendCustom(name, properties) }
    }

    func screen(_ name: String, auto: Bool = false) {
        let ts = RIQ.now()
        q.async {
            guard self.isRecording, name != self.lastScreen else { return }
            self.lastScreen = name
            self.screenName.set(name)
            if !auto { Signals.shared?.screenShown(name) }
            DispatchQueue.main.async { self.dom?.requestSnapshot() }
            if self.firstScreen == nil { self.firstScreen = name }
            self.appendLocked(["type": 5, "subtype": "navigate", "timestamp": ts,
                               "url": RIQ.appURL(name), "message": name], bytes: 120)
        }
    }

    func log(_ message: String, level: ReplayIQLogLevel) {
        record(["type": 5, "subtype": "console", "timestamp": RIQ.now(),
                "level": level.name, "message": message, "stack": ""], bytes: message.utf8.count + 80)
    }

    func setOptedOut(_ out: Bool) {
        q.async {
            if out {
                self.optedOut = true
                self.buffer.removeAll()
                self.custom.removeAll()
                self.bufferBytes = 0
                self.queue.clear()
                self.session = nil
                self.store.save(nil)
                self.updateFlags()
            } else if self.optedOut {
                self.optedOut = false
                self.beginSession()
            }
        }
    }

    func setSampleRate(_ rate: Double) {
        options.sampleRate = max(0, min(1, rate))
    }

    func stop() {
        q.async {
            self.endSession()
            self.stopped = true
            self.updateFlags()
        }
    }

    func reset() {
        q.async {
            self.endSession()
            self.userId = nil
            self.traits = [:]
            UserDefaults.standard.removeObject(forKey: Recorder.userKey)
            self.beginSession()
        }
    }

    func flush() { q.async { self.flushLocked() } }

    /// Something happened that may change the UI (touch, network response…).
    func activity() {
        if Thread.isMainThread {
            dom?.kick()
            Signals.shared?.interacting()
        } else {
            DispatchQueue.main.async { self.activity() }
        }
    }

    /// Queues an asset upload (v1.1 §3); it goes out before later batches.
    func enqueueAsset(hash: String, type: String, data: Data) {
        q.async {
            guard self.isRecording else { return }
            self.queue.enqueue(path: "api/v1/assets|\(type)|\(hash)", body: data, kind: .asset)
            self.uploader.kick()
        }
    }

    /// Records one event (a dictionary in the recording API's shape).
    func record(_ event: [String: Any], bytes: Int = 200) {
        guard isRecording else { return }
        q.async { self.appendLocked(event, bytes: bytes) }
    }

    // MARK: - Buffer and batches (on q)

    private func appendLocked(_ event: [String: Any], bytes: Int) {
        guard isRecording else { return }
        buffer.append(event)
        bufferBytes += bytes
        Diagnostics.shared.add("events")
        if buffer.count >= Recorder.maxBatchEvents || bufferBytes >= Recorder.flushBytes {
            flushLocked()
        }
    }

    private func appendCustom(_ name: String, _ props: [String: Any]) {
        guard isRecording else { return }
        custom.append(["name": name, "properties": Recorder.jsonSafe(props), "timestamp": RIQ.now()])
    }

    func flushLocked() {
        guard var s = session, s.sampled, !optedOut, !stopped else {
            buffer.removeAll(); custom.removeAll(); bufferBytes = 0
            return
        }
        if createPending {
            enqueueCreate(s)
            createPending = false
        }
        if !buffer.isEmpty || !custom.isEmpty {
            let events = buffer.sorted { ($0["timestamp"] as? Int64 ?? 0) < ($1["timestamp"] as? Int64 ?? 0) }
            let c = custom
            buffer.removeAll(); custom.removeAll(); bufferBytes = 0
            for body in Recorder.encodeBatches(events, custom: c, session: &s, options: options) {
                Diagnostics.shared.add("batch_bytes", body.count)
                Diagnostics.shared.add("batches")
                queue.enqueue(path: "api/v1/events", body: body, kind: .events)
            }
        }
        if backgroundedAt == nil { s.lastActive = RIQ.now() }
        session = s
        store.save(s)
        uploader.kick()
    }

    /// Builds the `POST /api/v1/events` bodies, splitting past the size limit.
    static func encodeBatches(_ events: [[String: Any]], custom: [[String: Any]], session: inout SessionState,
                              options: ReplayIQOptions, maxBytes: Int = maxBatchBytes) -> [Data] {
        var body: [String: Any] = [
            "session_id": session.id,
            "project_id": session.key,
            "batch_id": session.nextBatchID(),
            "platform": options.platform,
            "sdk": options.sdkName,
            "device_masked": true,
            "flushed_at": RIQ.iso(RIQ.now()),
            "events": events,
        ]
        if !custom.isEmpty { body["custom_events"] = custom }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            RIQ.log("could not encode a batch")
            return []
        }
        if data.count <= maxBytes { return [data] }
        if events.count <= 1 {
            RIQ.log("dropping an event over the size limit")
            return []
        }
        session.seq -= 1 // reuse the id slot for the first half
        let mid = events.count / 2
        return encodeBatches(Array(events[..<mid]), custom: custom, session: &session, options: options, maxBytes: maxBytes)
            + encodeBatches(Array(events[mid...]), custom: [], session: &session, options: options, maxBytes: maxBytes)
    }

    private func enqueueCreate(_ s: SessionState) {
        let screen = UIScreenInfo.current
        var meta: [String: String] = options.metadata
        meta["platform"] = options.platform
        meta["os"] = "ios"
        meta["os_version"] = screen.osVersion
        meta["app_version"] = UIScreenInfo.appVersion
        meta["device"] = UIScreenInfo.deviceModel
        meta["sdk"] = options.sdkName
        meta["locale"] = Locale.current.identifier
        meta["text_scale"] = UIScreenInfo.current.textScale
        meta["screen_density"] = UIScreenInfo.current.density
        meta["recording_mode"] = ["auto", "native_dom", "screenshot"][options.recordingMode.rawValue]
        for (k, v) in traits { meta["user_\(k)"] = v }
        var body: [String: Any] = [
            "session_id": s.id,
            "project_id": s.key,
            "url": RIQ.appURL(firstScreen ?? ""),
            "user_agent": "\(options.sdkName) (\(UIScreenInfo.deviceModel); iOS \(screen.osVersion); \(RIQ.bundleID) \(UIScreenInfo.appVersion))",
            "screen_width": screen.width,
            "screen_height": screen.height,
            "sdk_version": options.sdkName,
            "started_at": RIQ.iso(s.startedAt),
            "metadata": meta,
        ]
        if let userId { body["user_id"] = userId }
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            queue.enqueue(path: "api/v1/sessions", body: data, kind: .session)
        }
    }

    private func enqueueEnd(_ s: SessionState) {
        let body: [String: Any] = [
            "session_id": s.id,
            "ended_at": RIQ.iso(s.lastActive),
            "duration_ms": max(0, s.lastActive - s.startedAt),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            queue.enqueue(path: "api/v1/sessions/\(s.id)/end", body: data, kind: .end)
        }
    }

    /// A crash from the previous run goes to the session it happened in.
    private func enqueueCrash(_ c: CrashReport) {
        let body: [String: Any] = [
            "session_id": c.sessionID,
            "project_id": key,
            "batch_id": "\(c.sessionID)-crash-\(c.timestamp)",
            "platform": options.platform,
            "sdk": options.sdkName,
            "device_masked": true,
            "flushed_at": RIQ.iso(RIQ.now()),
            "events": [c.event],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            queue.enqueue(path: "api/v1/events", body: data, kind: .events)
        }
    }

    static func jsonSafe(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in props {
            if JSONSerialization.isValidJSONObject(["v": v]) { out[k] = v } else { out[k] = "\(v)" }
        }
        return out
    }

    private func startFlushTimer() {
        let t = DispatchSource.makeTimerSource(queue: q)
        let i = max(1, options.flushInterval)
        t.schedule(deadline: .now() + i, repeating: i, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        flushTimer = t
    }

    // MARK: - App lifecycle (main thread)

    private func installHooks() {
        UIScreenInfo.capture()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.didEnterBackground()
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.willEnterForeground()
        })
        observers.append(nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.q.sync { self?.flushLocked() }
        })
        if options.captureScreens {
            let sr = ScreenRecorder(options: options)
            screens = sr
            if options.recordingMode == .screenshot {
                sr.start()
            } else {
                dom = DomRecorder(options: options, screens: sr, registry: assetRegistry)
                dom?.start()
            }
        }
        if options.captureSignals { Signals.install(options: options) }
        if options.captureTouches { TouchRecorder.install(options: options) }
        if options.trackViewControllers { NavigationTracker.install() }
        if options.captureNetwork {
            var hosts = Set(options.networkIgnoredHosts.map { $0.lowercased() })
            if let h = endpoint.host?.lowercased() { hosts.insert(h) }
            NetworkRecorder.install(ignoredHosts: hosts, includeQuery: options.networkIncludeQuery)
        }
        InputTracker.install()
    }

    private func didEnterBackground() {
        screens?.pause()
        dom?.pause()
        let app = UIApplication.shared
        var task: UIBackgroundTaskIdentifier = .invalid
        task = app.beginBackgroundTask(withName: "ReplayIQ flush") {
            app.endBackgroundTask(task)
            task = .invalid
        }
        q.async {
            self.backgroundedAt = RIQ.now()
            self.flushLocked()
            self.uploader.whenIdle(timeout: 25) {
                DispatchQueue.main.async {
                    if task != .invalid { app.endBackgroundTask(task); task = .invalid }
                }
            }
        }
    }

    private func willEnterForeground() {
        q.async {
            if let b = self.backgroundedAt {
                self.backgroundedAt = nil
                if RIQ.now() - b >= Int64(self.options.sessionTimeout * 1000) {
                    self.endSession(at: b)
                    self.beginSession()
                }
            }
        }
        if let dom { dom.resume() } else { screens?.resume() }
    }
}

/// Device facts for the session create request.
enum UIScreenInfo {
    struct Info {
        let width: Int
        let height: Int
        let osVersion: String
        var textScale = "1"
        var density = "1"
    }

    /// Read on the main thread when the SDK starts (never blocks on main later).
    private static let cached = Locked(Info(width: 0, height: 0, osVersion: osVersion))
    static var current: Info { cached.get }

    static func capture() {
        let b = UIScreen.main.bounds
        let scale = UIFontMetrics.default.scaledValue(for: 100) / 100
        cached.set(Info(width: Int(b.width), height: Int(b.height), osVersion: osVersion,
                        textScale: String(format: "%.2f", scale), density: String(format: "%.0f", UIScreen.main.scale)))
    }

    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }()

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "0"
        let b = info["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }()

    static let deviceModel: String = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()
}
