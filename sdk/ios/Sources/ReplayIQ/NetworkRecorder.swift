import Foundation

/// `network` events for the app's HTTP requests: URLProtocol registration
/// (URLSession.shared) plus the default and ephemeral session configurations.
/// Only method, URL, status, duration and error are recorded; never headers
/// or bodies.
enum NetworkRecorder {
    private static var installed = false
    static let ignoredHosts = Locked<Set<String>>([])
    static let includeQuery = Locked(false)

    static func install(ignoredHosts hosts: Set<String>, includeQuery q: Bool) {
        ignoredHosts.set(hosts)
        includeQuery.set(q)
        guard !installed else { return }
        installed = true
        URLProtocol.registerClass(ReplayIQURLProtocol.self)
        riqSwizzleClass(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.default),
                        #selector(getter: URLSessionConfiguration.riq_default))
        riqSwizzleClass(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.ephemeral),
                        #selector(getter: URLSessionConfiguration.riq_ephemeral))
    }

    static func shouldRecord(_ request: URLRequest) -> Bool {
        guard let url = request.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if let host = url.host?.lowercased(), ignoredHosts.get.contains(host) { return false }
        return true
    }

    static func displayURL(_ url: URL?) -> String {
        guard let url else { return "" }
        if includeQuery.get { return url.absoluteString }
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        return c.string ?? url.absoluteString
    }

    static func record(method: String, url: URL?, status: Int, start: Date, error: Error?) {
        var e: [String: Any] = [
            "type": 5, "subtype": "network", "timestamp": RIQ.now(),
            "method": method, "url": displayURL(url), "status": status,
            "duration": Int64(Date().timeIntervalSince(start) * 1000),
        ]
        if let error { e["error"] = (error as NSError).localizedDescription }
        Recorder.shared?.record(e, bytes: 200)
        Recorder.shared?.activity() // the response may change the UI
    }
}

extension URLSessionConfiguration {
    @objc class var riq_default: URLSessionConfiguration {
        let c = self.riq_default // the original getter
        c.protocolClasses = ReplayIQURLProtocol.prepend(c.protocolClasses)
        return c
    }

    @objc class var riq_ephemeral: URLSessionConfiguration {
        let c = self.riq_ephemeral
        c.protocolClasses = ReplayIQURLProtocol.prepend(c.protocolClasses)
        return c
    }
}

/// Times one request by running it on an inner session and relaying the
/// response, data and completion to the original loader.
public final class ReplayIQURLProtocol: URLProtocol {
    static let handledKey = "io.replayiq.handled"

    static func prepend(_ classes: [AnyClass]?) -> [AnyClass] {
        var list = (classes ?? []).filter { $0 != ReplayIQURLProtocol.self }
        list.insert(ReplayIQURLProtocol.self, at: 0)
        return list
    }

    private static let inner: InnerSession = InnerSession()

    private var innerTask: URLSessionDataTask?
    private var start = Date()
    private var finished = false
    let lock = NSLock()

    override public class func canInit(with request: URLRequest) -> Bool {
        guard Recorder.shared?.isRecording == true,
              URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        return NetworkRecorder.shouldRecord(request)
    }

    override public class func canInit(with task: URLSessionTask) -> Bool {
        // Upload/stream tasks keep their body outside the request: leave them alone.
        if task is URLSessionUploadTask || task is URLSessionStreamTask || task is URLSessionWebSocketTask { return false }
        guard let r = task.currentRequest ?? task.originalRequest else { return false }
        return canInit(with: r)
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        guard let m = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        URLProtocol.setProperty(true, forKey: ReplayIQURLProtocol.handledKey, in: m)
        start = Date()
        innerTask = ReplayIQURLProtocol.inner.start(m as URLRequest, for: self)
    }

    override public func stopLoading() {
        innerTask?.cancel()
        lock.lock()
        let done = finished
        finished = true
        lock.unlock()
        if !done {
            NetworkRecorder.record(method: request.httpMethod ?? "GET", url: request.url, status: 0, start: start,
                                   error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                                  userInfo: [NSLocalizedDescriptionKey: "cancelled"]))
        }
    }

    fileprivate func complete(response: URLResponse?, error: Error?) {
        lock.lock()
        let done = finished
        finished = true
        lock.unlock()
        if !done {
            NetworkRecorder.record(method: request.httpMethod ?? "GET", url: request.url,
                                   status: (response as? HTTPURLResponse)?.statusCode ?? 0, start: start,
                                   error: (response == nil || error != nil) ? error : nil)
        }
        if let error { client?.urlProtocol(self, didFailWithError: error) } else { client?.urlProtocolDidFinishLoading(self) }
    }

    /// One shared session for every intercepted request.
    fileprivate final class InnerSession: NSObject, URLSessionDataDelegate {
        private var session: URLSession!
        private let owners = Locked<[Int: ReplayIQURLProtocol]>([:])

        override init() {
            super.init()
            let config = URLSessionConfiguration.default
            config.protocolClasses = (config.protocolClasses ?? []).filter { $0 != ReplayIQURLProtocol.self }
            let q = OperationQueue()
            q.maxConcurrentOperationCount = 1
            q.name = "io.replayiq.network"
            session = URLSession(configuration: config, delegate: self, delegateQueue: q)
        }

        func start(_ request: URLRequest, for owner: ReplayIQURLProtocol) -> URLSessionDataTask {
            let t = session.dataTask(with: request)
            owners.mutate { $0[t.taskIdentifier] = owner }
            t.resume()
            return t
        }

        private func owner(_ t: URLSessionTask) -> ReplayIQURLProtocol? { owners.get[t.taskIdentifier] }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let o = owner(dataTask) {
                o.client?.urlProtocol(o, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if let o = owner(dataTask) { o.client?.urlProtocol(o, didLoad: data) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let o = owners.mutate { $0.removeValue(forKey: task.taskIdentifier) }
            o?.complete(response: task.response, error: error)
        }
    }
}
