# How the Android SDK records, and how a recording replays

This explains what the `replayiq` Android library captures (Views, Jetpack
Compose, and React Native through `@replayiq/react-native`), what it sends,
and how ReplayIQ turns it into a replay. For setup see [README](README.md);
the wire formats are [Recording API v1](../../docs/sdk/recording-api-v1.md)
and [v1.1](../../docs/sdk/recording-api-v1.1-native-dom.md).

## 1. What is captured, and from where

### The screen: Native DOM (default) or screenshots

`recordingMode(AUTO)` (default) records the UI as a **Native DOM**, read from
the activity window's **View tree**:

| Android source | Node sent |
|---|---|
| Any View: frame (dp, relative to its parent), alpha, translation/scale/rotation, `clipChildren` / `clipToOutline`, elevation | `view` with `s.o`, `s.t`, `clip`, shadow |
| Backgrounds: `ColorDrawable`, `GradientDrawable` (colour, stroke, radii, gradients), ripple/inset/state-list (unwrapped), Material shapes | `s.bg`, `s.r`, `s.bw`/`s.bc`, `s.grad` |
| Other backgrounds (nine-patch, layer lists, custom drawables) | an `image` behind the view, rasterised once per look |
| `TextView` / `Button` | `text`: displayed text, size, weight, italic, colour, alignment, line height, max lines |
| `ImageView`, checkbox/radio buttons | `image`: the drawable rasterised once (vectors too), uploaded by sha256 |
| `EditText` | `input`: type (text, password, number, email, phone), hint, length, focus. **Never the value** |
| `ReplayIQ.mask(view)`, `android:tag="replayiq-mask"`, password fields, `maskAll*` options, React Native `<ReplayIQMask>` | `mask`: nothing inside is serialised or uploaded |
| `ScrollView`, `NestedScrollView`, `HorizontalScrollView`, `RecyclerView`, `ListView` | `scroll`: children in content coordinates, scrolling only changes `so` |
| `SurfaceView`, `TextureView`, `WebView`, `VideoView`, `MapView`, ExoPlayer, CameraX preview, Lottie, progress bars, custom `onDraw` views | `island`: cropped from a masked PixelCopy of the window (≤ 2/s, only when changed) |
| Jetpack Compose | from the semantics tree: text with its style, text fields as `input`, clickables' roles and labels, scroll containers, backgrounds/borders/shadows from modifiers, images as islands, `Modifier.replayIQMask()` as `mask` |
| React Native (Fabric and old renderer) | backgrounds, borders and radii via RN's `BackgroundStyleApplicator`; one-sided borders as edge lines; Fabric text from its precomputed layout; RN's debug overlay skipped |

How it runs: an `OnDrawListener` marks the tree dirty; the walk runs after
that draw, at most 30 times a second, and nothing runs while the screen is
static. Each view keeps a stable node id for its lifetime. The walk only
copies values on the main thread; diffing, serialising and gzip happen on
worker threads. A `ui_snapshot` goes on the first frame, an activity /
fragment / `screen()` change, resume, size change and at least every 30 s;
otherwise `ui_mutation`s. Assets are uploaded once (`HEAD`, then
`POST /api/v1/assets`) before the batch that uses them.

In `AUTO`, a screen that is mostly islands (> 50% of its area) switches to
**screenshots** until the next screen. `SCREENSHOT` always sends them: the
window is copied with PixelCopy (API 26+, `View.draw` on 24–25), masks are
painted over **on the device**, and a JPEG goes as a `screen` event at most
2 per second, only when it changed. `FLAG_SECURE` windows are sent blank.

### Everything else

| What | Captured by | Event |
|---|---|---|
| Touches | A `Window.Callback` wrapper (`down`, `move` ≤ every 50 ms, `up`), in dp | `touch` |
| Taps, rage taps (3+ within 700 ms / 48 dp) | Named from the nearest clickable view: content description, visible text, view id or RN testID, or the accessibility label RN reports (`button:"Pay now"`); never class names | `click`, `rage_click` |
| Gestures | Tap, double tap, long press, swipe, pan, pinch | `gesture` |
| Text edits, focus | `EditText` changes (never the value), focus changes | `input`, `focus`, `blur` |
| Screen changes | Activity / AndroidX fragment resumed, `ReplayIQ.screen(name)` | `navigate` |
| HTTP | `ReplayIQOkHttpInterceptor` (installed automatically for React Native's networking) or `recordNetwork`: method, URL without query, status, duration, error | `network` |
| Crashes | Uncaught exception handler: written to disk, sent on the next launch, then the previous handler runs | `js_error` |
| Logs and app errors | `ReplayIQ.log`, `logError`, `recordError` (React Native JS errors) | `console`, `js_error` |
| App state and performance | Lifecycle, app start, screen load, jank (FrameMetrics), hangs ≥ 2 s (watchdog, with the main thread's stack), `onTrimMemory`, keyboard (WindowInsets), orientation, connectivity, deep links, push opens, permissions, thermal/battery saver | the v1.1 signals |
| Your own events | `ReplayIQ.track` | `custom_events` |

## 2. What is sent

Every request is written to `noBackupFilesDir/replayiq/queue` first and sent
in order on its own thread, gzipped, with `device_masked: true`. Batches go
every 5 s, at 50 events, and when the app backgrounds:

```json
{"session_id": "…", "batch_id": "…-000023", "platform": "android", "device_masked": true,
 "events": [
  {"type": 5, "subtype": "ui_snapshot", "timestamp": …, "width": 411.4, "height": 914.3, "density": 2.625,
   "root": {"id": 1, "k": "view", "f": [0,0,411.4,914.3], "c": [
     {"id": 5, "k": "view", "f": [20,276,371,48], "s": {"bg": "#FF4F46E5", "r": [10,10,10,10]}, "role": "button", "label": "Pay now",
      "c": [{"id": 6, "k": "text", "f": [0,14,371,20], "tx": {"v": "Pay now", "size": 16, "w": 600, "col": "#FFFFFFFF", "al": "center"}}]},
     {"id": 8, "k": "scroll", "f": [0,340,411.4,574], "so": [0, 0], "c": [ … ]}]}},
  {"type": 5, "subtype": "ui_mutation", "timestamp": …, "updates": [{"id": 8, "k": "scroll", "f": [0,340,411.4,574], "so": [0, 812]}]},
  {"type": 5, "subtype": "network", "method": "GET", "url": "https://api…/prices", "status": 404, "duration": 85, "timestamp": …}
 ]}
```

## 3. What the server does

1. **Ingest** checks the key and that the batch is `device_masked`, then
   publishes it unchanged to Kafka.
2. **Transformer** keeps the batch as sent and converts it to rrweb:
   - `ui_snapshot` → Meta + FullSnapshot of an HTML page: every node an
     absolutely positioned element with its styles; text as styled text,
     images and islands as `<img>` of the asset URL, masks as striped blocks,
     inputs as boxes with dots;
   - `ui_mutation` → one rrweb mutation, plus scroll events for `so`;
   - `screen` → a one-image page, later frames swap its `src`;
   - `touch` → rrweb touch interactions.

   UI text and app text are scrubbed for PII patterns.
3. **Storage** saves it under its `batch_id` with time range and keyframes as
   metadata; assets are stored per project.

## 4. How it renders on replay

The dashboard's rrweb player rebuilds the page in the browser and applies the
changes in time order: a reconstruction of the app from its View tree, not a
video. Layout, colours, rounded corners, borders, shadows and images match;
text is real (Roboto renders exactly when the viewer has it); lists scroll
smoothly; masks are striped blocks; inputs show dots; maps, video and custom
drawing are small pictures. Screens that fell back to screenshots replay as
those images. Touches, timeline markers (errors, failed requests, rage taps,
hangs, frozen frames) and the Behaviour, Console and Network tabs come from
the other events.

## 5. Not captured

Dialogs, bottom-sheet dialogs, popups and toasts (only the activity window is
recorded; touches on them still are), the soft keyboard, request/response
bodies and headers, field values. Native DOM doesn't describe compound
drawables next to text, `foreground` drawables or 3D rotations; Compose
layout nodes without semantics aren't seen, and Compose text fields send no
`input` events.
