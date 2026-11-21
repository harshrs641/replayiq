---
name: android-sdk
description: Map of the ReplayIQ Android SDK (Kotlin library in sdk/android, also the native engine under React Native on Android) - which file does what, View and Compose walking, threading, Gradle/JDK/emulator setup, tests, the sample app, and pitfalls. Use before reading or changing anything in sdk/android or debugging an Android / React Native Android recording.
---

# ReplayIQ Android SDK

Gradle project with modules `:replayiq` (library, namespace
`com.replayiq.android`) and `:sample` (app `com.replayiq.sample`). It records
Views and Jetpack Compose (optional dependency). `sdk/react-native` uses it
on Android.

- What is captured and how it replays: `sdk/android/RECORDING.md`
- Setup: `sdk/android/README.md`
- Wire formats: `docs/sdk/recording-api-v1*.md`

## Public API (replayiq/src/main/java/com/replayiq/android/)

`ReplayIQ.kt` (object):
- `start(context, key, endpoint, options)`. A key-less overload reads the
  key from manifest meta-data.
- `identify`, `track`, `screen`, `log`, `logError`, `recordError`, `recordNetwork`.
- `okHttp(builder)` adds the interceptor and timing listener.
- `mask(view)` / `unmask(view)`, `maskPredicate`.
- `optOut` / `optIn`, `stop`, `reset`, `setSampleRate`, `sessionId`, `flush`,
  `debugStats`, `pushOpened`, `permissionResult`.

`ReplayIQOptions.kt` is immutable and built with `Builder` from Java:
`recordingMode`, `dataMode` (MASKED/RAW), `maskAllInputs`/`maskAllText`/
`maskAllImages`/`maskWebViews`, capture switches, body limits, `maxFps`,
`flushIntervalMs`, `sessionTimeoutMs`, `debug`.

`ReplayIQOkHttpInterceptor.kt` records the `network` events.
`compose/ReplayIQCompose.kt` provides the `Modifier.replayIQMask()` semantics key.

## File map (internal/)

| File | Role |
|---|---|
| `Recorder.kt` | Engine: session lifecycle, sampling, event buffer, batching to disk queue, wiring to activities |
| `SessionStore.kt` | Session state surviving process death (`sync` commit from crash handler) |
| `Transport.kt` | Disk FIFO + uploader, retry table, backoff 1 s→60 s |
| `Policies.kt` | Keyframe rules (first, size change, every 30 s), rage-tap rule (3 taps / 700 ms / 48 dp) |
| `DomRecorder.kt` | Native DOM: walk after a draw that changed something (≤30/s), diff + serialise on worker thread → `ui_snapshot` / `ui_mutation`. Falls back to screenshots on island-heavy screens |
| `ViewWalker.kt` | **Main thread.** View tree → `DomNode`. Stable ids in view tags. EditText input: `textInfo` style, hint colour `pc`, `pad` from compound padding, `filled` for passwords, length 0 for passwords |
| `ComposeDom.kt` | Compose semantics tree → nodes (best effort). Input style only when `hasTextLayout`. No pad |
| `ComposeSupport.kt` | Guards the optional Compose classpath. Any failure disables Compose capture |
| `ReactNative.kt`, `ReactNativeNetwork.kt` | RN views via reflection (Fabric + old renderer). RN's OkHttp client gets the interceptor |
| `DomNode.kt` | Node model (dp, ARGB ints) + JSON. `InputInfo(type, ph, len, focus, style, pc, filled, pad)` |
| `Drawables.kt` | Backgrounds → styles (colour, shape, gradient, stroke) or "rasterise" |
| `Assets.kt` | sha256 asset upload once, queued with the batches |
| `ScreenCapturer.kt` | Screenshot mode: ≤`maxFps`, after redraw, masked before encoding |
| `ViewInspector.kt` | Which views are masked, mask rects, tap selectors (`role:"label"`) |
| `TouchTracker.kt` | Window.Callback wrapper: touches, clicks, rage clicks |
| `InputWatcher.kt` | `input` events per typing burst (selector only, never value) |
| `FragmentTracker.kt` | `navigate` for AndroidX fragments (optional dep) |
| `Signals.kt` | v1.1 signals: lifecycle, app_start, screen_load, jank (FrameMetrics), hang watchdog, memory, keyboard, orientation, connectivity |
| `LogcatCapture.kt` | Automatic console from the app's own Logcat (includes System.out/err) |
| `OkHttpTiming.kt`, `NetworkRecord.kt` | dns/connect/tls/ttfb/download timing; captured request model |
| `Redactor.kt` | Always-masked rules. Must match `backend/internal/masking/always.go` |
| `CrashHandler.kt` | Uncaught exception → `js_error` written synchronously, then previous handler |
| `Events.kt`, `Json.kt` | Custom-event builders; JSON-safe conversion of app values |
| `Stats.kt`, `Log.kt` | Cost counters (debug), Logcat logging when `debug` |

## Threading rule

View, Compose and drawable reads happen on the main thread. Diff, serialise,
hash, encode and I/O happen on the worker thread. Never throw into the host
app: public calls are wrapped in `safe {}`.

## Build and test

Gradle needs **JDK 17**. The system default (Java 11) fails.

```bash
cd sdk/android
export JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
./gradlew :replayiq:testDebugUnitTest -q
./gradlew :sample:installDebug
```

Unit tests use Robolectric. They are in `replayiq/src/test/java/com/replayiq/android/internal/`:
- `NativeDomTest`: walker and inputs
- `ReactNativeDomTest`
- `RecorderTest`
- `TransportTest`
- `PoliciesTest`
- `TouchTrackerTest`
- `ViewInspectorTest`
- `EventsTest`
- `DataModeTest`

Fakes are in `fake/`.

## Sample app and emulator

- The sample is `ShopActivity` → `CheckoutActivity` → `ReceiptActivity`,
  with a RecyclerView, a custom `SparklineView`, and Compose content.
- It records to `http://10.0.2.2:8080`, which is the host's `./dev.sh` stack.
  Override with `-PreplayiqEndpoint=… -PreplayiqKey=…`.
- The AVD is `replayiq_api35`. Start it with:

```bash
$ANDROID_HOME/emulator/emulator -avd replayiq_api35 -no-snapshot -no-audio -no-boot-anim
```

Inspect the resulting session with the `debug-replay` skill (repo root).

## Pitfalls

- Sizes in DOM nodes are dp (divide px by density). Colours are ARGB ints,
  serialised as `#AARRGGBB`.
- Compose, fragments and React Native are optional. Check for them with
  `ComposeSupport` or reflection before touching their classes.
- Password fields send `filled`, never a length. Masked mode never sends `v`.
- Any new node field must also go in the spec, the backend transform and
  test, and the iOS and Flutter walkers.
