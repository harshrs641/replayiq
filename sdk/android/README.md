# ReplayIQ Android SDK

> How it records, what it sends and how a recording replays: [RECORDING.md](RECORDING.md).

Session replay for native Android apps (Views and Jetpack Compose). It records masked screenshots,
touches, screens, clicks, rage clicks, text-field edits (never the values), console lines, network
requests and crashes, and sends them to ReplayIQ using the
[Recording API v1](../../docs/sdk/recording-api-v1.md).

- Kotlin library, AAR, **minSdk 24**, compileSdk 35, Java 17 bytecode. No required dependencies.
- Optional: Jetpack Compose (masking + tap labels), AndroidX Fragment (fragment screens), OkHttp
  (network events). The SDK only touches these when your app already has them.
- Public API is static and Java-friendly (`ReplayIQ.start(...)` from Java or Kotlin).

## Install

Until the artifact is published, build the AAR and add it to your app:

```bash
cd sdk/android && ./gradlew :replayiq:assembleRelease   # → replayiq/build/outputs/aar/replayiq-release.aar
```

```kotlin
// app/build.gradle.kts
dependencies {
    implementation(files("libs/replayiq-release.aar"))
}
```

(Or include the module: `include(":replayiq")` with `project(":replayiq").projectDir = file("../replayiq/sdk/android/replayiq")`.)
The AAR ships its consumer ProGuard/R8 rules and the `INTERNET` permission.

## Start

Call `start` once, in `Application.onCreate()`:

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        ReplayIQ.start(
            this,
            "<ingest key>",                       // for now: the project id
            "https://ingest.replayiq.example",    // your ingest host (emulator → local stack: http://10.0.2.2:8080)
            ReplayIQOptions.Builder()
                .sampleRate(1.0)
                .debug(BuildConfig.DEBUG)         // Logcat tag "ReplayIQ"
                .build(),
        )
    }
}
```

```java
ReplayIQ.start(this, "<ingest key>", "https://ingest.replayiq.example",
        new ReplayIQOptions.Builder().sampleRate(0.25).build());
```

Starting later (for example after a consent dialog) works too: pass the current `Activity` as the
context so the SDK adopts the screen that is already visible.

Plain `http://` endpoints (local development) need a
[network security config](sample/src/main/res/xml/network_security_config.xml) that allows cleartext
for that host.

## API

| Call | What it does |
|---|---|
| `start(context, key, endpoint[, options])` | Start recording. Later calls are ignored (after `stop()` they resume recording). |
| `identify(userId[, traits])` | Sets `user_id` (and string traits as session metadata). Call it before the first flush (≈5 s after start) to land on the current session — see *Known limitations*. |
| `track(name[, properties])` | App event, sent as `custom_events`. |
| `screen(name)` | Names the current screen (`navigate`). Activities and fragments are automatic; use this for Compose navigation. Called during an activity's creation, it replaces that activity's automatic name. |
| `log(message[, level])`, `logError(throwable)` | `console` lines (`log` / `warn` / `error`). |
| `recordNetwork(method, url, status, durationMs[, error])` | A `network` event for HTTP clients other than OkHttp. |
| `mask(view)`, `unmask(view)` | Paint a view over / record a view a default rule would mask. |
| `optOut()`, `optIn()`, `isOptedOut` | Consent. Opting out drops the buffered and queued data and is remembered across launches. |
| `stop()` | End the session (sends `…/end`) and stop recording. |
| `reset()` | End the session and start a new one (logout). |
| `setSampleRate(rate)` | Sample rate for sessions started from now on. |
| `sessionId` | Current session id, or null when not recording. |
| `flush()` | Send buffered events now. |

All calls are safe on any thread and never throw.

### Options (`ReplayIQOptions.Builder`)

| Option | Default | |
|---|---|---|
| `sampleRate` | 1.0 | Decided once per session, before recording starts. Unsampled sessions send nothing. |
| `maskAllInputs` | true | EditTexts and Compose text fields. |
| `maskAllText` | false | Every TextView / Compose `Text` (and inputs). |
| `maskAllImages` | false | Every ImageView / Compose `Image`. |
| `maskWebViews` | false | WebView contents. |
| `captureScreens` | true | Off: touches and app events only. |
| `captureTouches` | true | Window.Callback wrapper for touches, clicks and rage clicks. |
| `captureCrashes` | true | Uncaught exceptions → `js_error` on next launch. |
| `captureNetworkQuery` | false | Keep `?query` in recorded URLs (they often carry tokens). |
| `imageScale` | 1.0 | Screenshot pixels per dp (0.5–2). |
| `jpegQuality` | 60 | |
| `maxFps` | 2 | Capped at 2 (protocol limit). |
| `maskColor` | grey | |
| `flushIntervalMs` | 5000 | |
| `sessionTimeoutMs` | 30 min | Time in background after which the session ends. |
| `projectId` | null | Sent as `project_id`; null = server takes it from the key. |
| `debug` | false | Logcat logging. |
| `wrapper(platform, sdk)` | `android`, `replayiq-android/<v>` | For SDKs built on this one, e.g. `wrapper("react-native", "replayiq-react-native/1.0.0")`. |

## Masking

Masking happens **on the device, before the JPEG is encoded**; batches are sent with
`device_masked: true` and the server never sees the masked pixels.

Masked by default:

- every `EditText` (turn off with `maskAllInputs(false)`, or per field with `ReplayIQ.unmask(view)`),
- every password field (`inputType` password variations or `PasswordTransformationMethod`) — **always**,
  even after `unmask`,
- Compose text fields (`EditableText` semantics) and password fields (`Password` semantics),
- windows with `FLAG_SECURE` (sent as a blank frame),
- the soft keyboard, dialogs and other windows: only the activity window is captured.

Mark anything else sensitive:

```kotlin
ReplayIQ.mask(accountNumberView)           // a View and everything inside it
```

```xml
<TextView
    android:tag="replayiq-mask"
    android:text="@string/iban" ... />
```

```kotlin
Text(account.iban, modifier = Modifier.replayIQMask())          // Compose
TextField(query, onQuery, modifier = Modifier.replayIQMask(false)) // record this field
```

Selectors in `click` / `input` events (`button:"Pay now"`, `input:"Card number"`) use the content
description, then the visible text (never the text of an input or a masked view; inputs use their
hint), then the view id.

## Recording modes: Native DOM and screenshots

`ReplayIQOptions.Builder().recordingMode(...)`:

| Mode | What is sent |
|---|---|
| `AUTO` (default) | Native DOM; a screen that is mostly islands (maps, video, games, custom drawing: > 50 % of its area) is recorded with screenshots until the next screen. |
| `NATIVE_DOM` | Always Native DOM (recording API v1.1, `docs/sdk/recording-api-v1.1-native-dom.md`). |
| `SCREENSHOT` | Always screenshots (recording API v1). |

**Native DOM** records the UI as a tree of nodes (`ui_snapshot`) plus small changes
(`ui_mutation`), which the server turns into an rrweb page. On the sample app's scripted flow it sent
**~12 KB/min instead of ~426 KB/min** of screenshots (gzipped), with a main-thread walk of
**~0.5 ms p50**. What the walker understands:

| Android | Node |
|---|---|
| Any View | `view`: frame (dp, relative to the parent), alpha, translation / scale / rotation (`t`, about the centre), `clip` (clipChildren / clipToOutline with its radius), elevation → shadow |
| Background `ColorDrawable`, `GradientDrawable` (solid: colour, tint and stroke read from its drawn pixels; linear / radial gradients; corner radii; ovals), `RippleDrawable` / `InsetDrawable` / `StateListDrawable` (unwrapped to the current shape, inset kept), Material `MaterialShapeDrawable` (via its public getters) | `s.bg`, `s.r`, `s.bw`/`s.bc`, `s.grad` |
| Any other background (nine-patch, layer lists, custom drawables) | an `image` behind the view, rasterised once per look (≤ 1 px/dp) |
| `TextView` / `Button` | `text`: displayed text (after all-caps / ellipsis), size (sp → dp), weight, italic, colour, alignment, line height, max lines; positioned at its gravity inside the padding |
| `ImageView`, `CheckBox` / `RadioButton` buttons | `image`: the drawable rasterised once (vectors too) and uploaded by sha256; `scaleType` → `fit` |
| `EditText` | `input`: type (`text`, `password`, `number`, `email`, `phone`), hint, length and focus. **Never the value**, even when `unmask`ed. |
| `ReplayIQ.mask(view)`, `android:tag="replayiq-mask"`, password `TextView`s, `maskAllText` / `maskAllImages` / `maskWebViews` | `mask`: a solid block; nothing inside is serialised or uploaded |
| `ScrollView`, `HorizontalScrollView`, `NestedScrollView`, `RecyclerView`, `ListView` | `scroll`: children in content coordinates, scrolling only changes `so` (RecyclerView / ListView offsets are their scrollbar estimates) |
| `SurfaceView`, `TextureView`, `WebView`, `VideoView`, `MapView`, ExoPlayer `PlayerView`, CameraX `PreviewView`, Lottie, `ProgressBar`, `Switch`, and leaf views that override `onDraw` | `island`: cropped from a masked PixelCopy of the window (SurfaceViews copied on their own), ≤ 2 frames/s, uploaded when it changed; API 24–25: an empty box with a `hint` |
| Jetpack Compose (see below) | from the semantics tree |
| React Native (Fabric and the old renderer) | `ReactViewGroup` backgrounds (colour, border width / colour, corner radii) read through RN's public `BackgroundStyleApplicator`; one-sided borders (`borderBottomWidth`) become 1-edge lines; `overflow: hidden` → `clip`; text size / colour / weight from the text's spans; Fabric `PreparedLayoutTextView` from its precomputed layout (else its accessibility text with `"approx": true`); RN's dev-only `DebuggingOverlay` is skipped. Values are cached per view for ≤ 1 s. If RN's classes are renamed (R8 without RN's keep rules) or missing, backgrounds fall back to rasterised images |

Compose (best-effort, from the semantics tree): frames, text with its style (from the public
`GetTextLayoutResult` action), text fields as `input` (never the value), clickables' roles and
labels, `Modifier.replayIQMask()` as `mask`, `verticalScroll` / `horizontalScroll` as `scroll`, lazy
lists as clipped views whose rows move, `background` / `border` / `shadow` colours and shapes read
from the node's modifiers (by reflection on Compose internals: lost if R8 renames them), and images /
icons (`Role.Image`, or a content description without text) as islands. Not seen: layout nodes
without semantics (a plain `Box(Modifier.background(...))`, `drawBehind`, `Canvas`), `graphicsLayer`
alpha / transforms, `AndroidView` interop children, rich-text spans. A text style change without a
text change (e.g. an animated colour) is picked up on the next snapshot.

How it runs: an `OnDrawListener` on the window marks the tree dirty; the walk runs after that draw,
≤ 30 times/s, and nothing runs while the screen is static. Each view keeps a stable node id (a view
tag) for its lifetime. The walk only copies values; diffing, serialising and gzip happen on worker
threads. `ui_snapshot` is sent on the first frame, on an activity / fragment / `screen()` change, on
resume, on size change, when switching from screenshots and at least every 30 s of activity;
otherwise `ui_mutation` with adds, removes and updates (each update carries the node's complete own
fields). Assets (images, island frames) are uploaded once: `HEAD /api/v1/assets/<hash>`, then `POST`,
queued in the same disk queue before the batch that references them, and remembered on disk.

## What is recorded

| Event | Source |
|---|---|
| `screen` | Activity window screenshot when it redrew, ≤ 2 fps, keyframe on the first frame, size/orientation change and every 30 s. PixelCopy on API 26+ (off the main thread), `View.draw` on API 24–25. Identical frames are dropped. |
| `touch` | `down` / `move` (≤ every 50 ms) / `up`, in dp. |
| `click`, `rage_click` | A tap (no movement beyond touch slop); 3+ taps within 700 ms and 48 dp. Views: nearest clickable view; Compose: the clickable semantics node. |
| `input` | A focused EditText was edited (one event per burst of typing). |
| `navigate` | Activity resumed (`app://<package>/<Activity>`), AndroidX fragment resumed (`…/<Activity>/<Fragment>`), `ReplayIQ.screen(name)`. |
| `network` | `ReplayIQOkHttpInterceptor` or `recordNetwork`. Method, URL without query, status, duration, error. No headers or bodies. |
| `console` | `ReplayIQ.log` / `logError`. |
| `js_error` | Uncaught exceptions: written to disk synchronously, sent on the next launch, then the previous handler (system dialog, Crashlytics…) runs. |
| `ui_snapshot`, `ui_mutation` | Native DOM (above). |
| `gesture` | `tap`, `double_tap`, `long_press`, `swipe`, `pan`, `pinch` (with `dx`/`dy`/`scale`, dp). Taps also send `click`. |
| `focus` / `blur` | An `EditText` gained / lost focus. |
| `scroll` | A scroll container settled (300 ms), with its offset. |
| `lifecycle` | `foreground` (with `cold`) / `background`. |
| `app_start` | `cold`: process start → first frame (only when `start` ran in `Application.onCreate`); `warm`: activity re-created from the background → first frame. |
| `screen_load` | Activity created → first frame; fragment / `screen()` → next frame. |
| `jank` | Every 5 s that had frames > 16.7 ms (`dropped`) or > 700 ms (`frozen`), from FrameMetrics (API 24+). |
| `hang` | Main thread blocked ≥ 2 s (watchdog thread, foreground only), with the main thread's stack. |
| `memory` | `onTrimMemory` running-low (`warning`) / critical, `onLowMemory`, with MB used. |
| `keyboard` | Soft keyboard shown / hidden, with its height (WindowInsets on API 30+). |
| `orientation` | Rotation. |
| `connectivity` | Network type and quality, if the app has `ACCESS_NETWORK_STATE` (the SDK doesn't add it). Sent as `network`: the spec's `type` field collides with the event's own `type: 5`. |
| `deeplink` | Activity opened with `ACTION_VIEW` + data (query stripped unless `captureNetworkQuery`). |
| `push_open` | Opened from a Firebase notification (`google.message_id` extra) or an intent with the `replayiq_push_campaign` extra; or `ReplayIQ.pushOpened(campaign)`. |
| `permission` | A dangerous permission's state changed (checked on resume; `limited` for Android 14 partial photo access), or `ReplayIQ.permissionResult(name, result)`. |
| `thermal` / `power` | Thermal status changes (API 29+), battery saver on / off. |

Session metadata also carries `locale`, `text_scale`, `screen_density` and `recording_mode`.

```kotlin
val client = OkHttpClient.Builder()
    .addInterceptor(ReplayIQOkHttpInterceptor())
    .build()
```

## Transport

- Session created with `POST /api/v1/sessions` on the first flush (so an early `identify` is included).
- Events flushed every 5 s, at 50 events, and when the app goes to the background, as
  `POST /api/v1/events` with `batch_id = <session id>-<sequence>` (stable across retries), gzip and
  `Authorization: Bearer <key>`.
- Every request is written to `noBackupFilesDir/replayiq/queue` first and sent in order on its own
  thread, so it survives app kills. At most ~5 MB / ~1000 events of batches are kept (oldest dropped).
- Retries per the spec: 5xx / network errors back off 1 s, 2 s, 4 s … 60 s; 429 honours `Retry-After`;
  413 splits the batch in halves (`…-a`, `…-b`); 400 drops it; 401/403 stops recording for the app run.
- A session ends (`POST …/end`) after 30 min in the background (checked again on the next launch if
  the process was killed), on `stop()` / `reset()`. Relaunching within 30 min continues the session.

## Performance

Measured on the sample app (Android 15 emulator, software GPU, non-debuggable build, the same ~100 s
scripted flow in both modes, after a warm-up run):

| | Screenshots | Native DOM |
|---|---|---|
| Events, gzipped | 426 KB/min | 12 KB/min (~36x less) |
| Assets (one-time per install) | 0 | 9 KB (11 images / island frames) |
| Events / min | 129 (37 `screen`) | 168 (68 `ui_mutation`, 3.5 `ui_snapshot`) |
| Main-thread walk p50 / p95 | n/a | 0.54 / 6.9 ms wall, 0.45 / 2.2 ms CPU |
| Diff + serialise (worker) p50 / p95 | n/a | 1.0 / 15.7 ms |
| Worst frame | 1371 ms | 1460 ms (emulator-bound: every frame was > 16 ms in both modes) |

`ReplayIQ.debugStats(reset)` returns these counters (with `debug(true)`). In any build, `adb shell
setprop log.tag.ReplayIQStats DEBUG` and an app restart log them every 15 s under the `ReplayIQStats`
tag. Debuggable builds run largely interpreted on emulators and are ~10x slower, so measure with a
release build.

React Native example (`sdk/react-native/example`, RN 0.88 Fabric, release build, same emulator, a ~70 s
checkout → order summary → scroll flow, twice): Native DOM throughout (no screenshot fallback),
~9–14 KB/min gzipped, main-thread walk p50 / p95 **0.46 / 1.33 ms CPU** (0.52 / 2.08 ms wall).

Screenshot mode: capture planning (finding mask rects) is a view-tree walk on the main thread at most twice a second,
and only after the window redrew. Pixels are copied by PixelCopy and scaled to 1 px/dp; masking, JPEG
encoding (~10–20 KB per frame on a phone screen) and base64 run on a background thread; HTTP on
another. Capture pauses in the background. While a screen with masked views is scrolling, frames are
skipped until it settles so a mask can't trail behind its field.

## Known limitations

- Only the activity window is captured: dialogs, bottom-sheet dialogs, popups and toasts are not in
  the replay (touches on them still are, as `touch` events in window coordinates).
- Screenshot mode: `SurfaceView` / video / maps / camera previews render on their own surfaces and
  are not captured. Native DOM records them as islands (SurfaceViews copied separately, API 26+).
- Native DOM: compound drawables of TextViews (icons next to a label), text spans, `foreground`
  drawables and 3D rotations aren't described; Compose coverage is listed above.
- Compose text fields produce no `input` events (Views only), and Compose masking reads the semantics
  tree: a custom composable that draws sensitive text without text semantics must use
  `Modifier.replayIQMask()`.
- `identify` after the session was created is stored for the next session only: the server keeps
  the first `POST /sessions` for a session id (`ON CONFLICT DO NOTHING`).

## Sample app

`sample/` is a small shop: a product screen in a fragment (a loyalty number masked from XML, a vector
image on a rounded tile, a 40-row RecyclerView), a
checkout activity (name / card / CVV masked, promo code unmasked, *Pay now* calls a missing endpoint →
404 network event + console error, *Crash the app* throws), a Compose receipt (`Modifier.replayIQMask`,
masked text and password fields, an icon, a bordered card and a scrolling order history), a
custom-drawn chart (an island) on checkout, and *Log out* (`ReplayIQ.reset()`).

```bash
./dev.sh up                                    # repo root: local stack on :8080 / dashboard on :3000
cd sdk/android
./gradlew :sample:installDebug                 # endpoint http://10.0.2.2:8080, key "verify"
# other host/key: ./gradlew :sample:installDebug -PreplayiqEndpoint=https://… -PreplayiqKey=…
# recording mode: -PreplayiqMode=SCREENSHOT | NATIVE_DOM | AUTO (default)
# measuring: ./gradlew :sample:installRelease (non-debuggable, debug-signed), then
#   adb shell am broadcast -a com.replayiq.sample.STATS --ez reset true   # start a window
#   adb shell am broadcast -a com.replayiq.sample.STATS && adb logcat -s ReplayIQStats
```

Then open `http://localhost:3000/?session=<id>` (the id is in Logcat: `adb logcat -s ReplayIQ`).

## Build and test

```bash
./gradlew :replayiq:testDebugUnitTest     # JVM + Robolectric
./gradlew :replayiq:assembleRelease
```

Needs JDK 17 and an Android SDK with platform 35 (`local.properties` → `sdk.dir=…`, or `ANDROID_HOME`).

## Notes for the React Native bridge

The RN SDK should be a thin native module over this library:

- **Start from the module**, not JS-only: `ReplayIQ.start(currentActivity ?: reactContext.applicationContext, key, endpoint, options)`.
  Passing the current activity lets the SDK adopt the screen that is already showing (RN calls `start`
  after the activity resumed). Map the JS options object onto `ReplayIQOptions.Builder` field by field
  (all builder methods take primitives).
- Everything else maps 1:1 to `@JvmStatic` calls: `identify(String, Map<String,String>)`,
  `track(String, Map<String,Any?>)` (convert `ReadableMap.toHashMap()`), `screen(String)` (from React
  Navigation's state listener), `log(String, String)`, `optOut()`, `optIn()`, `stop()`, `reset()`,
  `setSampleRate(Double)`, `getSessionId()`.
- **Masking:** RN `TextInput` is an `EditText` (masked by default) and `secureTextEntry` is a password
  field (always masked). For other views, add a native prop or a module method that calls
  `ReplayIQ.mask(view)` / `unmask(view)` on the view resolved from its React tag (`UIManagerHelper`),
  or set `nativeID`/`testID`-driven tagging. RN text renders through `ReactTextView` (a `TextView`), so
  `maskAllText` works.
- **Selectors:** RN sets `accessibilityLabel` → content description, which is used first, so labelled
  `Pressable`s give good `button:"…"` selectors. A tap names the nearest clickable or labelled
  ancestor; RN's `DebuggingOverlay` is never the target; class names are never used as labels (an
  unlabelled view gives just its role, e.g. `button`); `testID` is used when there's no label. Pans,
  swipes and the `scroll` signal name the scroll container by its stable label only (content
  description, id or `testID`), never by its first visible row.
- **Network:** RN's `fetch` / `XMLHttpRequest` use OkHttp: add the interceptor with
  `OkHttpClientProvider.setOkHttpClientFactory { OkHttpClientProvider.createClientBuilder().addInterceptor(ReplayIQOkHttpInterceptor()).build() }`.
- **JS errors:** forward `ErrorUtils.setGlobalHandler` errors to a module method that calls
  `ReplayIQ.logError`, or add a dedicated `js_error` entry point if fatal JS errors should be reported
  as crashes (native crashes are already handled).
- Report the wrapper with `ReplayIQOptions.Builder().wrapper("react-native", "replayiq-react-native/<semver>")`:
  it sets `platform` / `metadata.platform`, `sdk`, `sdk_version` and the user agent.
