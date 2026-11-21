# ReplayIQ Recording API v1.2: data mode, full console and network logs

Additions to [v1](recording-api-v1.md) and [v1.1](recording-api-v1.1-native-dom.md).
Same endpoints, envelope, auth and retry rules. Status: **draft** (2026-11).

Every SDK records three streams: **rendering** (the replay), **console logs**
and **network logs**. v1.2 makes the last two complete, gives developers
explicit APIs for them, and adds a **data mode** chosen in the SDK's init
options: masked or raw.

## 1. Onboarding and options

One call with the ingest key; everything else is optional.

```
web / React Native   ReplayIQ.init(key, { endpoint, dataMode, capture })
Flutter              ReplayIQ.init(key: …, endpoint: …, dataMode: …, capture: …)
iOS                  ReplayIQ.start(key: …, endpoint: …, options: …)   // options.dataMode, options.capture
Android              ReplayIQ.start(context, key, endpoint, ReplayIQOptions.Builder().dataMode(…).capture(…).build())
```

| Option | Values | Default |
|---|---|---|
| `dataMode` | `masked` / `raw` (see §4) | `masked` |
| `capture.replay` | record the screen (DOM / Native DOM / screenshots) | on |
| `capture.console` | automatic console/log capture | on |
| `capture.network` | automatic network capture | on |
| `capture.networkBodies` | capture request/response bodies | on |
| `network.maxBodyBytes` | body size limit per request/response, then truncated | 65536 |
| `network.ignoreUrls` | URL prefixes/patterns never recorded | the SDK's own endpoint routes |
| `network.redactHeaders` | extra header names to redact | `[]` |
| `network.maskBodyKeys` | extra JSON keys whose values are masked | `[]` |

## 2. Console logs

### Event

```json
{ "type": 5, "subtype": "console", "timestamp": 1795…,
  "level": "info",
  "message": "Checkout loaded",
  "args": [{"cart": 3, "total": 65}],
  "source": "CheckoutScreen.tsx:42",
  "logger": "payments",
  "stack": "…" }
```

| Field | |
|---|---|
| `level` | `debug`, `info`, `log`, `warn`, `error` (`trace` → `debug`). Uncaught errors stay `js_error`. |
| `message` | The line as text (arguments joined), ≤ 4000 chars. |
| `args` | Optional: the arguments as JSON values (objects serialized, depth ≤ 4, ≤ 8 KB total; cyclic/unserializable → string). |
| `source` | Optional: caller location (`file:line`) when the platform gives it. |
| `logger` | Optional: Android Logcat tag, iOS `os_log` subsystem/category, Dart `log(name:)`, a JS logger name. |
| `stack` | Optional: for errors / `trace`. |

### Automatic capture (`capture.console`)

| Platform | Captured |
|---|---|
| Web | every `console.debug/info/log/warn/error/trace` |
| Flutter | `print`, `debugPrint`, `dart:developer` `log()` (with name and level) |
| iOS | `print` / `NSLog` (the app's stdout/stderr, redirected and passed through), the app's own `os_log`/`Logger` entries (OSLogStore, own process) |
| Android | the app's own Logcat (its process only, all tags and levels) and `System.out`/`err` |
| React Native | every JS console level, plus the native capture above |

### Explicit API

```
ReplayIQ.log(message, level = "log", data?)     // data: object → args
ReplayIQ.logError(error, data?)                 // console level "error" with the error's stack
```

## 3. Network logs

### Event

```json
{ "type": 5, "subtype": "network", "timestamp": 1795…,
  "method": "POST", "url": "https://api.acme.com/pay?order=42",
  "status": 502, "duration": 1900, "error": "",
  "protocol": "h2", "cached": false, "initiator": "fetch",
  "request":  { "headers": {"content-type": "application/json", "authorization": "[redacted]"},
                "body": "{\"amount\":65,\"card\":\"[redacted]\"}", "size": 41, "truncated": false },
  "response": { "headers": {"content-type": "application/json"},
                "body": "{\"error\":\"gateway timeout\"}", "size": 27, "truncated": false,
                "content_type": "application/json" },
  "timing": { "dns": 2, "connect": 18, "tls": 31, "ttfb": 1820, "download": 4 } }
```

| Field | |
|---|---|
| `url` | Full URL including the query string (values masked per §4). |
| `request` / `response` | `headers` (lower-case names), `body` (text; see below), `size` (bytes on the wire or body length), `truncated`. |
| `body` | Text-like content only (`application/json`, `text/*`, `application/x-www-form-urlencoded`, `application/xml`, GraphQL). Binary and multipart → omitted, `size` kept. Cut at `network.maxBodyBytes` with `truncated: true`. |
| `timing` | ms, when the platform exposes them (Resource Timing on web, `URLSessionTaskMetrics` on iOS, OkHttp `EventListener` on Android); omitted otherwise. |
| `protocol`, `cached`, `initiator` | Optional: `http/1.1` / `h2` / `h3`; served from cache; `fetch` / `xhr` / `okhttp` / `urlsession` / `dio` / … |

The SDK never records its own requests to the ingest endpoint's `/api/v1/sessions`, `/events`, `/assets` routes.

### Automatic capture (`capture.network`)

| Platform | Captured |
|---|---|
| Web | `fetch`, `XMLHttpRequest` (bodies: request as sent; response cloned and read as text, never blocking the app) |
| Flutter | every dart:io request (HttpOverrides: package:http, Dio, `Image.network`) |
| iOS | URLSession (shared, default and ephemeral configurations), including upload tasks |
| Android | OkHttp (interceptor installed on clients the app builds via `ReplayIQ.okHttp(builder)`; React Native's client automatically) and `HttpURLConnection` where possible |
| React Native | the native capture (RN's networking is native) |

### Explicit API

```
web:      ReplayIQ.fetch(input, init)  // a recording fetch; plus ReplayIQ.recordNetwork({...})
Flutter:  ReplayIQ.httpClient(), ReplayIQ.dioInterceptor(), ReplayIQ.recordNetwork(...)
iOS:      ReplayIQ.urlSessionConfiguration(base) / ReplayIQURLProtocol, ReplayIQ.recordNetwork(...)
Android:  ReplayIQOkHttpInterceptor(), ReplayIQ.okHttp(builder), ReplayIQ.recordNetwork(...)
RN (JS):  ReplayIQ.recordNetwork({...})
```

`recordNetwork` takes the event's fields (method, url, status, duration,
request, response, timing, error); the SDK applies the same redaction.

## 4. Data mode: masked or raw

Each batch says which mode it was recorded in:

```json
{ "session_id": "…", "batch_id": "…", "data_mode": "raw", … }
```

(`device_masked: true` from v1 means `data_mode: "masked"`; SDKs send both
for compatibility.)

### Always masked on the device, in both modes (PCI DSS and secrets)

- Password / secure text fields: no value, no length.
- Values of the headers `authorization`, `proxy-authorization`, `cookie`,
  `set-cookie`, `x-api-key`, plus `network.redactHeaders` → `"[redacted]"`.
- Card numbers (13–19 digits passing Luhn, with spaces/dashes) and values of
  JSON / form / query keys named like `cvv`, `cvc`, `cvv2`, `card_number`,
  `cardnumber`, `pan`, `password`, `passwd`, `secret`, `token`, `access_token`,
  `refresh_token`, `api_key`, `apikey` (case-insensitive, `_`/`-` ignored),
  plus `network.maskBodyKeys` → `"[redacted]"`.

### `masked` (default)

Nothing else unmasked leaves the device:

- **Rendering**: as today: input values never sent; `mask` views and the
  SDK's masking rules applied on the device; screenshots painted over.
- **Console / network**: sent with the always-masked rules applied; the
  server additionally scrubs PII patterns (emails, phone numbers, …) in
  messages, URLs, headers and bodies before storing.
- **Stored**: one copy. The dashboard shows it; there is no unmasked view.

### `raw`

The SDK sends what it sees (except the always-masked list), plus what the
server needs to make a masked copy:

- **Native DOM**: `input` nodes carry their value in `in.v` (not for
  passwords); views that would be masked are sent with their content and
  `"masked": true` on the node; text that the masked rules would hide gets
  `"masked": true` too.
- **Screenshots**: the unmasked frame, plus `mask_rects: [[x, y, w, h], …]`
  (logical points) of what masked mode would have painted over.
- **Web**: rrweb with input masking off (`maskAllInputs: false`), password
  fields still masked; elements that masked mode blocks are recorded with a
  `data-riq-masked` attribute (rrweb `blockClass` off).
- **Console / network**: as captured, with only the always-masked rules.

The server stores **two copies**: raw (as sent) and masked (built by the
server: masked nodes become `mask` blocks, `in.v` removed, text and
attributes PII-scrubbed, screenshot `mask_rects` painted over, console and
network text, headers and bodies scrubbed). The dashboard shows the masked
copy by default with a **Masked / Unmasked** switch.

Compliance notes: raw mode should be used only where the customer's policy
allows it; every view of unmasked data will be audit-logged once dashboard
login exists; the always-masked list cannot be turned off.
