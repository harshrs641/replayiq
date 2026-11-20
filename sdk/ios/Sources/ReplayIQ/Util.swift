import Foundation

/// Internal helpers shared by every part of the SDK.
enum RIQ {
    static let version = "1.0.0"
    static let sdkName = "replayiq-ios/\(version)"

    /// Set from `ReplayIQOptions.debug`. SDK failures are only ever logged,
    /// never thrown into the host app.
    static var debug = false

    static func log(_ message: @autoclosure () -> String) {
        guard debug else { return }
        NSLog("[ReplayIQ] %@", message())
    }

    /// Unix time in milliseconds.
    static func now() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func iso(_ ms: Int64) -> String {
        isoFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "app" }

    /// `app://<bundle id>/<route>`, the mobile form of a page URL.
    static func appURL(_ route: String) -> String {
        let r = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        return "app://\(bundleID)/\(r)"
    }

    /// Application Support/ReplayIQ (excluded from backups).
    static func storageDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var dir = base.appendingPathComponent("ReplayIQ", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }
}

/// A value guarded by a lock, readable from any thread.
final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    var get: T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    @discardableResult
    func mutate<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Exchanges two instance methods of a class once.
func riqSwizzle(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
    guard let o = class_getInstanceMethod(cls, original),
          let r = class_getInstanceMethod(cls, replacement) else { return }
    if class_addMethod(cls, original, method_getImplementation(r), method_getTypeEncoding(r)) {
        class_replaceMethod(cls, replacement, method_getImplementation(o), method_getTypeEncoding(o))
    } else {
        method_exchangeImplementations(o, r)
    }
}

/// Exchanges two class methods once.
func riqSwizzleClass(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
    guard let meta = object_getClass(cls) else { return }
    riqSwizzle(meta, original, replacement)
}
