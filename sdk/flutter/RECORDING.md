# How the Flutter SDK records, and how a recording replays

This explains what `replayiq_flutter` captures in a Flutter app, what it
sends, and how ReplayIQ turns it into a replay. For setup see
[README](README.md); the wire formats are
[Recording API v1](../../docs/sdk/recording-api-v1.md) (screenshots, app
events) and [v1.1](../../docs/sdk/recording-api-v1.1-native-dom.md) (Native DOM,
mobile signals).

## 1. What is captured, and from where

### The screen: Native DOM (default) or screenshots

`recordingMode: RecordingMode.auto` (default) records the UI as a **Native
DOM**: a tree of nodes describing what Flutter draws, plus small changes.
Flutter paints everything itself, so its **render tree** describes almost the
whole screen:

| Flutter render object | Node sent |
|---|---|
| `RenderParagraph` (every `Text`) | `text`: string (spans joined), font family, size, weight, italic, colour, alignment, line height, max lines |
| `RenderDecoratedBox` / `RenderColoredBox` / `RenderPhysicalModel` / `RenderPhysicalShape` (Container, Card, Material, buttons) | `view` with background, corner radii, border, shadow, gradient |
| `RenderClipRect` / `RRect` / `Oval` / `Path` | `clip` (with radius) |
| `RenderOpacity`, transforms | `s.o`, `s.t` (2D affine about the centre) |
| `RenderImage` | `image`: the decoded image, uploaded once as an asset by sha256 (≤ 1x) |
| `RenderEditable` (every `TextField`) | `input`: type, length, focus. **Never the value.** Hints/labels are separate `text` nodes |
| `ReplayIQMask` | `mask`: a solid block; nothing inside is serialised or uploaded |
| Scrollables (`RenderViewportBase`, `RenderSingleChildViewport`) | `scroll`: children in content coordinates, scrolling only changes `so` |
| `RenderCustomPaint`, checkboxes and other things it can't describe | `island`: that area cropped from a capture and uploaded (≤ 2/s, only when it changed) |
| Platform views (`RenderUiKitView`, `RenderAndroidView`: maps, web views) | `island` without pixels and a `hint` (Flutter can't capture them) |

How it runs: after each frame that repainted, the walker reads the render
tree (each render object keeps a stable node id), at most 30 times a second
and never while the screen is static. Diffing and serialising happen off the
UI thread. A `ui_snapshot` is sent on the first frame, a route change, a size
change, resume, and at least every 30 s; otherwise `ui_mutation`s with adds,
removes and updates. Images, fonts from the app's font manifest and islands
are uploaded once (`HEAD`, then `POST /api/v1/assets`).

In `auto`, a screen where islands cover more than half the area (a map, a
game) switches to **screenshots** until the next route change.
`RecordingMode.screenshot` always sends screenshots: the Flutter view is
rasterized, sensitive areas are painted over **on the device**, and a JPEG is
sent as a `screen` event at most 2 per second, only when it changed.

### Everything else

| What | Captured by | Event |
|---|---|---|
| Touches | Flutter pointer events (`down`, `move` ≤ every 50 ms, `up`) | `touch` |
| Taps, rage taps (3+ within 700 ms / 48 pt) | Gestures, named from the widget under the finger (`button:"Pay now"`, `input:"Email"`, `listitem:"Item 3"`) | `click`, `rage_click` |
| Gestures | Double tap, long press, pan, swipe, pinch | `gesture` |
| Text-field edits, focus | `EditableText` focus and changes (never the value) | `input`, `focus`, `blur` |
| Screen changes | `ReplayIQ.navigatorObserver` on your `Navigator` → `app://<bundle id>/<route>` | `navigate` |
| HTTP | `HttpOverrides`: every dart:io request (package:http, Dio, `Image.network`): method, URL, status, duration, error | `network` |
| Errors | `FlutterError.onError` and `PlatformDispatcher.onError`, with file, line and stack | `js_error` |
| Logs | `debugPrint`, and `print` inside `ReplayIQ.runZoned` | `console` |
| App state and performance | Lifecycle, app start, screen load, frame timings (jank), keyboard, orientation, memory | `lifecycle`, `app_start`, `screen_load`, `jank`, `keyboard`, `orientation`, `memory` |
| Your own events | `ReplayIQ.track` | `custom_events` |

## 2. What is sent

Batches go every 5 s, at 50 events, or when the app is backgrounded; they are
written to disk first (so they survive an app kill), gzipped, and marked
`device_masked: true`:

```json
{"session_id": "…", "batch_id": "…-000042", "platform": "flutter", "device_masked": true,
 "events": [
  {"type": 5, "subtype": "ui_snapshot", "timestamp": …, "width": 393, "height": 852,
   "root": {"id": 1, "k": "view", "f": [0,0,393,852], "c": [
     {"id": 7, "k": "text", "f": [16,60,361,34], "tx": {"v": "Checkout", "size": 28, "w": 700, "col": "#FF111827"}},
     {"id": 9, "k": "input", "f": [16,130,361,44], "in": {"type": "text", "len": 0}},
     {"id": 12, "k": "mask", "f": [16,184,361,44]}]}},
  {"type": 5, "subtype": "ui_mutation", "timestamp": …,
   "updates": [{"id": 9, "k": "input", "f": [16,130,361,44], "in": {"type": "text", "len": 4, "focus": true}}]},
  {"type": 5, "subtype": "touch", "timestamp": …, "x": 196, "y": 610, "phase": "down"},
  {"type": 5, "subtype": "click", "selector": "button:\"Pay now\"", "timestamp": …}
 ]}
```

## 3. What the server does

1. **Ingest** checks the key and that mobile batches are `device_masked`
   (only the phone can mask pixels), then publishes the batch unchanged to
   Kafka.
2. **Transformer** keeps the batch as sent (so it can be converted again
   later) and converts it to rrweb, the format the player understands:
   - `ui_snapshot` → a Meta event plus a FullSnapshot of an HTML page where
     every node is an absolutely positioned element with its styles: a
     `text` node is styled text, `image`/`island` an `<img>` of the asset
     URL, `mask` a striped block, `input` a box showing dots for the length;
   - `ui_mutation` → one rrweb mutation (adds, removes, style/text changes)
     plus scroll events for `so` changes;
   - `screen` → keyframes become a page holding one `<img>`; other frames
     just swap that image's `src`;
   - `touch` → rrweb touch interactions (the replay's touch indicator).

   UI text and app text (logs, URLs) are also scrubbed for PII patterns.
3. **Storage** saves the result under its `batch_id`, with time range and
   keyframes as metadata. Assets live in their own bucket, per project.

## 4. How it renders on replay

The dashboard's rrweb player rebuilds that HTML page in the browser and
applies the changes in time order. What you see is a reconstruction of the
app from its own render tree, not a video:

- text, colours, borders, shadows and images match the app; text is sharp at
  any zoom and searchable;
- scrolling and animations (opacity, transforms) are smooth, up to 30 updates
  a second;
- masked areas are striped blocks, inputs show dots, never values;
- custom-painted areas are small pictures (islands); platform views are grey
  boxes labelled with their kind;
- screens recorded as screenshots replay as those (masked) images.

Taps show as touch indicators; errors, failed requests and rage taps are
timeline markers; the other events fill the Behaviour, Console and Network
tabs.

## 5. Not captured

Request/response bodies and headers, text-field values, the system keyboard
and status bar, platform views' pixels, and anything drawn without a render
object the walker understands (it becomes an island instead).
