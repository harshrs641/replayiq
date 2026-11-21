import QuartzCore
import UIKit

/// Records the UI as a Native DOM (`ui_snapshot` / `ui_mutation`, recording
/// API v1.1). In `.auto` mode it hands a screen to the screenshot recorder
/// when most of it is islands (maps, video, games) and takes it back when
/// that screen goes away.
///
/// Scheduling: the tree is walked when something may have changed — after
/// touches, screen changes, network responses, keyboard and app events, and
/// every 33 ms (≤ 30/s) while anything animates or scrolls — and once a
/// second otherwise, to catch changes nobody announced. An unchanged tree
/// sends nothing.
final class DomRecorder {
    enum Mode { case dom, screens }

    static let activeInterval: CFTimeInterval = 1.0 / 30
    static let idleInterval: CFTimeInterval = 1.0
    static let snapshotInterval: Int64 = 30_000

    private let options: ReplayIQOptions
    private weak var screens: ScreenRecorder?
    private let walker: DomWalker
    private let q = DispatchQueue(label: "io.replayiq.dom", qos: .utility)

    // Main thread.
    private var timer: Timer?
    private var running = false
    private var busy = false
    private var activeUntil: CFTimeInterval = 0
    private var needSnapshot = true
    private var lastSize: CGSize = .zero
    private var lastRootID = 0
    private(set) var mode: Mode = .dom
    private var screensSince: CFTimeInterval = 0

    // DOM queue.
    private var tree = DomTree()
    private var hasTree = false
    private var lastSnapshotAt: Int64 = 0
    private let assets: DomAssets
    private var firstFrameSent = false
    private var scrolls: [Int: (so: [Double], changedAt: Int64, pending: Bool)] = [:]

    init(options: ReplayIQOptions, screens: ScreenRecorder?, registry: AssetRegistry?) {
        self.options = options
        self.screens = screens
        walker = DomWalker(options: options)
        assets = DomAssets(registry: registry) { enc in
            Recorder.shared?.enqueueAsset(hash: enc.hash, type: enc.type, data: enc.data)
            Diagnostics.shared.add("asset_uploads")
            Diagnostics.shared.add("asset_bytes", enc.data.count)
        }
    }

    // MARK: - Control (main thread)

    func start() {
        guard !running else { return }
        running = true
        needSnapshot = true
        schedule(0)
    }

    func pause() {
        running = false
        timer?.invalidate()
        timer = nil
        if mode == .screens { screens?.pause() }
    }

    /// After the app returns to the foreground or a new session starts.
    func resume() {
        needSnapshot = true
        if mode == .screens { screens?.resume() }
        start()
    }

    func requestSnapshot() {
        needSnapshot = true
        kick()
    }

    /// Something may have changed: walk soon and stay at full rate for a while.
    func kick(for seconds: CFTimeInterval = 1.5) {
        activeUntil = max(activeUntil, CACurrentMediaTime() + seconds)
        guard running else { return }
        if let t = timer, t.fireDate.timeIntervalSinceNow > DomRecorder.activeInterval { schedule(DomRecorder.activeInterval) }
        if timer == nil { schedule(DomRecorder.activeInterval) }
    }

    private func schedule(_ delay: CFTimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            self?.timer = nil
            self?.tick()
        }
        t.tolerance = delay > 0.5 ? 0.2 : 0.004
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func scheduleNext() {
        guard running else { return }
        let now = CACurrentMediaTime()
        schedule(now < activeUntil ? DomRecorder.activeInterval : DomRecorder.idleInterval)
    }

    private func tick() {
        guard running else { return }
        defer { scheduleNext() }
        guard let recorder = Recorder.shared, recorder.isRecording,
              UIApplication.shared.applicationState == .active,
              let window = ScreenRecorder.keyWindow() else { return }
        if busy { activeUntil = max(activeUntil, CACurrentMediaTime() + 0.1); return }

        let r = walker.walk(window)
        Diagnostics.shared.sample("walk_ms", r.duration * 1000)
        Diagnostics.shared.add("walks")
        if r.moving || r.deferred { activeUntil = max(activeUntil, CACurrentMediaTime() + 0.3) }

        if options.recordingMode == .auto && autoSwitch(r) { return }
        if mode == .screens { return }

        let size = CGSize(width: r.width, height: r.height)
        if size != lastSize || r.root.id != lastRootID { needSnapshot = true }
        lastSize = size
        lastRootID = r.root.id
        let snap = needSnapshot
        needSnapshot = false
        let density = window.screen.scale
        busy = true
        q.async { [weak self] in
            guard let self else { return }
            let changed = self.process(r, snapshot: snap, density: density)
            DispatchQueue.main.async {
                self.busy = false
                if changed { self.activeUntil = max(self.activeUntil, CACurrentMediaTime() + 1) }
            }
        }
    }

    /// `.auto`: screenshots for screens that are mostly islands.
    private func autoSwitch(_ r: DomWalker.Result) -> Bool {
        let now = CACurrentMediaTime()
        if mode == .dom, r.islandRatio > 0.5 {
            mode = .screens
            screensSince = now
            Diagnostics.shared.add("mode_switches")
            RIQ.log("screen is \(Int(r.islandRatio * 100))% islands: recording screenshots")
            screens?.resume()
            return true
        }
        if mode == .screens {
            if r.islandRatio < 0.35, now - screensSince > 1 {
                mode = .dom
                screens?.pause()
                needSnapshot = true
                Diagnostics.shared.add("mode_switches")
                RIQ.log("back to Native DOM recording")
                return false
            }
            return true
        }
        return false
    }

    // MARK: - Serialisation (DOM queue)

    /// Returns true when something was sent.
    private func process(_ r: DomWalker.Result, snapshot: Bool, density: CGFloat) -> Bool {
        let start = CACurrentMediaTime()
        let ts = RIQ.now()
        let new = DomTree(r.root) { self.own($0) }
        scrollSignals(new, ts: ts)
        var event: [String: Any]
        let sinceSnapshot = ts - lastSnapshotAt
        if snapshot || !hasTree {
            event = snapshotEvent(new, r: r, density: density, ts: ts)
        } else {
            let m = DomDiffer.diff(tree, new)
            if m.isEmpty {
                Diagnostics.shared.sample("diff_ms", (CACurrentMediaTime() - start) * 1000)
                return false
            }
            if sinceSnapshot >= DomRecorder.snapshotInterval {
                event = snapshotEvent(new, r: r, density: density, ts: ts)
            } else {
                event = ["type": 5, "subtype": "ui_mutation", "timestamp": ts]
                for (k, v) in m.json() { event[k] = v }
                Diagnostics.shared.add("ui_mutation")
            }
        }
        tree = new
        hasTree = true
        let bytes = (try? JSONSerialization.data(withJSONObject: event).count) ?? 1000
        Diagnostics.shared.sample("diff_ms", (CACurrentMediaTime() - start) * 1000)
        Diagnostics.shared.add("ui_bytes", bytes)
        Recorder.shared?.record(event, bytes: bytes)
        if !firstFrameSent {
            firstFrameSent = true
            DispatchQueue.main.async { Signals.shared?.firstFrame() }
        }
        Signals.shared?.frameCommitted(at: ts)
        return true
    }

    /// `scroll` once a scroll view has settled (300 ms without moving).
    private func scrollSignals(_ t: DomTree, ts: Int64) {
        var seen = Set<Int>()
        for (id, e) in t.entries {
            guard e.own["k"] as? String == "scroll", let so = e.own["so"] as? [Double] else { continue }
            seen.insert(id)
            if var s = scrolls[id] {
                if s.so != so {
                    s = (so, ts, true)
                } else if s.pending, ts - s.changedAt >= 300 {
                    s.pending = false
                    let role = e.own["role"] as? String ?? "scroll"
                    let sel = ElementSelector.format(role, e.own["label"] as? String)
                    Recorder.shared?.record(["type": 5, "subtype": "scroll", "timestamp": ts, "selector": sel,
                                             "x": so[0], "y": so[1]], bytes: 100)
                    Diagnostics.shared.add("signal_scroll")
                }
                scrolls[id] = s
            } else {
                scrolls[id] = (so, ts, false)
            }
        }
        scrolls = scrolls.filter { seen.contains($0.key) }
    }

    private func snapshotEvent(_ t: DomTree, r: DomWalker.Result, density: CGFloat, ts: Int64) -> [String: Any] {
        lastSnapshotAt = ts
        Diagnostics.shared.add("ui_snapshot")
        return ["type": 5, "subtype": "ui_snapshot", "timestamp": ts,
                "width": DomColor.round(r.width), "height": DomColor.round(r.height),
                "density": DomColor.round(density), "bg": DomColor.hex(r.bg), "root": t.root]
    }

    /// A node's own fields (the node minus `c`), resolving pixels to assets.
    private func own(_ n: DomNode) -> [String: Any] {
        var j: [String: Any] = [
            "id": n.id, "k": n.kind.rawValue,
            "f": [DomColor.round(n.frame.minX), DomColor.round(n.frame.minY),
                  DomColor.round(n.frame.width), DomColor.round(n.frame.height)],
        ]
        if let s = n.style.json() { j["s"] = s }
        if let role = n.role { j["role"] = role }
        if let label = n.label { j["label"] = label }
        if let t = n.text { j["tx"] = t.json() }
        if let i = n.input { j["in"] = i.json() }
        if let so = n.scrollOffset { j["so"] = [DomColor.round(so.x), DomColor.round(so.y)] }
        if let hint = n.hint { j["hint"] = hint }
        if let p = n.pixels, let h = assets.hash(p, points: n.frame.size) {
            var img: [String: Any] = ["a": h]
            if let fit = n.fit { img["fit"] = fit }
            j["img"] = img
        }
        return j
    }
}
