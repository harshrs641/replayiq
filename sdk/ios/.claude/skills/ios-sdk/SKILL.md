---
name: ios-sdk
description: Map of the ReplayIQ iOS SDK (Swift package in sdk/ios, also the native engine under React Native on iOS) - which file does what, the threading model, the Native DOM walker, build and test commands, the example app and UI tests, and known pitfalls. Use before reading or changing anything in sdk/ios or debugging an iOS / React Native iOS recording.
---

# ReplayIQ iOS SDK

Swift package `ReplayIQ` (iOS 15+, no dependencies). It records UIKit and
SwiftUI apps. `sdk/react-native` uses it on iOS.

- What is captured and how it replays: `sdk/ios/RECORDING.md`
- Setup and public API: `sdk/ios/README.md`
- Wire formats: `docs/sdk/recording-api-v1*.md`

## Public API (Sources/ReplayIQ/ReplayIQ.swift)

`ReplayIQ.start(key:endpoint:options:)`, `identify`, `track`, `screen`, `log`,
`logError`, `recordError` (used by React Native for JS errors),
`recordNetwork`, `urlSessionConfiguration(_:)`, `optOut`/`optIn`, `stop`,
`reset`, `flush`, `sessionId`, `isRecording`, `diagnostics`, `maskPredicate`,
`trackDeepLink`, `trackPushOpen`.

`ReplayIQOptions` sets:
- `recordingMode`: `.auto`, `.nativeDom` or `.screenshot`.
- `dataMode`: `.masked` or `.raw`.
- `capture`: console, network and body options.
- `maskAllTextInputs` / `maskAllText`, `sampleRate`, `flushInterval` (5 s),
  `sessionTimeout` (30 min), `maxFramesPerSecond`, `debug`.

Masking API (`Masking.swift`): `view.replayIQMasked = true`, SwiftUI `.replayIQMask()`.

## File map (Sources/ReplayIQ)

| File | Role |
|---|---|
| `ReplayIQ.swift` | Public facade + options |
| `Recorder.swift` | Core: session lifecycle, sampling, event buffer, batching. **All mutable state on serial queue `q`.** `record()` is callable from any thread. Batch flush at 5 s, 50 events, 2 MB, or background |
| `SessionStore.swift` | Persisted session (continues across relaunch within timeout, batch seq) |
| `BatchQueue.swift` | Disk FIFO at `Application Support/ReplayIQ/queue`. Requests survive app kill |
| `Uploader.swift` | HTTP sender (protocol so tests fake it), retry/backoff per spec. Its own requests are never recorded |
| `Gzip.swift` | gzip via Compression framework (no zlib) |
| `NativeDom/DomWalker.swift` | **Main thread.** Walks the key window's CALayer tree → `DomNode`s: views, text (UILabel, UITextView, CATextLayer, RN paragraphs), images, inputs (`input()`: UITextField/UITextView style, placeholder colour, `pad` from `textRect`, `filled` for secure), scroll views, masks, islands (bitmaps for SwiftUI text, shapes, maps, video) |
| `NativeDom/DomNode.swift` | Node model + JSON (`DomInput` carries `style`, `placeholderColor`, `filled`, `pad`, `length`) |
| `NativeDom/DomDiffer.swift` | Flattened tree diff → `ui_mutation` (adds/removes/updates) |
| `NativeDom/DomRecorder.swift` | When to walk (after touches, nav, network, keyboard; ≤30/s while animating; else 1/s). Snapshot vs mutation. Hands off to screenshots in `.auto` when the screen is mostly islands |
| `NativeDom/DomAssets.swift` | sha256 asset dedupe (on disk per key), `HEAD` then `POST /api/v1/assets` |
| `ScreenRecorder.swift` | Screenshot mode: `drawHierarchy`, mask painted on device, JPEG, ≤2 fps, changed frames only, keyframes |
| `Masking.swift` | Mask API + which views are masked |
| `TouchRecorder.swift` | `UIApplication.sendEvent` swizzle: touches, taps, rage taps (3 taps / 700 ms / 48 pt), gestures. `role:"label"` selectors from accessibility |
| `NavigationTracker.swift` | `viewDidAppear` → `navigate` |
| `NetworkRecorder.swift` | `URLProtocol` on `URLSession.shared` + default/ephemeral configurations. Method, URL, status, timing; headers/bodies in raw data mode |
| `ConsoleRecorder.swift` | stdout/stderr pipe redirect (passed through unchanged) + os_log. Rate cap 50 lines/s with a "N console lines not recorded" summary |
| `CrashReporter.swift` | NSException + fatal signals. Async-signal-safe write to disk, sent as `js_error` on next launch |
| `Signals.swift` | v1.1 signals: lifecycle, app_start, screen_load, jank (display link), hang ≥2 s (watchdog), memory, keyboard, orientation, connectivity, deep links, push, permissions, thermal/power, focus/blur |
| `Redactor.swift` | Always-masked rules (secret headers, Luhn cards, sensitive keys). Must match `backend/internal/masking/always.go` |
| `Diagnostics.swift` | Counters and timings (walk ms etc.) exposed as `ReplayIQ.diagnostics` |
| `Util.swift` | `RIQ` helpers, debug logging. SDK errors are logged, never thrown into the app |

## Threading rule

UIKit/CALayer reads happen on the main thread (walker, mask rects, screenshot
draw). Hashing, encoding, diffing, serialising and I/O happen on utility
queues or `Recorder.q`. Keep walker work property reads only. Typical walk
cost is 1 to 4 ms.

## Build and test

```bash
cd sdk/ios
xcodebuild -scheme ReplayIQ -destination 'generic/platform=iOS Simulator' -quiet build
xcodebuild test -scheme ReplayIQ -destination 'id=<simulator udid>' -quiet 2>&1 | grep -E "error:|failed|Executed"
xcrun simctl list devices booted     # find a udid (iPhone 17 Pro is used locally)
```

Tests are in `Tests/ReplayIQTests`:
- `ReplayIQTests.swift`: recorder, queue, uploader, touches
- `NativeDomTests.swift`: walker and differ, including input style
- `DataModeTests.swift`: raw/masked, console, network, redaction

## Example app and end-to-end check

- `Example/ReplayIQExample.xcodeproj`, scheme `ReplayIQExample`, bundle id
  `io.replayiq.example`.
- The app is SwiftUI shop and checkout plus `UIKitCheckout.swift`. It records
  with key `verify` to `localhost:8080`.
- UI tests in `Example/ReplayIQExampleUITests/CheckoutFlowUITests.swift`:
  - `testCheckoutSession`: the full flow.
  - `testMeasureMinute`: one minute of use, for cost measurement.

```bash
cd sdk/ios/Example
xcodebuild test -project ReplayIQExample.xcodeproj -scheme ReplayIQExample \
  -destination 'id=<udid>' -only-testing:ReplayIQExampleUITests/CheckoutFlowUITests/testCheckoutSession
```

Then inspect the new session with the `debug-replay` skill (repo root).

## Pitfalls

- XCTest logs heavily to stdout. A one-minute UI test once produced 56k
  `console` events. Don't treat UI-test console volume as real app behaviour.
- If the example app keeps sending into an old session, its disk queue is
  still draining. Run `xcrun simctl uninstall booted io.replayiq.example`.
- Never send input values in masked mode. Secure fields send `filled`, never
  a length.
- Any new node field needs the spec (`docs/sdk/recording-api-v1.1-native-dom.md`),
  the backend transform (`transform/nativedom.go` + test), and the same field
  in the Android and Flutter SDKs.
- The keyboard and system alerts are separate windows and are not captured.
