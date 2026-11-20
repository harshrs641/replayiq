import Foundation

/// The current session, persisted so a relaunch within the session timeout
/// continues it (and batch ids keep increasing).
struct SessionState: Codable, Equatable {
    var id: String
    var key: String
    var startedAt: Int64
    var lastActive: Int64
    var seq: Int
    /// Decided once per session, before anything is recorded.
    var sampled: Bool

    static func new(key: String, now: Int64, sampleRate: Double, random: () -> Double) -> SessionState {
        SessionState(id: UUID().uuidString.lowercased(), key: key, startedAt: now, lastActive: now,
                     seq: 0, sampled: SessionState.sample(sampleRate, random: random))
    }

    static func sample(_ rate: Double, random: () -> Double) -> Bool {
        if rate >= 1 { return true }
        if rate <= 0 { return false }
        return random() < rate
    }

    /// Whether a stored session may be continued at `now`.
    func isLive(now: Int64, key: String, timeout: TimeInterval) -> Bool {
        self.key == key && now - lastActive < Int64(timeout * 1000)
    }

    /// `<session_id>-<sequence>`, the same on every retry of that batch.
    mutating func nextBatchID() -> String {
        seq += 1
        return String(format: "%@-%06d", id, seq)
    }
}

final class SessionStore {
    private let url: URL
    init(dir: URL) { url = dir.appendingPathComponent("session.json") }

    func load() -> SessionState? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: d)
    }

    func save(_ s: SessionState?) {
        guard let s else { try? FileManager.default.removeItem(at: url); return }
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }
}
