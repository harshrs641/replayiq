import Foundation

/// Sends HTTP requests; a protocol so tests can fake the server.
protocol HTTPClient {
    /// status 0 means no response arrived (error set).
    func send(_ request: URLRequest, completion: @escaping (_ status: Int, _ headers: [AnyHashable: Any], _ error: Error?) -> Void)
}

final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        // The network recorder adds itself to new configurations: never record
        // (or loop through) our own uploads.
        config.protocolClasses = (config.protocolClasses ?? []).filter { $0 != ReplayIQURLProtocol.self }
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest, completion: @escaping (Int, [AnyHashable: Any], Error?) -> Void) {
        let m = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: ReplayIQURLProtocol.handledKey, in: m)
        session.dataTask(with: m as URLRequest) { _, response, error in
            let http = response as? HTTPURLResponse
            completion(http?.statusCode ?? 0, http?.allHeaderFields ?? [:], error)
        }.resume()
    }
}

/// Drains the BatchQueue in order, one request at a time, applying the
/// recording API's retry table:
///
/// | 2xx, 400 | drop | 401/403 | stop for this run | 413 | split and resend |
/// | 429 | wait Retry-After | 5xx / network | backoff 1 s, 2 s, 4 s ... 60 s |
final class Uploader {
    let queue: BatchQueue
    private let client: HTTPClient
    private let endpoint: URL
    private let key: String
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let onUnauthorized: () -> Void
    /// Assets the server has (set by the recorder; nil in tests that don't care).
    var registry: AssetRegistry?
    private let q = DispatchQueue(label: "io.replayiq.upload", qos: .utility)

    private var inFlight = false
    private var waiting = false
    private(set) var halted = false
    private var attempt = 0
    private var idleWaiters: [() -> Void] = []

    init(queue: BatchQueue, client: HTTPClient, endpoint: URL, key: String,
         after: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
         onUnauthorized: @escaping () -> Void = {}) {
        self.queue = queue
        self.client = client
        self.endpoint = endpoint
        self.key = key
        self.onUnauthorized = onUnauthorized
        let q = self.q
        self.after = after ?? { delay, work in q.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    /// Backoff for the n-th consecutive failure (0-based): 1, 2, 4 ... 60 s.
    static func backoff(_ attempt: Int) -> TimeInterval {
        min(60, pow(2, Double(min(attempt, 6))))
    }

    func kick() { q.async { self.pump() } }

    /// Calls `done` once nothing is queued or sending (or after `timeout`).
    func whenIdle(timeout: TimeInterval, _ done: @escaping () -> Void) {
        q.async {
            var called = false
            let once = { if !called { called = true; done() } }
            if self.isIdleLocked { once(); return }
            self.idleWaiters.append(once)
            self.q.asyncAfter(deadline: .now() + timeout) { once() }
            self.pump()
        }
    }

    private var isIdleLocked: Bool { !inFlight && (halted || queue.items().isEmpty) }

    private func notifyIdle() {
        guard isIdleLocked else { return }
        let w = idleWaiters
        idleWaiters.removeAll()
        w.forEach { $0() }
    }

    private func pump() {
        guard !inFlight, !waiting, !halted else { return }
        guard let item = queue.items().first else { notifyIdle(); return }
        guard let (path, body) = queue.read(item) else {
            queue.remove(item)
            return pump()
        }
        if item.kind == .asset { return sendAsset(item, line: path, body: body) }
        var req = URLRequest(url: endpoint.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let gz = Gzip.compress(body) {
            req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            req.httpBody = gz
            if item.kind == .events { Diagnostics.shared.add("batch_bytes_gzip", gz.count) }
        } else {
            req.httpBody = body
        }
        inFlight = true
        client.send(req) { [weak self] status, headers, error in
            self?.q.async { self?.handle(item, body: body, path: path, status: status, headers: headers, error: error) }
        }
    }

    /// Assets: `HEAD /api/v1/assets/<hash>` first, then `POST /api/v1/assets`
    /// (raw bytes, X-Asset-Hash) when the server doesn't have it.
    private func sendAsset(_ item: BatchQueue.Item, line: String, body: Data) {
        let parts = line.split(separator: "|").map(String.init)
        guard parts.count == 3 else { queue.remove(item); return pump() }
        let (path, type, hash) = (parts[0], parts[1], parts[2])
        if registry?.isKnown(hash) == true {
            queue.remove(item)
            return pump()
        }
        var head = URLRequest(url: endpoint.appendingPathComponent(path).appendingPathComponent(hash))
        head.httpMethod = "HEAD"
        head.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        inFlight = true
        client.send(head) { [weak self] status, _, _ in
            guard let self else { return }
            self.q.async {
                if status == 200 {
                    self.inFlight = false
                    self.attempt = 0
                    self.registry?.markUploaded(hash)
                    self.queue.remove(item)
                    return self.pump()
                }
                var req = URLRequest(url: self.endpoint.appendingPathComponent(path))
                req.httpMethod = "POST"
                req.setValue(type, forHTTPHeaderField: "Content-Type")
                req.setValue(hash, forHTTPHeaderField: "X-Asset-Hash")
                req.setValue("Bearer \(self.key)", forHTTPHeaderField: "Authorization")
                req.httpBody = body
                self.client.send(req) { [weak self] status, headers, error in
                    self?.q.async {
                        if (200..<300).contains(status) { self?.registry?.markUploaded(hash) }
                        self?.handle(item, body: body, path: path, status: status, headers: headers, error: error)
                    }
                }
            }
        }
    }

    private func handle(_ item: BatchQueue.Item, body: Data, path: String, status: Int, headers: [AnyHashable: Any], error: Error?) {
        inFlight = false
        switch status {
        case 200..<300:
            attempt = 0
            queue.remove(item)
        case 401, 403:
            RIQ.log("ingest key rejected (\(status)): recording stopped for this run")
            halted = true
            onUnauthorized()
            notifyIdle()
            return
        case 413:
            attempt = 0
            if let parts = Uploader.split(body), item.kind == .events {
                queue.replace(item, with: parts.map { (path, $0) })
            } else {
                RIQ.log("dropping a batch the server says is too large")
                queue.remove(item)
            }
        case 429:
            let retry = Uploader.retryAfter(headers) ?? Uploader.backoff(attempt)
            attempt += 1
            return wait(retry)
        case 0, 500..<600:
            let delay = Uploader.backoff(attempt)
            attempt += 1
            RIQ.log("upload failed (\(status) \(error?.localizedDescription ?? "")): retry in \(delay)s")
            return wait(delay)
        default: // 400 and any other client error: retrying won't help.
            RIQ.log("server rejected a batch (\(status)): dropped")
            attempt = 0
            queue.remove(item)
        }
        pump()
    }

    private func wait(_ delay: TimeInterval) {
        waiting = true
        after(delay) { [weak self] in
            guard let self else { return }
            self.q.async { self.waiting = false; self.pump() }
        }
    }

    static func retryAfter(_ headers: [AnyHashable: Any]) -> TimeInterval? {
        for (k, v) in headers where (k as? String)?.lowercased() == "retry-after" {
            if let s = v as? String, let n = Double(s.trimmingCharacters(in: .whitespaces)) { return max(0, n) }
            if let n = v as? NSNumber { return n.doubleValue }
        }
        return nil
    }

    /// Splits an events batch in two halves with derived batch ids, or nil
    /// when it holds a single event.
    static func split(_ body: Data) -> [Data]? {
        guard var obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let events = obj["events"] as? [Any], events.count > 1 else { return nil }
        let id = obj["batch_id"] as? String ?? UUID().uuidString
        let mid = events.count / 2
        let custom = obj["custom_events"]
        var out: [Data] = []
        for (i, part) in [Array(events[..<mid]), Array(events[mid...])].enumerated() {
            obj["events"] = part
            obj["batch_id"] = "\(id).\(i + 1)"
            obj["custom_events"] = i == 0 ? custom : nil
            guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
            out.append(d)
        }
        return out
    }
}
