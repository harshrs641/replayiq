# POC: Mixpanel's free Flutter replay SDK -> ReplayIQ

Proves that a mobile app can feed ReplayIQ **without any backend change**, using
Mixpanel's Apache-2.0 `mixpanel_flutter_session_replay` package as the recorder.

```
Flutter app (Mixpanel SDK, serverUrl = http://<mac>.local:9090)
   |  POST /record  (gzip JSON array of rrweb events, Basic auth = token)
   v
adapter.js  (this folder, :9090)
   |  POST /api/v1/sessions        once per replay_id
   |  POST /api/v1/events          size-bounded chunks (EventBatch)
   |  POST /api/v1/sessions/{id}/end   after SESSION_IDLE_MS idle  -> triggers AI analysis
   v
ReplayIQ gateway :8080  ->  Kafka -> MinIO / Ollama  ->  dashboard (rrweb-player)
```

The Mixpanel SDK already emits rrweb events (screenshot inside a fake DOM, touches
as rrweb mouse/touch events, plus a "wireframe" custom event listing visible
elements). The adapter forwards them and adds what ReplayIQ's tokenizer needs:

| From the SDK | Adapter output |
|---|---|
| Meta (type 4) | same, plus `href: "app://flutter"` so the AI sees "navigate" |
| touchStart (type 3 / source 2 / type 7) | extra `{subtype:"click", selector:'button:"Pay now"'}` |
| 3+ touches within 700 ms / 48 px | extra `{subtype:"rage_click"}` (once per burst) |
| wireframe (type 5, tag `mp_wireframe`) | forwarded; also used to label taps |
| `replay_id`, `distinct_id`, Basic-auth token | `session_id`, `user_id`, `project_id` |

## 1. Run the tests (no stack needed)

```bash
cd poc/mixpanel-adapter
node --test test.js        # Node 18+; uses a mock ReplayIQ
```

## 2. Start ReplayIQ as usual

```bash
./dev.sh up        # or docker compose up -d
curl http://localhost:8080/health
```

## 3. Start the adapter

```bash
REPLAYIQ_URL=http://localhost:8080 \
ALLOWED_TOKENS=demo \
SESSION_IDLE_MS=20000 \
node poc/mixpanel-adapter/adapter.js
```

| Env | Default | Meaning |
|---|---|---|
| `PORT` | 9090 | adapter port |
| `REPLAYIQ_URL` | http://localhost:8080 | ReplayIQ gateway |
| `ALLOWED_TOKENS` | (empty = accept any) | comma-separated; **set this before exposing the adapter on a network or tunnel** |
| `PROJECT_ID` | (token) | force all sessions into one ReplayIQ project |
| `SESSION_IDLE_MS` | 30000 | no batches for this long -> end session -> AI analysis |
| `MAX_CHUNK_BYTES` | 900000 | per-POST cap (ReplayIQ caps bodies at 5 MB; stay under Kafka's 1 MB default) |
| `KEYFRAME_MS` | 30000 | screenshot frames in between are sent as an img `src` swap instead of a full page snapshot (smooth playback); a real snapshot is kept this often so seeking stays fast |

## 4. Pick the adapter URL (no tunnel needed on the same network)

Upstream, the Mixpanel SDK refuses any `serverUrl` that is not `https://`. The
patched copy in `flutter_poc/third_party/` also accepts plain `http://` for
**local-network hosts only** (`*.local`, localhost, private IPs, IPv6
link-local/ULA); public hosts still need `https://`. The app allows local HTTP
on iOS (`NSAllowsLocalNetworking` in `Info.plist`) and in Android debug builds
(`usesCleartextTraffic` in `src/debug/AndroidManifest.xml`).

| Device | `RIQ_URL` |
|---|---|
| Phone on the same Wi-Fi / hotspot as the Mac | `http://<mac-name>.local:9090` (`scutil --get LocalHostName`) |
| Android emulator | `http://10.0.2.2:9090` |
| iOS simulator | `http://localhost:9090` |

On iOS the first upload shows a "Local Network" permission prompt; allow it.
The adapter is reachable by anyone on that network, so keep `ALLOWED_TOKENS` set.

Only if the phone is on a different network do you need a public HTTPS URL,
e.g. `cloudflared tunnel --url http://localhost:9090` (quick tunnels expire;
the URL changes on every run).

## 5. Run the demo app (needs Flutter >= 3.38)

```bash
cd poc/mixpanel-adapter/flutter_poc
flutter pub get
flutter run --dart-define=RIQ_URL=http://$(scutil --get LocalHostName).local:9090 --dart-define=RIQ_PROJECT=demo
```

Do not re-run `flutter create` here: it would overwrite the iOS/Android
local-network settings above.

Note: `flutter_poc/` was written against the SDK's exported API but **not compiled** in
the environment that created it. Expect to fix a typo or two.

Then in the app: type a name, tap **Pay now** 3-4 times quickly (rage tap), tap **Load prices
(fails)** and **Apply coupon (throws)**, open **Order summary**, scroll, go back, and either tap
**Flush now** or send the app to the background. After ~`SESSION_IDLE_MS` the adapter ends the
session.

### Console, network, errors and navigation (companion)

The Mixpanel SDK records only the screen. `flutter_poc/lib/replayiq_companion.dart` records what
the app does, in the web SDK's event shapes, tagged with the SDK's `replayId`, and posts it to the
adapter's `POST /riq/events` (same token auth as `/record`), which adds it to the same session:

| Hook | Records |
|---|---|
| `navigatorObservers: [companion.navigatorObserver]` | screen changes as `app://flutter/<route name>` |
| `companion.captureAllHttp()` | every request made through dart:io's `HttpClient` (package:http, Dio, `Image.network`): method, URL, status, duration; status 0 plus the error when there is no response. The recorders' own uploads to the adapter are skipped |
| `companion.httpClient()` | the same, for chosen calls only (when not using `captureAllHttp`) |
| `companion.installErrorHandlers()` | `FlutterError.onError` and uncaught async errors, with stack and first app frame |
| `companion.runCapturingPrints(() => runApp(...))` | `print`/`debugPrint` lines (skips the SDK's own logs and Flutter's printed error reports) |

Unlike the screenshots, this text is not masked on the phone; ReplayIQ redacts PII patterns in
these fields on ingest (`masking.MaskTextFields`).

## 6. What to check

- Adapter log: `batch ok replay=...` lines, then `session ended`.
- Dashboard (http://localhost:3000): a new session with user `poc_user_1`; the replay is a
  portrait phone-screen slideshow with touch indicators.
- AI summary: should mention taps on `button:"Pay now"` and a rage click. Analysis is skipped
  for sessions under 5 s or 5 events (see `pipeline/analyze.go`).
- Card field: shown as dots (`obscureText`).
- Behaviour / Console / Network tabs: the screens, the 404 from **Load prices**, the error from
  **Apply coupon** (with `main.dart` line and stack) and the app's log lines.

## Known limits of this POC

- **Companion coverage:** requests made by plugins' native code (iOS/Android networking, not
  Dart) aren't recorded, and navigation only for named routes reads well (unnamed ones show as
  `app://flutter/`).
- **Privacy:** pixels are masked on the device; ReplayIQ's server-side masking cannot redact
  pixels, and the raw bucket stores batches unmasked. Default SDK masking hides all text, which
  also blanks the wireframe labels; the demo unmasks text to make the AI output readable. Decide
  your masking policy before real use.
- **Size/perf:** every screenshot is a full snapshot with a base64 JPEG, up to 2 per second;
  ReplayIQ's masking regexes run over that string. Fine for a POC, not for production.
- **Dashboard:** fixed 480 px player height and it drops type-5 events, so wireframes are stored
  but not displayed.
- **Licensing/terms:** the SDK is Apache-2.0 but built for Mixpanel's service. Fine for a POC;
  for production, fork it or write your own recorder emitting the same event shapes.
