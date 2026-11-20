import UIKit
import XCTest
@testable import ReplayIQ

final class GzipTests: XCTestCase {
    func testRoundTrip() throws {
        let text = String(repeating: "{\"type\":5,\"subtype\":\"touch\"}", count: 500)
        let data = Data(text.utf8)
        let gz = try XCTUnwrap(Gzip.compress(data))
        XCTAssertEqual(Array(gz.prefix(3)), [0x1f, 0x8b, 0x08])
        XCTAssertLessThan(gz.count, data.count / 5)
        XCTAssertEqual(Gzip.decompress(gz), data)
    }

    func testCRC32KnownValue() {
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testEmptyAndRandom() throws {
        XCTAssertNotNil(Gzip.compress(Data()))
        let random = Data((0..<10_000).map { _ in UInt8.random(in: 0...255) })
        let gz = try XCTUnwrap(Gzip.compress(random))
        XCTAssertEqual(Gzip.decompress(gz), random)
    }
}

final class SessionTests: XCTestCase {
    func testBatchIDsAreSequentialAndStable() {
        var s = SessionState.new(key: "k", now: 0, sampleRate: 1, random: { 0.5 })
        XCTAssertEqual(s.nextBatchID(), "\(s.id)-000001")
        XCTAssertEqual(s.nextBatchID(), "\(s.id)-000002")
    }

    func testSampling() {
        XCTAssertTrue(SessionState.sample(1, random: { 0.99 }))
        XCTAssertFalse(SessionState.sample(0, random: { 0 }))
        XCTAssertTrue(SessionState.sample(0.5, random: { 0.2 }))
        XCTAssertFalse(SessionState.sample(0.5, random: { 0.7 }))
    }

    func testSessionTimeout() {
        let s = SessionState.new(key: "k", now: 1_000, sampleRate: 1, random: { 0 })
        XCTAssertTrue(s.isLive(now: 1_000 + 29 * 60_000, key: "k", timeout: 1800))
        XCTAssertFalse(s.isLive(now: 1_000 + 31 * 60_000, key: "k", timeout: 1800))
        XCTAssertFalse(s.isLive(now: 1_000, key: "other", timeout: 1800))
    }

    func testStorePersists() {
        let dir = tempDir()
        let store = SessionStore(dir: dir)
        var s = SessionState.new(key: "k", now: 5, sampleRate: 1, random: { 0 })
        _ = s.nextBatchID()
        store.save(s)
        XCTAssertEqual(SessionStore(dir: dir).load(), s)
        store.save(nil)
        XCTAssertNil(store.load())
    }

    func testEncodeBatchShape() throws {
        var s = SessionState.new(key: "proj", now: 0, sampleRate: 1, random: { 0 })
        let events: [[String: Any]] = [["type": 5, "subtype": "touch", "timestamp": Int64(1), "x": 1.0, "y": 2.0, "phase": "down"]]
        let bodies = Recorder.encodeBatches(events, custom: [["name": "x", "properties": [:], "timestamp": Int64(1)]],
                                            session: &s, options: ReplayIQOptions())
        XCTAssertEqual(bodies.count, 1)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        XCTAssertEqual(obj["session_id"] as? String, s.id)
        XCTAssertEqual(obj["project_id"] as? String, "proj")
        XCTAssertEqual(obj["batch_id"] as? String, "\(s.id)-000001")
        XCTAssertEqual(obj["device_masked"] as? Bool, true)
        XCTAssertEqual(obj["platform"] as? String, "ios")
        XCTAssertEqual(obj["sdk"] as? String, "replayiq-ios/\(RIQ.version)")
        XCTAssertNotNil(obj["flushed_at"] as? String)
        XCTAssertEqual((obj["events"] as? [Any])?.count, 1)
        XCTAssertEqual((obj["custom_events"] as? [Any])?.count, 1)
    }

    func testEncodeSplitsLargeBatches() throws {
        var s = SessionState.new(key: "p", now: 0, sampleRate: 1, random: { 0 })
        let big = String(repeating: "a", count: 400)
        let events: [[String: Any]] = (0..<10).map { ["type": 5, "subtype": "screen", "timestamp": Int64($0), "image": big] }
        let bodies = Recorder.encodeBatches(events, custom: [], session: &s, options: ReplayIQOptions(), maxBytes: 1500)
        XCTAssertGreaterThan(bodies.count, 1)
        let ids = try bodies.map { try XCTUnwrap((JSONSerialization.jsonObject(with: $0) as? [String: Any])?["batch_id"] as? String) }
        XCTAssertEqual(Set(ids).count, ids.count)
        let total = try bodies.map { try XCTUnwrap(((JSONSerialization.jsonObject(with: $0) as? [String: Any])?["events"] as? [Any])?.count) }.reduce(0, +)
        XCTAssertEqual(total, 10)
        XCTAssertTrue(bodies.allSatisfy { $0.count <= 1500 })
    }
}

final class FramePolicyTests: XCTestCase {
    func testKeyframeRules() {
        var p = FramePolicy()
        let size = CGSize(width: 393, height: 852)
        var d = p.decide(hash: 1, size: size, at: 1_000)
        XCTAssertEqual(d, .keyframe, "first frame")
        p.commit(d, hash: 1, size: size, at: 1_000)

        XCTAssertEqual(p.decide(hash: 1, size: size, at: 1_500), .skip, "unchanged")
        d = p.decide(hash: 2, size: size, at: 2_000)
        XCTAssertEqual(d, .delta)
        p.commit(d, hash: 2, size: size, at: 2_000)

        d = p.decide(hash: 2, size: CGSize(width: 852, height: 393), at: 2_500)
        XCTAssertEqual(d, .keyframe, "size change")
        p.commit(d, hash: 2, size: CGSize(width: 852, height: 393), at: 2_500)

        XCTAssertEqual(p.decide(hash: 2, size: CGSize(width: 852, height: 393), at: 2_500 + 30_000), .keyframe, "every 30 s")

        p.forceKeyframe = true
        XCTAssertEqual(p.decide(hash: 2, size: CGSize(width: 852, height: 393), at: 3_000), .keyframe, "after resume")
    }
}

final class RageTests: XCTestCase {
    func testRageClick() {
        var r = RageDetector()
        XCTAssertFalse(r.tap(CGPoint(x: 10, y: 10), at: 0))
        XCTAssertFalse(r.tap(CGPoint(x: 20, y: 15), at: 200))
        XCTAssertTrue(r.tap(CGPoint(x: 15, y: 12), at: 400))
        XCTAssertFalse(r.tap(CGPoint(x: 15, y: 12), at: 500), "once per burst")
    }

    func testNotRageWhenSlowOrFar() {
        var r = RageDetector()
        XCTAssertFalse(r.tap(CGPoint(x: 10, y: 10), at: 0))
        XCTAssertFalse(r.tap(CGPoint(x: 10, y: 10), at: 800))
        XCTAssertFalse(r.tap(CGPoint(x: 200, y: 10), at: 900))
        XCTAssertFalse(r.tap(CGPoint(x: 10, y: 10), at: 1_000))
        XCTAssertFalse(r.tap(CGPoint(x: 12, y: 10), at: 1_100))
        XCTAssertTrue(r.tap(CGPoint(x: 14, y: 10), at: 1_200))
    }
}

final class QueueAndUploaderTests: XCTestCase {
    final class FakeClient: HTTPClient {
        var statuses: [Int]
        var headers: [AnyHashable: Any] = [:]
        private(set) var requests: [URLRequest] = []
        let lock = NSLock()
        init(_ statuses: [Int]) { self.statuses = statuses }
        func send(_ request: URLRequest, completion: @escaping (Int, [AnyHashable: Any], Error?) -> Void) {
            lock.lock()
            requests.append(request)
            let s = statuses.isEmpty ? 202 : statuses.removeFirst()
            lock.unlock()
            completion(s, s == 429 ? headers : [:], s == 0 ? URLError(.notConnectedToInternet) : nil)
        }
        var batchIDs: [String] {
            lock.lock(); defer { lock.unlock() }
            return requests.compactMap { r in
                guard let b = r.httpBody, let d = Gzip.decompress(b),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
                return o["batch_id"] as? String
            }
        }
    }

    func body(_ id: String, events: Int = 2) -> Data {
        let ev = (0..<events).map { ["type": 5, "timestamp": $0] }
        return try! JSONSerialization.data(withJSONObject: ["batch_id": id, "events": ev])
    }

    func makeUploader(_ client: FakeClient, queue: BatchQueue, delays: Locked<[TimeInterval]>, unauthorized: (() -> Void)? = nil) -> Uploader {
        Uploader(queue: queue, client: client, endpoint: URL(string: "http://localhost:8080")!, key: "secret",
                 after: { d, work in delays.mutate { $0.append(d) }; DispatchQueue.global().async(execute: work) },
                 onUnauthorized: unauthorized ?? {})
    }

    func drain(_ u: Uploader) {
        let e = expectation(description: "idle")
        u.whenIdle(timeout: 5) { e.fulfill() }
        wait(for: [e], timeout: 10)
    }

    func testQueueOrderAndPersistence() {
        let dir = tempDir()
        let q = BatchQueue(dir: dir)
        q.enqueue(path: "api/v1/sessions", body: Data("{}".utf8), kind: .session)
        q.enqueue(path: "api/v1/events", body: body("a"), kind: .events)
        let reopened = BatchQueue(dir: dir)
        XCTAssertEqual(reopened.items().map(\.kind), [.session, .events])
        XCTAssertEqual(reopened.read(reopened.items()[1])?.path, "api/v1/events")
    }

    func testQueueCapDropsOldestEventBatchesOnly() {
        let q = BatchQueue(dir: tempDir(), maxBytes: 2_500)
        q.enqueue(path: "api/v1/sessions", body: Data(repeating: 0x20, count: 2_000), kind: .session)
        for i in 0..<5 { q.enqueue(path: "api/v1/events", body: Data(repeating: 0x20, count: 1_000 + i), kind: .events) }
        let items = q.items()
        XCTAssertEqual(items.first?.kind, .session)
        XCTAssertEqual(items.filter { $0.kind == .events }.count, 2)
    }

    func testSendsWithAuthAndGzipThenDrops() throws {
        let q = BatchQueue(dir: tempDir())
        q.enqueue(path: "api/v1/events", body: body("b1"), kind: .events)
        let client = FakeClient([202])
        let u = makeUploader(client, queue: q, delays: Locked([]))
        drain(u)
        let r = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(r.url?.absoluteString, "http://localhost:8080/api/v1/events")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertTrue(q.items().isEmpty)
    }

    func testRetriesWithBackoffAndSameBatchID() {
        let q = BatchQueue(dir: tempDir())
        q.enqueue(path: "api/v1/events", body: body("b7"), kind: .events)
        let client = FakeClient([503, 0, 500, 202])
        let delays = Locked<[TimeInterval]>([])
        let u = makeUploader(client, queue: q, delays: delays)
        drain(u)
        XCTAssertEqual(client.batchIDs, ["b7", "b7", "b7", "b7"])
        XCTAssertEqual(delays.get, [1, 2, 4])
        XCTAssertTrue(q.items().isEmpty)
    }

    func testBackoffCaps() {
        XCTAssertEqual(Uploader.backoff(0), 1)
        XCTAssertEqual(Uploader.backoff(5), 32)
        XCTAssertEqual(Uploader.backoff(6), 60)
        XCTAssertEqual(Uploader.backoff(20), 60)
    }

    func test400Drops() {
        let q = BatchQueue(dir: tempDir())
        q.enqueue(path: "api/v1/events", body: body("bad"), kind: .events)
        q.enqueue(path: "api/v1/events", body: body("good"), kind: .events)
        let client = FakeClient([400, 202])
        drain(makeUploader(client, queue: q, delays: Locked([])))
        XCTAssertEqual(client.batchIDs, ["bad", "good"])
        XCTAssertTrue(q.items().isEmpty)
    }

    func test401Halts() {
        let q = BatchQueue(dir: tempDir())
        q.enqueue(path: "api/v1/events", body: body("x"), kind: .events)
        q.enqueue(path: "api/v1/events", body: body("y"), kind: .events)
        let client = FakeClient([401])
        var called = false
        let u = makeUploader(client, queue: q, delays: Locked([]), unauthorized: { called = true })
        drain(u)
        XCTAssertTrue(called)
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(q.items().count, 2, "kept for a later run")
    }

    func test413Splits() {
        let q = BatchQueue(dir: tempDir())
        q.enqueue(path: "api/v1/events", body: body("big", events: 4), kind: .events)
        let client = FakeClient([413, 202, 202])
        drain(makeUploader(client, queue: q, delays: Locked([])))
        XCTAssertEqual(client.batchIDs, ["big", "big.1", "big.2"])
        XCTAssertTrue(q.items().isEmpty)
    }

    func test429UsesRetryAfter() {
        let q = BatchQueue(dir: tempDir())
        q.enqueue(path: "api/v1/events", body: body("r"), kind: .events)
        let client = FakeClient([429, 202])
        client.headers = ["Retry-After": "7"]
        let delays = Locked<[TimeInterval]>([])
        drain(makeUploader(client, queue: q, delays: delays))
        XCTAssertEqual(delays.get, [7])
        XCTAssertEqual(client.batchIDs, ["r", "r"])
    }
}

final class MaskingAndSelectorTests: XCTestCase {
    func testMasksInputsSecureAndMarkedViews() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let field = UITextField(frame: CGRect(x: 10, y: 10, width: 200, height: 40))
        let secure = UITextField(frame: CGRect(x: 10, y: 60, width: 200, height: 40))
        secure.isSecureTextEntry = true
        let label = UILabel(frame: CGRect(x: 10, y: 110, width: 200, height: 20))
        let card = UIView(frame: CGRect(x: 10, y: 140, width: 300, height: 100))
        card.replayIQMasked = true
        let inside = UITextField(frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        card.addSubview(inside)
        let hidden = UITextField(frame: CGRect(x: 10, y: 300, width: 100, height: 40))
        hidden.isHidden = true
        [field, secure, label, card, hidden].forEach(window.addSubview)

        let all = Masking.rects(in: window, maskTextInputs: true, maskAllText: false)
        XCTAssertEqual(all.count, 3) // field, secure, card (inside is covered by card)
        XCTAssertTrue(all.contains { $0.contains(CGPoint(x: 100, y: 30)) })
        XCTAssertTrue(all.contains { $0.contains(CGPoint(x: 100, y: 190)) })

        let secureOnly = Masking.rects(in: window, maskTextInputs: false, maskAllText: false)
        XCTAssertEqual(secureOnly.count, 2) // secure + card

        let withText = Masking.rects(in: window, maskTextInputs: true, maskAllText: true)
        XCTAssertEqual(withText.count, 4)
    }

    func testSelectors() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let button = UIButton(type: .system)
        button.setTitle("Pay now", for: .normal)
        button.frame = CGRect(x: 0, y: 0, width: 100, height: 44)
        window.addSubview(button)
        XCTAssertEqual(ElementSelector.selector(for: button, at: .zero, in: window, masked: false), "button:\"Pay now\"")
        XCTAssertEqual(ElementSelector.selector(for: button, at: .zero, in: window, masked: true), "button")

        let field = UITextField()
        field.placeholder = "Email"
        field.text = "secret@example.com"
        XCTAssertEqual(ElementSelector.format(ElementSelector.role(of: field), ElementSelector.label(of: field)), "textfield:\"Email\"")
        field.isSecureTextEntry = true
        XCTAssertEqual(ElementSelector.role(of: field), "password")
    }

    func testScreenNames() {
        XCTAssertNil(NavigationTracker.screenName(UINavigationController()))
        let vc = UIViewController()
        XCTAssertNil(NavigationTracker.screenName(vc), "system class")
        vc.replayIQScreenName = "Cart"
        XCTAssertEqual(NavigationTracker.screenName(vc), "Cart")
    }
}

final class NetworkAndCrashTests: XCTestCase {
    func testNetworkFilters() {
        NetworkRecorder.ignoredHosts.set(["ingest.example.com"])
        XCTAssertFalse(NetworkRecorder.shouldRecord(URLRequest(url: URL(string: "https://ingest.example.com/api/v1/events")!)))
        XCTAssertTrue(NetworkRecorder.shouldRecord(URLRequest(url: URL(string: "https://api.example.com/cart")!)))
        XCTAssertFalse(NetworkRecorder.shouldRecord(URLRequest(url: URL(string: "file:///tmp/x")!)))
        NetworkRecorder.includeQuery.set(false)
        XCTAssertEqual(NetworkRecorder.displayURL(URL(string: "https://u:p@api.example.com/a?token=1#f")), "https://api.example.com/a")
    }

    func testConfigurationsGetTheProtocol() {
        NetworkRecorder.install(ignoredHosts: [], includeQuery: false)
        let c = URLSessionConfiguration.default
        XCTAssertTrue(c.protocolClasses?.first == ReplayIQURLProtocol.self)
        XCTAssertTrue(URLSessionConfiguration.ephemeral.protocolClasses?.first == ReplayIQURLProtocol.self)
    }

    func testSignalReportParsing() throws {
        let r = try XCTUnwrap(CrashReporter.parseSignalReport("sess-1\n1794995702120\n11\n0 App 0x1 main\n1 libdyld 0x2 start\n"))
        XCTAssertEqual(r.sessionID, "sess-1")
        XCTAssertEqual(r.timestamp, 1_794_995_702_120)
        XCTAssertEqual(r.event["subtype"] as? String, "js_error")
        XCTAssertEqual(r.event["message"] as? String, "Fatal signal SIGSEGV")
        XCTAssertEqual((r.event["stack"] as? String)?.components(separatedBy: "\n").count, 2)
        XCTAssertNil(CrashReporter.parseSignalReport("\n1\n11\n"))
    }

    func testCollectReadsAndDeletesExceptionReport() throws {
        let dir = tempDir()
        let obj: [String: Any] = ["session_id": "s9", "timestamp": 42, "message": "NSRangeException: out of bounds", "stack": "a\nb"]
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("crash-exception.json"))
        let reports = CrashReporter.collect(dir: dir)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].sessionID, "s9")
        XCTAssertEqual(reports[0].event["message"] as? String, "NSRangeException: out of bounds")
        XCTAssertTrue(CrashReporter.collect(dir: dir).isEmpty)
    }
}

func tempDir() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("riq-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
