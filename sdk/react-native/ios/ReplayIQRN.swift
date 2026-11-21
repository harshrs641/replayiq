import Foundation
import React
import ReplayIQ
import UIKit

/// React Native bridge over the native ReplayIQ iOS SDK. Screens, touches,
/// network (RN's fetch/XHR use NSURLSession) and native crashes are recorded
/// by the SDK itself; JavaScript adds JS errors, console lines and React
/// Navigation screens through these methods.
@objc(ReplayIQRN)
final class ReplayIQRN: NSObject {
    @objc static func requiresMainQueueSetup() -> Bool { false }

    @objc(start:endpoint:options:)
    func start(_ key: String, endpoint: String, options: NSDictionary) {
        let o = ReplayIQOptions()
        o.platform = "react-native"
        if let sdk = options["sdk"] as? String { o.sdkName = sdk }
        // RN screens come from React Navigation (trackNavigation), not view controllers.
        o.trackViewControllers = false
        if let v = options["sampleRate"] as? Double { o.sampleRate = v }
        if let v = options["maskAllTextInputs"] as? Bool { o.maskAllTextInputs = v }
        if let v = options["maskAllText"] as? Bool { o.maskAllText = v }
        if let v = options["debug"] as? Bool { o.debug = v }
        if let v = options["metadata"] as? [String: String] { o.metadata = v }
        switch options["recordingMode"] as? String {
        case "nativeDom": o.recordingMode = .nativeDom
        case "screenshot": o.recordingMode = .screenshot
        default: o.recordingMode = .auto
        }
        if let maskID = options["maskNativeID"] as? String {
            // <ReplayIQMask> renders a View with this nativeID.
            ReplayIQ.maskPredicate = { view in ReplayIQRN.nativeID(of: view) == maskID }
        }
        ReplayIQ.start(key: key, endpoint: endpoint, options: o)
    }

    /// The React nativeID of a view: `nativeID` on the old renderer
    /// (UIView+React), `nativeId` on Fabric component views.
    static func nativeID(of view: UIView) -> String? {
        for name in ["nativeID", "nativeId"] where view.responds(to: NSSelectorFromString(name)) {
            if let id = view.value(forKey: name) as? String { return id }
        }
        return nil
    }

    @objc(identify:traits:)
    func identify(_ userId: String, traits: NSDictionary) {
        ReplayIQ.identify(userId, traits: traits as? [String: Any])
    }

    @objc(track:properties:)
    func track(_ name: String, properties: NSDictionary) {
        ReplayIQ.track(name, properties: properties as? [String: Any])
    }

    @objc(screen:)
    func screen(_ name: String) { ReplayIQ.screen(name) }

    @objc(log:level:)
    func log(_ message: String, level: String) {
        let l: ReplayIQLogLevel = level == "error" ? .error : level == "warn" ? .warn : .log
        ReplayIQ.log(message, level: l)
    }

    @objc(recordError:stack:filename:line:column:)
    func recordError(_ message: String, stack: String, filename: String, line: NSNumber, column: NSNumber) {
        ReplayIQ.recordError(message, stack: stack, filename: filename, line: line.intValue, column: column.intValue)
    }

    @objc func optOut() { ReplayIQ.optOut() }
    @objc func optIn() { ReplayIQ.optIn() }
    @objc func stop() { ReplayIQ.stop() }
    @objc func reset() { ReplayIQ.reset() }
    @objc func flush() { ReplayIQ.flush() }

    @objc(getSessionId:reject:)
    func getSessionId(_ resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        resolve(ReplayIQ.sessionId)
    }
}
