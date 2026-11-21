---
name: flutter-sdk
description: Map of the ReplayIQ Flutter SDK (Dart package replayiq_flutter in sdk/flutter) - which file does what, the render-tree Native DOM walker, screenshot fallback, transport, tests, the example app with its dart-defines and autopilot, and pitfalls. Use before reading or changing anything in sdk/flutter or debugging a Flutter recording.
---

# ReplayIQ Flutter SDK

Pure Dart package `replayiq_flutter`. There is no native plugin code for
recording. It walks Flutter's **render tree** itself.

- What is captured and how it replays: `sdk/flutter/RECORDING.md`
- Setup: `sdk/flutter/README.md`
- Wire formats: `docs/sdk/recording-api-v1*.md`

Some masking and screenshot code is derived from
mixpanel_flutter_session_replay (Apache-2.0). Keep the headers and `NOTICE`.

## Public API (lib/src/replayiq.dart, exported by lib/replayiq_flutter.dart)

Setup:

```dart
void main() => ReplayIQ.runZoned(() async {
  await ReplayIQ.init(key: …, endpoint: …, /* options */);
  runApp(MaterialApp(navigatorObservers: [ReplayIQ.navigatorObserver], …));
});
```

- `runZoned` is optional. It only adds `print` capture.
- Other calls: `identify`, `track`, `log`, `logError`, `recordError`,
  `recordNetwork`, `httpClient([inner])` (wraps `package:http`), `optOut` /
  `optIn`, `start` / `stop`, `reset`, `flush`, `sessionId`, `isRecording`,
  `debugStats()`.
- `RecordingMode`: auto, nativeDom, screenshot. Data mode (masked/raw) is in
  `lib/src/options.dart`.
- Widgets: `ReplayIQMask` / `ReplayIQUnmask` (`lib/src/widgets/mask.dart`).

## File map (lib/src)

| File | Role |
|---|---|
| `replayiq.dart` | Facade, init, early-event buffer, device info, guards (SDK errors never reach the app) |
| `options.dart` | Data mode and capture options |
| `version.dart` | SDK version. **Keep in sync with pubspec.yaml** |
| `session/recorder.dart` | Sessions, batching, consent: everything between "an event happened" and the outbox |
| `session/state_store.dart` | Persisted session, sampling decision, batch seq |
| `transport/outbox.dart` | Disk queue (gzipped body + header per request), ordered by kind |
| `transport/uploader.dart` | Send + retry/backoff (1 s→60 s) per spec |
| `nativedom/walker.dart` | Render tree → nodes: RenderParagraph text, images, decorated boxes, clips, scrollables, RenderEditable inputs (`len`, `filled` for obscured, `tx` via `_style()`, `pad: [0,0]`), masks, islands |
| `nativedom/node.dart` | Node model (`k`: view/text/image/input/island/scroll/mask, `f` relative to parent) |
| `nativedom/differ.dart` | Flattened diff → `ui_mutation` |
| `nativedom/dom_recorder.dart` | Walk after frames (≤ every `minInterval`), snapshot vs mutation, timing samples |
| `nativedom/assets.dart` | Asset upload queue + known-hash cache on disk |
| `capture/screen_recorder.dart`, `screen_capturer.dart` | Screenshot mode: change-driven, rate-limited, masked before encoding |
| `capture/mask_detector.dart` | Finds mask rects (text fields, `ReplayIQMask`) |
| `behaviour/touch.dart` | `touch`, `click`, `rage_click` |
| `behaviour/selector.dart` | `role:"label"` names for tapped widgets |
| `behaviour/navigation.dart` | `navigate` via NavigatorObserver (`app://<bundle>/<route name>`). **Unnamed routes give poor URLs** |
| `behaviour/input.dart` | `input` on blur after edit (never the value) |
| `behaviour/signals.dart` | lifecycle, app_start, screen_load, jank, keyboard, orientation, memory |
| `behaviour/errors_console.dart` | FlutterError / zone errors, debugPrint/print → `console` |
| `behaviour/http_capture.dart` | `network` events (headers/bodies in raw mode, always-masked) |
| `privacy/redact.dart` | Always-masked rules. Must match `backend/internal/masking/always.go` |
| `util/` | ids, ISO time, SDK log (root zone, debug only) |

## Build and test

```bash
cd sdk/flutter
flutter test                       # all package tests
flutter test test/native_dom_test.dart
cd example && flutter test
```

Package tests:
- `native_dom_test.dart`: walker, including input style
- `capture_test.dart`
- `behaviour_test.dart`
- `selector_test.dart`
- `recorder_test.dart`
- `transport_test.dart`
- `http_capture_test.dart`
- `network_v12_test.dart`
- `redact_console_test.dart`
- `data_mode_test.dart`

## Example app

`example/lib/main.dart` is a shop → checkout → order summary flow with a
generated image asset. Its behaviour is set with dart-defines:

```bash
cd sdk/flutter/example
flutter run --dart-define=RIQ_ENDPOINT=http://localhost:8080 --dart-define=RIQ_KEY=verify \
  --dart-define=RIQ_MODE=auto --dart-define=RIQ_DATA_MODE=masked --dart-define=RIQ_AUTOPILOT=60
```

`RIQ_AUTOPILOT=<seconds>` runs the scripted use in `example/lib/autopilot.dart`,
which is useful for cost measurement. Inspect the session with the
`debug-replay` skill (repo root).

## Pitfalls

- Pushed routes render correctly: the walker follows the top route. A "wrong
  route" seen only in FullSnapshot text was a misdiagnosis before. Check the
  rendered replay.
- Obscured fields send `filled`, never a length. Masked mode never sends `v`.
- Text scale: styles go through `TextScaler`. Use `_style(TextStyle?, TextScaler)`
  for any new text-like node.
- Any new node field must also go in the spec, the backend transform and
  test, and the iOS and Android walkers.
