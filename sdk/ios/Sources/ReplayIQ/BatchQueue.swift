import Foundation

/// Requests waiting to be sent, persisted to disk so they survive an app kill
/// and go out on the next launch (recording API v1, "Errors and retries").
///
/// One file per request: the first line is the API path, the rest the JSON
/// body. Names sort in the order the requests were queued.
final class BatchQueue {
    enum Kind: String {
        case session, events, end, asset
    }

    struct Item: Equatable {
        let url: URL
        var name: String { url.lastPathComponent }
        var kind: Kind { Kind(rawValue: url.pathExtension) ?? .events }
        var base: String { url.deletingPathExtension().lastPathComponent }
    }

    let dir: URL
    /// Cap on queued event batches and assets (bytes on disk). The oldest are
    /// dropped past it; session create/end requests are always kept.
    let maxBytes: Int
    private let lock = NSLock()
    private var counter = 0

    init(dir: URL, maxBytes: Int = 5 * 1024 * 1024) {
        self.dir = dir
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func enqueue(path: String, body: Data, kind: Kind) -> Item? {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        let name = String(format: "%013lld-%06d.%@", RIQ.now(), counter % 1_000_000, kind.rawValue)
        let item = Item(url: dir.appendingPathComponent(name))
        guard write(item.url, path: path, body: body) else { return nil }
        enforceCapLocked()
        return item
    }

    func items() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        return itemsLocked()
    }

    func read(_ item: Item) -> (path: String, body: Data)? {
        guard let data = try? Data(contentsOf: item.url),
              let nl = data.firstIndex(of: 0x0a),
              let path = String(data: data[data.startIndex..<nl], encoding: .utf8) else { return nil }
        return (path, data.subdata(in: (nl + 1)..<data.endIndex))
    }

    func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
    }

    /// Replaces an item by several, keeping its place in the queue (413 split).
    func replace(_ item: Item, with parts: [(path: String, body: Data)]) {
        lock.lock(); defer { lock.unlock() }
        for (i, p) in parts.enumerated() {
            let url = dir.appendingPathComponent("\(item.base)-\(i + 1).\(item.kind.rawValue)")
            _ = write(url, path: p.path, body: p.body)
        }
        try? FileManager.default.removeItem(at: item.url)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        for i in itemsLocked() { try? FileManager.default.removeItem(at: i.url) }
    }

    private func write(_ url: URL, path: String, body: Data) -> Bool {
        var data = Data(path.utf8)
        data.append(0x0a)
        data.append(body)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            RIQ.log("could not persist batch: \(error)")
            return false
        }
    }

    private func itemsLocked() -> [Item] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { Kind(rawValue: ($0 as NSString).pathExtension) != nil }
            .sorted()
            .map { Item(url: dir.appendingPathComponent($0)) }
    }

    private func enforceCapLocked() {
        let events = itemsLocked().filter { $0.kind == .events || $0.kind == .asset }
        var sizes = events.map { (try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        var total = sizes.reduce(0, +)
        var i = 0
        while total > maxBytes, i < events.count - 1 { // never drop the newest
            try? FileManager.default.removeItem(at: events[i].url)
            total -= sizes[i]
            sizes[i] = 0
            i += 1
        }
        if i > 0 { RIQ.log("queue over \(maxBytes) bytes: dropped \(i) oldest batches") }
    }
}
