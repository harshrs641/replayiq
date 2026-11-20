# ReplayIQ iOS SDK

Session replay for iOS 15+ apps (UIKit and SwiftUI). The SDK records the
screen as a **Native DOM** (a tree of nodes plus small changes, [Recording API
v1.1](../../docs/sdk/recording-api-v1.1-native-dom.md)) or as masked
screenshots (v1), along with touches, gestures, mobile signals, screen changes, taps, rage taps, text input (never its
value), console logs, HTTP requests and crashes. It sends them to ReplayIQ
using the [Recording API v1](../../docs/sdk/recording-api-v1.md).

- Swift Package `ReplayIQ` (no dependencies), plus `ReplayIQ.podspec`
- The whole public API can be called from Objective-C (`@objc`). This is the
  base for the React Native bridge.
- Masking happens on the device, before any image is encoded. Batches are
  sent with `device_masked: true`.

## Install

**Swift Package Manager.** In Xcode, use File › Add Package Dependencies…
and add the repository. While working on the SDK locally, add `sdk/ios` as a
local package. In `Package.swift`:

```swift
.package(url: "https://github.com/harshrs641/replayiq.git", from: "1.0.0")
// target: .product(name: "ReplayIQ", package: "replayiq")
```

**CocoaPods** (local path for now):

```ruby
pod 'ReplayIQ', :path => '../replayiq/sdk/ios'
```

To publish to trunk, move the podspec to the repository root and set
`source_files` to `sdk/ios/Sources/ReplayIQ/**/*.swift`.

## Usage

```swift
import ReplayIQ

// AppDelegate.application(_:didFinishLaunchingWithOptions:) or App.init()
let options = ReplayIQOptions()
options.sampleRate = 0.5          // record half of all sessions
ReplayIQ.start(key: "<ingest key>", endpoint: "https://ingest.replayiq.example", options: options)

ReplayIQ.identify("user_123", traits: ["plan": "pro"])
ReplayIQ.track("checkout_started", properties: ["total": 218])
ReplayIQ.log("payment declined", level: .error)      // Console tab
ReplayIQ.screen("Checkout")                           // SwiftUI screens

ReplayIQ.optOut() / ReplayIQ.optIn()   // consent; remembered across launches
ReplayIQ.reset()                       // logout: end the session, start a new one
ReplayIQ.stop()                        // end the session and stop recording
ReplayIQ.flush()                       // send buffered events now
ReplayIQ.sessionId                     // current session id (nil when not recording)
```

Objective-C:

```objc
@import ReplayIQ;
ReplayIQOptions *o = [ReplayIQOptions new];
[ReplayIQ startWithKey:@"<key>" endpoint:@"https://ingest.replayiq.example" options:o];
[ReplayIQ identify:@"user_123" traits:@{@"plan": @"pro"}];
[ReplayIQ log:@"hello" level:ReplayIQLogLevelWarn];
```

Until real ingest keys exist, the key is the project id. It is sent as
`Authorization: Bearer <key>` and as `project_id`.

### SwiftUI screens

UIKit view controllers are tracked automatically: `navigate` uses the class
name, or `viewController.replayIQScreenName` when you set it. SwiftUI hosting
controllers have no meaningful names, so name SwiftUI screens yourself:

```swift
CheckoutView().replayIQScreen("Checkout")   // or ReplayIQ.screen("Checkout")
```

## Recording modes

`options.recordingMode`:

| Mode | What is sent |
|---|---|
| `.auto` (default) | Native DOM. A screen that is more than half islands (a map, video or game) switches to screenshots, and switches back when that screen goes away. The server inserts a keyframe at each switch. |
| `.nativeDom` | Native DOM only. |
| `.screenshot` | Masked screenshots only (v1). |

### How Native DOM works

- **The walker.** It walks the key window's CALayer tree, which UIKit and SwiftUI both render into.
- **What each layer becomes:**
  - Every layer that draws something becomes a node: frame relative to its parent, background, corner radii (per corner), border, shadow, opacity, 2D transform about the centre, clipping and gradients.
  - Layers that draw nothing are folded into their children.
  - `UILabel`, `UITextView` and `CATextLayer` become `text` nodes (string, font, size, weight, colour, alignment, lines).
  - `UIImageView`s and layer images become `image` nodes, uploaded once as assets at no more than 1x.
  - `UITextField` and editable `UITextView` (SwiftUI `TextField` / `SecureField` / `TextEditor`) become `input` nodes. These carry the type, placeholder, length and focus, never the value, and their subviews are never walked. Secure fields send no length.
  - `UIScrollView`s become `scroll` nodes. Children are in content coordinates and scrolling only changes `so`.
- **Islands.** Content that can't be described becomes an `island`: a small bitmap uploaded as an asset and re-sent only when its pixels change (at most 2/s).
  - SwiftUI `Text`, which iOS draws into layer bitmaps, is an island labelled with its accessibility label.
  - So are shape layers, custom `draw(_:)` views, and maps, video, web views and Metal views.
  - Maps, video, web and Metal views are captured from the screen with masks painted over. A camera preview is never captured: it is an empty box with `hint: "camera"`.
- **When it walks:**
  - After touches, screen changes, network responses, keyboard and app events.
  - Up to 30 times a second while anything animates, scrolls or keeps changing.
  - Otherwise once a second. An unchanged screen sends nothing.
- **Snapshots and mutations.** A `ui_snapshot` is sent on the first frame, on a screen change, size change or resume, when returning from screenshot mode, and at least every 30 s of activity. Everything else goes as `ui_mutation`s, where each update carries the node's complete own fields.
- **Thread split.** The walk runs on the main thread. Hashing, encoding, diffing and serialising run on a utility queue.
- **Assets.** Each asset is uploaded once: `HEAD /api/v1/assets/<hash>` and, if missing, `POST /api/v1/assets`. Uploads are queued on disk ahead of the batch that references them, and known hashes are remembered per key.

Measured on the Example app: iPhone 17 Pro simulator, Release build, the same scripted 72 s UI-test flow in each mode (`testMeasureMinute`):

| | screenshot | Native DOM |
|---|---|---|
| event bytes / min (raw) | 3.57 MB | 378 KB (9.4x less) |
| event bytes / min (gzipped, on the wire) | 1.73 MB | 74.5 KB (23x less) |
| assets (one-time, per install) | 0 | 63 KB (20 images/islands) |
| events / min | 261 (60 frames) | 640 (422 `ui_*`) |
| main-thread capture | 52 ms p50 / 66 ms p95 per frame | walk 1.3 ms p50 / 3.4 ms p95, 5.4 ms max |
| off-main diff + serialise | n/a | 0.9 ms p50 / 1.9 ms p95 |
| frames > 1.5x budget (p95 frame) | 37 ms | 16.7 ms |

The worst single frame was about 400–460 ms in both modes, caused by the UI test runner's keyboard and navigation on the simulator.
`ReplayIQ.diagnostics` returns these counters in any build.

## Mobile signals (v1.1 §2)

With `captureSignals` (on by default), the SDK sends:

| Signal | When it's sent |
|---|---|
| `gesture` | Tap, double tap, long press, swipe, pan, pinch, with a selector. Taps also send `click`. |
| `focus` / `blur` | A text field gains or loses focus. |
| `scroll` | A scroll view settles (300 ms without moving). Native DOM mode only. |
| `lifecycle` | The app comes to the foreground (with `cold`), goes to the background, or terminates. |
| `app_start` | Cold: process start to the first recorded frame. Warm: entering the foreground to the next frame. |
| `screen_load` | UIKit: `viewWillAppear` to `viewDidAppear`. Manual screens: `ReplayIQ.screen` to the next frame. |
| `jank` | Per 5 s window while the user interacts, if any frame was dropped (> 16.7 ms and 1.5x the target) or frozen (> 700 ms). |
| `hang` | The main thread was blocked for 2 s or more (from a watchdog thread). Sent with its duration once the main thread recovers. |
| `memory` | OS memory warnings, with the footprint in MB. |
| `keyboard` | The keyboard is shown (with its height) or hidden. |
| `orientation` | The screen rotates. |
| `connectivity` | The network changes (NWPathMonitor): wifi, cellular or none, plus quality. |
| `deeplink` | A link reaches the app or scene delegate's open-URL methods, or `ReplayIQ.trackDeepLink(_:)` is called. |
| `push_open` | The app's `UNUserNotificationCenterDelegate` handles a notification open. Only the campaign id is sent. Also `ReplayIQ.trackPushOpen(_:)`. |
| `permission` | Camera, microphone, photos, location or notifications changes from undetermined, checked each time the app becomes active. |
| `thermal` / `power` | The thermal state or Low Power Mode changes. |

The session metadata also carries `locale`, `text_scale`, `screen_density` and `recording_mode`.

## What gets recorded

| Event | Source |
|---|---|
| `ui_snapshot` / `ui_mutation` | Native DOM (see above). |
| `screen` | Screenshot mode (or an auto-mode fallback): screenshot of the key window, at most 2 fps, sent only when the pixels changed. JPEG quality 0.6 at 1.5x scale (both configurable, at most 2x). A keyframe is sent on the first frame, on a size or rotation change, after returning from the background, and every 30 s. |
| `touch` | Taps and drags in the key window (`down`, `move` at most every 50 ms, `up`). Taken from `UIApplication.sendEvent`. Keyboard windows are never recorded. |
| `click` / `rage_click` | `role:"label"` selectors built from accessibility info. For UIKit this is the view's accessibility label or button title. For SwiftUI it is the accessibility element under the finger, e.g. `button:"Pay now"`. A rage click is 3+ taps within 700 ms and 48 pt. |
| `input` | A text field or text view was edited. Sent at most once per second per field, with the field's label or placeholder. The value is never sent. |
| `navigate` | Your app's view controllers' `viewDidAppear`, `ReplayIQ.screen(_:)`, `.replayIQScreen(_:)` |
| `network` | Method, URL (query string stripped by default), status, duration and error for `URLSession.shared` and any session made with `.default` / `.ephemeral` configurations. Headers and bodies are never recorded. The ingest host is always excluded. Upload tasks and background sessions are not recorded. |
| `console` | `ReplayIQ.log(_:level:)` |
| `js_error` | Uncaught `NSException`s and fatal signals (SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP), including Swift runtime traps. Written to disk at crash time and sent on the next launch to the session that crashed. |

## Masking

In Native DOM mode:
- Masked views become `mask` nodes. Their children, text and images are never serialised or uploaded.
- Content that sits under a SwiftUI `.replayIQMask()` overlay is dropped too.
- `maskAllText` turns labels and SwiftUI text into masks.

In screenshot mode, masked areas are painted over on the device, before the image is encoded. These are masked by default:

- every `UITextField` and editable `UITextView`, which covers SwiftUI
  `TextField`, `SecureField` and `TextEditor`. Turn this off with
  `options.maskAllTextInputs = false`. Secure fields stay masked regardless.
- any UIKit view you mark: `view.replayIQMasked = true` (Objective-C:
  `view.replayIQMasked = YES`). The mask covers the view and everything inside it.
- any SwiftUI view you mark with the modifier:

```swift
CardPreview().replayIQMask()
```

To also mask every label and read-only text view (and web views), set
`options.maskAllText = true`.

The masks use the views' on-screen (presentation-layer) frames, so they follow
push transitions and other animations.

Not covered: content drawn inside a `WKWebView` (mark the web view masked, or
use `maskAllText`), and SwiftUI `Text` holding sensitive data (use
`.replayIQMask()`). The system keyboard and system sheets (e.g. "Save
Password?") run in separate windows and never appear in recordings.

## Sessions, batching and delivery

- `sampleRate` is decided once per session, before anything is recorded.
  Unsampled sessions send nothing.
- A session continues across launches and background periods. It ends after
  30 min in the background (`sessionTimeout`), or on `reset()` / `stop()`, and
  `POST /sessions/{id}/end` is then sent with the last active time.
- Events are batched every 5 s, at 50 events, at 2 MB, and when the app goes
  to the background (with a background task so the batch can upload). Each
  batch's `batch_id` is `<session_id>-<sequence>`. The sequence is persisted,
  so retries and relaunches never reuse an id.
- Every request (session create, events, end) is written to
  `Application Support/ReplayIQ/queue` before it is sent, so it survives an
  app kill. Requests are sent in order and gzipped.
- Retries follow the spec:
  - 2xx and 400: the batch is dropped.
  - 401/403: recording stops for this run; the queued batches are kept.
  - 413: the batch is split in two and resent.
  - 429: retried after `Retry-After`.
  - 5xx or a network error: retried with backoff of 1, 2, 4 … 60 s and the same `batch_id`.
- Offline, at most `maxQueueBytes` (5 MB) of event batches are kept on disk.
  The oldest are dropped first; session create and end requests are never
  dropped.
- SDK failures are never thrown into the app. They are logged with `NSLog`
  only when `options.debug` is on, which is the default in DEBUG builds.

## Performance

Taking the snapshot and finding the masks must run on the main thread
(UIKit). This is one `drawHierarchy(afterScreenUpdates: false)` at most every
500 ms, plus a walk of the view tree. Hashing (for change detection), JPEG
encoding and base64 run on a utility queue. A new snapshot is skipped while
the previous one is still encoding. Recording pauses in the background.

## Options

| Option | Default |
|---|---|
| `sampleRate` | 1.0 |
| `maskAllTextInputs` / `maskAllText` | true / false |
| `captureScreens`, `captureTouches`, `captureNetwork`, `captureCrashes`, `trackViewControllers` | true |
| `maxFramesPerSecond` (≤ 2), `imageScale` (≤ 2), `jpegQuality` | 2, 1.5, 0.6 |
| `networkIncludeQuery`, `networkIgnoredHosts` | false, [] |
| `flushInterval`, `sessionTimeout`, `maxQueueBytes` | 5 s, 1800 s, 5 MB |
| `debug` | on in DEBUG builds |
| `metadata` | extra string metadata on the session |
| `platform`, `sdkName` | `ios`, `replayiq-ios/1.0.0`. Only wrapper SDKs should change these. |

## Example app and tests

The Example has a "Store map" screen (mostly a map) that exercises the auto
fallback to screenshots. `RIQ_MODE=auto|nativeDom|screenshot` picks the mode.
Pass it to UI tests as `TEST_RUNNER_RIQ_MODE=nativeDom xcodebuild test …`.


`Example/ReplayIQExample.xcodeproj` is a checkout app with SwiftUI screens
(shop, cart, checkout with masked fields and a `.replayIQMask()` card) and a
UIKit checkout sheet (masked fields and a `replayIQMasked` view). It also
has a debug screen with log, network and crash buttons. It records to
`http://localhost:8080` with key `verify`; override these with the
`RIQ_ENDPOINT` / `RIQ_KEY` environment variables or `Info.plist`.

```bash
# unit tests (package)
cd sdk/ios && xcodebuild test -scheme ReplayIQ -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

```bash
# end-to-end: start ./dev.sh up, then drive the example with real touches
cd sdk/ios/Example && xcodebuild test -project ReplayIQExample.xcodeproj -scheme ReplayIQExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The UI test prints `RIQ_SESSION=<id>`. Open
`http://localhost:3000/?session=<id>` to watch the replay. Uninstall the
app first if you want a fresh session; otherwise a run within 30 min
continues the previous one.

## Notes for the React Native bridge

- Make the RN module a thin Objective-C/Swift bridge that calls the
  `ReplayIQ` class methods directly. Every method is `@objc`, safe from any
  thread and has no return values except `sessionId` / `isRecording`.
  Options are a plain `ReplayIQOptions` object, so map the JS options
  dictionary onto its properties.
- Set `options.platform = "react-native"` and
  `options.sdkName = "replayiq-react-native/<version>"` so sessions are
  labelled correctly.
- Screens: call `ReplayIQ.screen(name)` from the React Navigation state
  listener, and set `trackViewControllers = false`. RN view controllers
  aren't meaningful screens.
- Masking: expose a `<ReplayIQMask>` native view whose backing `UIView` sets
  `replayIQMasked = true`. RN `TextInput`s are `UITextField`/`UITextView`, so
  they are masked by default.
- JS errors and console: forward them with `ReplayIQ.log(_:level:)`. For
  fatal JS errors, add a bridge method that records a `js_error`; it can be
  added to the public API when the bridge is built.
- Network: `fetch`/XHR in RN go through `NSURLSession` with the default
  configuration, so they are recorded automatically.
- Native DOM works on RN (Fabric) apps:
  - `RCTParagraphComponentView` text becomes real `text` nodes, read from its attributed string (font, size, weight, colour, alignment).
  - RN's stretchable (9-slice) border images become `bw`/`bc`/`r` borders.
  - Background and border layers are painted behind children, ordered by `zPosition`.
  - Borders on only some sides are drawn on all four sides. The spec has no per-side borders yet.
- Taps on RN views get selectors from `accessibilityLabel` (set
  `accessibilityLabel` / `accessibilityRole` in JS for good selectors).
