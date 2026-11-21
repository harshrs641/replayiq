# How the iOS SDK records, and how a recording replays

This explains what the `ReplayIQ` Swift package captures in an iOS app (UIKit,
SwiftUI, and React Native through `@replayiq/react-native`), what it sends,
and how ReplayIQ turns it into a replay. For setup see [README](README.md);
the wire formats are [Recording API v1](../../docs/sdk/recording-api-v1.md)
and [v1.1](../../docs/sdk/recording-api-v1.1-native-dom.md).

## 1. What is captured, and from where

### The screen: Native DOM (default) or screenshots

`options.recordingMode = .auto` (default) records the UI as a **Native DOM**.
UIKit and SwiftUI both render into the key window's **CALayer tree**, so the
walker reads that tree:

| iOS source | Node sent |
|---|---|
| Any layer that draws: background colour, `cornerRadius` (+ `maskedCorners`), border, shadow, opacity, 2D transform, `masksToBounds` | `view` with `s.bg`, `s.r`, `s.bw`/`s.bc`, `s.sh`, `s.o`, `s.t`, `clip`. Layers that draw nothing are folded into their children |
| `CAGradientLayer` | `s.grad` |
| `UILabel`, `UITextView`, `CATextLayer` | `text`: string, font, size, weight, colour, alignment, lines |
| React Native paragraph views (`RCTParagraphComponentView`) | `text` from the component's attributed string |
| `UIImageView` and layer images | `image`: uploaded once as an asset by sha256 (≤ 1x) |
| Stretchable (9-slice) border images, e.g. React Native borders | read as a border (width, colour, radius) instead of a stretched picture |
| `UITextField`, editable `UITextView` (SwiftUI `TextField`, `SecureField`, `TextEditor`) | `input`: type, placeholder, length, focus. **Never the value**; secure fields send no length |
| `view.replayIQMasked = true`, SwiftUI `.replayIQMask()`, React Native `<ReplayIQMask>` | `mask`: nothing inside is serialised or uploaded |
| `UIScrollView` | `scroll`: children in content coordinates, scrolling only changes `so` |
| SwiftUI `Text` (drawn into layer bitmaps), shape layers, custom `draw(_:)` | `island`: a small cropped bitmap, labelled with its accessibility text |
| `MKMapView`, `AVPlayerLayer`, `WKWebView`, Metal views | `island` cropped from a masked screen capture (≤ 2/s, only when changed) |
| Camera previews | an empty box with `hint: "camera"` (never captured) |

Layers are visited in paint order (`zPosition`, then order), so content lands
above its own background.

When it walks: after touches, screen changes, network responses, keyboard
and app events; up to 30 times a second while anything animates or scrolls;
otherwise once a second. An unchanged screen sends nothing. The walk runs on
the main thread; hashing, encoding, diffing and serialising on a utility
queue. A `ui_snapshot` goes on the first frame, a screen change, size change,
resume and at least every 30 s; otherwise `ui_mutation`s. Assets are uploaded
once (`HEAD`, then `POST /api/v1/assets`).

In `.auto`, a screen that is more than half islands (a map, video, game)
switches to **screenshots** until that screen goes away. `.screenshot` always
sends them: the key window is drawn with `drawHierarchy`, masks (text fields,
marked views) are painted over **on the device**, and a JPEG goes as a
`screen` event at most 2 per second, only when the pixels changed.

### Everything else

| What | Captured by | Event |
|---|---|---|
| Touches | `UIApplication.sendEvent` (`down`, `move` ≤ every 50 ms, `up`); keyboard windows never | `touch` |
| Taps, rage taps | Named from accessibility: the view's label or button title, the nearest button/control around tapped text, or the SwiftUI accessibility element under the finger (`button:"Pay now"`) | `click`, `rage_click` |
| Gestures | Double tap, long press, swipe, pan, pinch | `gesture` |
| Text edits, focus | Text field changes (never the value), focus changes | `input`, `focus`, `blur` |
| Screen changes | UIKit `viewDidAppear`, `ReplayIQ.screen(_:)`, `.replayIQScreen(_:)` | `navigate` |
| HTTP | A `URLProtocol` on `URLSession.shared` and on `.default`/`.ephemeral` configurations: method, URL, status, duration, error (not the SDK's own uploads) | `network` |
| Crashes | Uncaught `NSException`s and fatal signals, written to disk at crash time, sent on the next launch | `js_error` |
| Logs and app errors | `ReplayIQ.log`, `ReplayIQ.recordError` (used for React Native JS errors) | `console`, `js_error` |
| App state and performance | Lifecycle, app start, screen load, jank (display link), hangs ≥ 2 s (watchdog), memory warnings, keyboard, orientation, connectivity, deep links, push opens, permissions, thermal/power | the v1.1 signals |
| Your own events | `ReplayIQ.track` | `custom_events` |

## 2. What is sent

Every request is written to `Application Support/ReplayIQ/queue` first and
sent in order, gzipped, with `device_masked: true`. Batches go every 5 s, at
50 events, at 2 MB, and when the app backgrounds:

```json
{"session_id": "…", "batch_id": "…-000017", "platform": "ios", "device_masked": true,
 "events": [
  {"type": 5, "subtype": "ui_snapshot", "timestamp": …, "width": 402, "height": 874, "density": 3,
   "root": {"id": 1, "k": "view", "f": [0,0,402,874], "c": [
     {"id": 31, "k": "view", "f": [20,157,362,43], "s": {"bg": "#FFFFFFFF", "r": [8,8,8,8], "bw": 1, "bc": "#FFD1D5DB"},
      "c": [{"id": 32, "k": "input", "f": [1,1,360,41], "in": {"type": "text", "ph": "Full name"}}]},
     {"id": 40, "k": "text", "f": [20,82,362,34], "tx": {"v": "Checkout", "size": 28, "w": 700}}]}},
  {"type": 5, "subtype": "click", "selector": "button:\"Pay now\"", "timestamp": …},
  {"type": 5, "subtype": "hang", "duration": 2400, "timestamp": …}
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
   - `ui_mutation` → one rrweb mutation, plus scroll events;
   - `screen` → a one-image page, later frames swap its `src`;
   - `touch` → rrweb touch interactions.

   UI text and app text are scrubbed for PII patterns.
3. **Storage** saves it under its `batch_id` with time range and keyframes as
   metadata; assets are stored per project.

## 4. How it renders on replay

The dashboard's rrweb player rebuilds the page in the browser and applies the
changes in time order: a reconstruction of the app from its layer tree.
Layout, colours, borders, rounded corners, shadows and images match; text
is real text (Apple's system font renders exactly on a Mac, with a close
substitute elsewhere); scrolling and animations are smooth. Masks are striped
blocks, inputs show dots, islands are small pictures. Screens that fell back
to screenshots replay as those images. Touches, timeline markers (errors,
failed requests, rage taps, hangs, frozen frames) and the Behaviour, Console
and Network tabs come from the other events.

## 5. Not captured

The system keyboard and system alerts (separate windows), camera previews,
request/response bodies and headers, field values, URLSession upload tasks
and background sessions. Blur/vibrancy effects are approximated.
