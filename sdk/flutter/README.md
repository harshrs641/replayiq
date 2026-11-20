# replayiq_flutter

> How it records, what it sends and how a recording replays: [RECORDING.md](RECORDING.md).

ReplayIQ session replay for Flutter apps (iOS and Android).

One `init` call records:

| What | How it shows in ReplayIQ |
|---|---|
| The screen, as screenshots masked **on the device** | The replay (seekable, keyframe every 30 s) |
| Touches (down, move, up) | Touch indicator in the replay |
| Taps, rage taps (3+ within 700 ms / 48 pt), text-field edits | Behaviour tab, AI analysis |
| Screen changes (with `ReplayIQ.navigatorObserver`) | Behaviour tab, session URL |
| `debugPrint` (and `print`, with `ReplayIQ.runZoned`) | Console tab |
| Flutter and uncaught errors, with file and line | Console tab, timeline, AI analysis |
| Every HTTP request: method, URL, status, duration | Network tab |
| Your own events (`ReplayIQ.track`) | `custom_events` |

It implements [Recording API v1](../../docs/sdk/recording-api-v1.md).

## Install

Until it is published, depend on it from this repository:

```yaml
dependencies:
  replayiq_flutter:
    git:
      url: <this repository>
      path: sdk/flutter
```

Requirements: Flutter 3.32+, iOS 15+, Android API 24+.

> **iOS and Swift Package Manager:** Flutter requires a plugin used by
> path or git to sit in a folder named after the package, and this one sits
> in `sdk/flutter`. Use CocoaPods for now (add
> `config: enable-swift-package-manager: false` under `flutter:` in your
> app's `pubspec.yaml`, as [`example/`](example) does) until the package is
> published to pub.dev, where the folder name matches.

## Set up

```dart
import 'package:flutter/material.dart';
import 'package:replayiq_flutter/replayiq_flutter.dart';

void main() => ReplayIQ.runZoned(() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ReplayIQ.init(
    key: 'YOUR_INGEST_KEY',                  // for now: your project id
    endpoint: 'https://ingest.replayiq.example',
  );
  runApp(const MyApp());
});

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorObservers: [ReplayIQ.navigatorObserver],
    routes: {...},
  );
}
```

- No widget needs wrapping: the SDK captures the whole Flutter view.
- `ReplayIQ.runZoned` is optional; it only adds `print` output to the
  Console tab. If you use it, call `ensureInitialized` inside it (as above)
  so Flutter sees one zone.
- Name your routes (`RouteSettings(name: '/checkout')`, or `routes:`) to
  get readable URLs: `app://<bundle id>/checkout`. For go_router, pass
  `ReplayIQ.navigatorObserver` in `GoRouter(observers: [...])`.
- Local testing: `http://localhost:8080` works from the iOS simulator,
  `http://10.0.2.2:8080` from the Android emulator (allow cleartext traffic
  in debug builds).

## API

```dart
await ReplayIQ.init(
  key: '...',
  endpoint: '...',
  userId: 'user_123',                // optional, same as identify()
  sampleRate: 0.25,                  // record 25% of sessions (default 1.0)
  maskAllText: false,                // paint over all text, not only inputs
  maskAllImages: false,              // paint over all images
  captureAllHttp: true,              // record dart:io HTTP (http, Dio, Image.network)
  captureErrors: true,               // FlutterError.onError + PlatformDispatcher.onError
  captureConsole: true,              // debugPrint
  recordScreen: true,                // false sends only events, no screenshots/touches
  screenshotScale: 1.0,              // image pixels per point (1x keeps ~40 KB/frame)
  jpegQuality: 60,
  recordingMode: RecordingMode.auto, // auto | nativeDom | screenshot
  debug: false,                      // print the SDK's own log lines (debug builds)
);

ReplayIQ.identify('user_123', traits: {'plan': 'pro'});
ReplayIQ.track('checkout_started', {'items': 3});
ReplayIQ.log('Payment sheet opened', level: 'warn');   // Console tab
ReplayIQ.recordError(error, stackTrace);               // a caught error
await ReplayIQ.optOut();   // stop, delete what is queued, remembered across launches
await ReplayIQ.optIn();
await ReplayIQ.stop();     // end the session now (starts the AI analysis)
await ReplayIQ.start();    // a new session after stop()
await ReplayIQ.flush();    // send buffered events now
ReplayIQ.sessionId;        // the session being recorded
ReplayIQ.isRecording;
```

Every call is safe before `init` finishes and never throws; SDK failures
are swallowed (and printed only with `debug: true` in debug builds).

## Recording modes (prototype)

- `RecordingMode.nativeDom` records the UI as a tree of nodes plus small
  changes ([Recording API v1.1](../../docs/sdk/recording-api-v1.1-native-dom.md)):
  text with its font and colour, boxes with their background, radius,
  border and shadow, images (uploaded once as assets, at most 1x), scroll
  views as content offsets, text fields as empty inputs, `ReplayIQMask` as
  solid blocks. Custom painters, checkboxes and other things it can't
  describe are sent as small cropped bitmaps ("islands"). Light and smooth
  (up to 30 changes/s), but needs the v1.1 server transformer to play.
- `RecordingMode.screenshot` sends masked screenshots (v1), as before.
- `RecordingMode.auto` (default) uses native DOM and switches to
  screenshots on a screen where islands cover more than half of it,
  switching back on the next route change.

In every mode the SDK also records mobile signals: `gesture` (tap, double tap, long
press, pan, swipe, pinch), `focus`/`blur`, `lifecycle`, `app_start`,
`screen_load`, `jank`, `keyboard`, `orientation` and `memory`.

## Masking

Masking happens on the device, before a screenshot is encoded: masked
pixels never leave the phone. The server stores these sessions as
"Masked on device".

| Content | Default |
|---|---|
| Text fields (`TextField`, `TextFormField`, `CupertinoTextField`, any `EditableText`), including password fields | Always masked, cannot be unmasked |
| Anything inside `ReplayIQMask` | Masked |
| Other text | Visible; `maskAllText: true` masks it |
| Images | Visible; `maskAllImages: true` masks them |
| Inside `ReplayIQUnmask` | Exempt from `maskAllText` / `maskAllImages` (text fields stay masked) |

```dart
ReplayIQMask(child: Text(user.email))
ReplayIQMask(child: CardPreview(card))
ReplayIQUnmask(child: Text('Order total'))   // with maskAllText: true
```

Labels sent with events follow the same rules: a tap inside
`ReplayIQMask` is sent as `button` without its label, and with
`maskAllText` labels are dropped unless inside `ReplayIQUnmask`. Text-field
events carry the field's label or hint (`input:"Card number"`), never what
was typed. Taps on plain text send only `text`, since such text may be
personal.

Not captured at all: request and response bodies and headers, field
values, platform views (maps, web views: they appear blank), the system
keyboard and the status bar.

## Tap selectors

`click` and `rage_click` name the widget under the finger as
`role:"label"`:

| Widget | Selector |
|---|---|
| `ElevatedButton(child: Text('Pay now'))` and any `*Button` | `button:"Pay now"` |
| `IconButton(tooltip: 'Delete')`, `BackButton` | `button:"Delete"`, `button:"Back"` |
| `TextField(decoration: InputDecoration(labelText: 'Email'))` | `input:"Email"` |
| `ListTile(title: Text('Item 3'))` | `listitem:"Item 3"` |
| `Checkbox` / `Switch` / `Radio` / `Slider` / `Tab` (and their list tiles) | `checkbox:"..."`, `switch:"..."`, ... |
| `InkWell` / `GestureDetector` with `onTap` | `button:"<text inside>"` |
| Anything else | `text`, `image` or `view` |

## How it sends data

- A session is a UUID. It survives app restarts and ends after 30 minutes in
  the background (or `stop()`), when the SDK sends
  `POST /api/v1/sessions/{id}/end`.
- `POST /api/v1/sessions` goes out with the session's first batch, so an
  `identify()` right after launch is included.
- Events are batched every 5 s, at 50 events, at ~3 MB, and when the app goes
  to the background (with an iOS background task to finish the upload).
- Batches are gzipped, carry `batch_id = <session id>-<sequence>` and
  `device_masked: true`, and are written to disk before sending, so they
  survive an app kill and are sent on the next launch.
- Responses follow the API's table: 2xx done; 400 dropped; 401/403 stop
  recording for this app run; 413 split in two and resent; 429 wait
  `Retry-After`; 5xx and network errors retry the same `batch_id` after 1 s,
  2 s, 4 s ... 60 s. At most ~5 MB / 1000 events wait on disk; the oldest
  batches are dropped first.
- Screenshots are taken only when the screen changed, at most 2 per second,
  paused in the background. Mask detection walks the widget tree on the UI
  thread; rasterizing and JPEG encoding run on the raster and a native
  background thread; gzip of screenshot batches runs in a background
  isolate.

## Example

[`example/`](example) is a checkout demo (text fields, a masked card, a
button to rage-tap, a named route, a failing request, a thrown error):

```bash
cd example
flutter run --dart-define=RIQ_ENDPOINT=http://localhost:8080 --dart-define=RIQ_KEY=verify
```

## Development

```bash
flutter analyze
flutter test
cd example && flutter test
```

## License and attribution

Apache License 2.0 (see [LICENSE](LICENSE)). The capture side (screenshot
capture, on-device masking, touch sampling, capture scheduling, native JPEG
encoders) is derived from Mixpanel's Apache-2.0
`mixpanel_flutter_session_replay` 2.1.0; see [NOTICE](NOTICE). Derived files
say so in their header.
