// Native side of replayiq_flutter: JPEG encoding, device info and a
// background task so the last batch can upload when the app is backgrounded.
//
// The JPEG encoder is derived from mixpanel_flutter_session_replay 2.1.0
// (Copyright 2022 Mixpanel, Inc., Apache-2.0); see LICENSE and NOTICE.
// Changed: channel name, quality passed by Dart, Mixpanel super-property
// broadcasting removed, device info added.
import Flutter
import UIKit

public class ReplayIQFlutterPlugin: NSObject, FlutterPlugin {
    private static let encodeQueue = DispatchQueue(
        label: "dev.replayiq.flutter.jpeg",
        qos: .utility
    )

    private var backgroundTaskId = UIBackgroundTaskIdentifier.invalid

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "dev.replayiq.flutter",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(ReplayIQFlutterPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "compressJpeg":
            compressJpeg(call: call, result: result)
        case "deviceInfo":
            result(deviceInfo())
        case "processStartMillis":
            result(ReplayIQFlutterPlugin.processStartMillis())
        case "beginBackgroundTask":
            beginBackgroundTask()
            result(nil)
        case "endBackgroundTask":
            endBackgroundTask()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func deviceInfo() -> [String: String] {
        var info: [String: String] = [
            "os": "ios",
            "os_version": UIDevice.current.systemVersion,
            "device": ReplayIQFlutterPlugin.modelIdentifier(),
        ]
        let bundle = Bundle.main
        if let id = bundle.bundleIdentifier { info["bundle_id"] = id }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String
        switch (version, build) {
        case let (v?, b?): info["app_version"] = "\(v) (\(b))"
        case let (v?, nil): info["app_version"] = v
        default: break
        }
        return info
    }

    /// When this process started (for app_start), in unix ms.
    private static func processStartMillis() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Int(start.tv_sec) * 1000 + Int(start.tv_usec) / 1000
    }

    private static func modelIdentifier() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = Mirror(reflecting: systemInfo.machine).children.reduce("") { id, el in
            guard let value = el.value as? Int8, value != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(value)))
        }
        return machine
    }

    private func beginBackgroundTask() {
        guard backgroundTaskId == .invalid,
              let app = UIApplication.value(forKey: "sharedApplication") as? UIApplication else { return }
        backgroundTaskId = app.beginBackgroundTask(withName: "replayiq.flush") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid,
              let app = UIApplication.value(forKey: "sharedApplication") as? UIApplication else { return }
        app.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    private func compressJpeg(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let rgba = args["rgba"] as? FlutterStandardTypedData,
              let width = args["width"] as? Int,
              let height = args["height"] as? Int,
              let quality = args["quality"] as? Int else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
            return
        }
        let bytes = rgba.data
        guard bytes.count == width * height * 4 else {
            result(FlutterError(code: "INVALID_DATA", message: "Unexpected buffer size", details: nil))
            return
        }
        ReplayIQFlutterPlugin.encodeQueue.async {
            // Screenshots are opaque: treat RGBA as RGBX.
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let cg = CGImage(
                      width: width, height: height,
                      bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                      provider: provider, decode: nil, shouldInterpolate: false,
                      intent: .defaultIntent),
                  let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: CGFloat(quality) / 100.0)
            else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "ENCODE_FAILED", message: "JPEG encoding failed", details: nil))
                }
                return
            }
            DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: jpeg)) }
        }
    }
}
