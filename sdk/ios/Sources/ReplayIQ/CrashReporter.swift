import Darwin
import Foundation

/// A crash recorded by the previous run, sent as `js_error` on this launch.
struct CrashReport {
    let sessionID: String
    let timestamp: Int64
    let event: [String: Any]
}

// State used inside the signal handler: allocated up front, plain C memory,
// so the handler only calls async-signal-safe functions.
private var riqSignalPath: UnsafeMutablePointer<CChar>?
private let riqSessionBuf: UnsafeMutablePointer<CChar> = {
    let p = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
    p.initialize(repeating: 0, count: 64)
    return p
}()
private var riqSessionLen: Int = 0
private var riqExceptionHandled: Int32 = 0
private let riqNumBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 32)
private let riqFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
private let riqPrevious = UnsafeMutablePointer<sigaction>.allocate(capacity: Int(NSIG))
private var riqPreviousExceptionHandler: (@convention(c) (NSException) -> Void)?
private let riqSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

private func riqWriteNumber(_ fd: Int32, _ value: Int64) {
    var v = value
    var n = 0
    if v == 0 { riqNumBuf[0] = 0x30; n = 1 }
    while v > 0 && n < 30 { riqNumBuf[n] = CChar(0x30 + Int(v % 10)); v /= 10; n += 1 }
    var i = 0, j = n - 1
    while i < j { let t = riqNumBuf[i]; riqNumBuf[i] = riqNumBuf[j]; riqNumBuf[j] = t; i += 1; j -= 1 }
    riqNumBuf[n] = 0x0a
    _ = write(fd, riqNumBuf, n + 1)
}

private let riqSignalHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { sig, _, _ in
    if riqExceptionHandled == 0, riqSessionLen > 0, let path = riqSignalPath {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            _ = write(fd, riqSessionBuf, riqSessionLen)
            riqNumBuf[0] = 0x0a
            _ = write(fd, riqNumBuf, 1)
            var ts = timespec()
            clock_gettime(CLOCK_REALTIME, &ts)
            riqWriteNumber(fd, Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000)
            riqWriteNumber(fd, Int64(sig))
            let n = backtrace(riqFrames, 128)
            backtrace_symbols_fd(riqFrames, n, fd)
            close(fd)
        }
    }
    // Hand the signal to whoever was installed before us (or the default).
    sigaction(sig, riqPrevious.advanced(by: Int(sig)), nil)
    raise(sig)
}

enum CrashReporter {
    private static var installed = false

    private static func paths(_ dir: URL) -> (signal: URL, exception: URL) {
        (dir.appendingPathComponent("crash-signal.txt"), dir.appendingPathComponent("crash-exception.json"))
    }

    private static var exceptionPath: String = ""

    static func install(dir: URL) {
        guard !installed else { return }
        installed = true
        let p = paths(dir)
        riqSignalPath = strdup(p.signal.path)
        exceptionPath = p.exception.path
        _ = riqSessionBuf; _ = riqNumBuf; _ = riqFrames; _ = riqSignals

        riqPreviousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { e in
            riqExceptionHandled = 1
            CrashReporter.writeException(e)
            riqPreviousExceptionHandler?(e)
        }

        // An alternate stack so a stack overflow can still be reported.
        let size = 64 * 1024
        var ss = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16), ss_size: size, ss_flags: 0)
        sigaltstack(&ss, nil)
        for sig in riqSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = riqSignalHandler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, riqPrevious.advanced(by: Int(sig)))
        }
    }

    /// The session crashes are attributed to (nil: not recording).
    static func setSession(_ id: String?) {
        let bytes = Array((id ?? "").utf8.prefix(63))
        riqSessionLen = 0
        for (i, b) in bytes.enumerated() { riqSessionBuf[i] = CChar(bitPattern: b) }
        riqSessionBuf[bytes.count] = 0
        riqSessionLen = bytes.count
    }

    private static func writeException(_ e: NSException) {
        guard riqSessionLen > 0 else { return }
        let obj: [String: Any] = [
            "session_id": String(cString: riqSessionBuf),
            "timestamp": RIQ.now(),
            "message": "\(e.name.rawValue): \(e.reason ?? "")",
            "stack": e.callStackSymbols.joined(separator: "\n"),
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            FileManager.default.createFile(atPath: exceptionPath, contents: d)
        }
    }

    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "signal \(sig)"
        }
    }

    private static var binaryName: String {
        Bundle.main.executableURL?.lastPathComponent ?? "app"
    }

    static func event(message: String, stack: String, at ts: Int64) -> [String: Any] {
        ["type": 5, "subtype": "js_error", "timestamp": ts, "message": message,
         "filename": binaryName, "lineno": 0, "colno": 0, "stack": stack]
    }

    /// Reads (and deletes) the reports left by the previous run.
    static func collect(dir: URL) -> [CrashReport] {
        let p = paths(dir)
        var out: [CrashReport] = []
        if let d = try? Data(contentsOf: p.exception),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let sid = obj["session_id"] as? String, !sid.isEmpty {
            let ts = (obj["timestamp"] as? NSNumber)?.int64Value ?? RIQ.now()
            out.append(CrashReport(sessionID: sid, timestamp: ts,
                                   event: event(message: obj["message"] as? String ?? "Uncaught exception",
                                                stack: obj["stack"] as? String ?? "", at: ts)))
        }
        if let s = try? String(contentsOf: p.signal, encoding: .utf8), let r = parseSignalReport(s) {
            out.append(r)
        }
        try? FileManager.default.removeItem(at: p.exception)
        try? FileManager.default.removeItem(at: p.signal)
        return out
    }

    static func parseSignalReport(_ s: String) -> CrashReport? {
        let lines = s.components(separatedBy: "\n")
        guard lines.count >= 3, !lines[0].isEmpty, let ts = Int64(lines[1]), let sig = Int32(lines[2]) else { return nil }
        let stack = lines.dropFirst(3).filter { !$0.isEmpty }.joined(separator: "\n")
        return CrashReport(sessionID: lines[0], timestamp: ts,
                           event: event(message: "Fatal signal \(signalName(sig))", stack: stack, at: ts))
    }
}
