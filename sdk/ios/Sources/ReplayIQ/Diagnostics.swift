import Foundation

/// Counters describing what the SDK recorded and sent, for tuning and for
/// `ReplayIQ.diagnostics`. Thread-safe; cheap.
final class Diagnostics {
    static let shared = Diagnostics()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var samples: [String: [Double]] = [:]
    private var maxima: [String: Double] = [:]
    private var startedAt = Date()

    func add(_ key: String, _ n: Int = 1) {
        lock.lock(); counts[key, default: 0] += n; lock.unlock()
    }

    /// Keeps the last 5000 samples of a timing (ms).
    func sample(_ key: String, _ v: Double) {
        lock.lock()
        samples[key, default: []].append(v)
        if samples[key]!.count > 5000 { samples[key]!.removeFirst(1000) }
        if v > maxima[key, default: 0] { maxima[key] = v }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        counts.removeAll(); samples.removeAll(); maxima.removeAll()
        startedAt = Date()
        lock.unlock()
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Any] = ["seconds": Date().timeIntervalSince(startedAt)]
        for (k, v) in counts { out[k] = v }
        for (k, s) in samples where !s.isEmpty {
            let sorted = s.sorted()
            func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
            out[k] = ["n": s.count, "p50": pct(0.5), "p95": pct(0.95), "max": maxima[k] ?? 0]
        }
        return out
    }
}
