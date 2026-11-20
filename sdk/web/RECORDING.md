# How the web SDK records, and how a recording replays

This explains what `@replayiq/web` captures in the browser, what it sends,
and how ReplayIQ turns it back into a replay. For setup see [README](README.md);
the wire format is [Recording API v1](../../docs/sdk/recording-api-v1.md).

## 1. What is captured, and from where

| What | Captured by | Becomes |
|---|---|---|
| The page itself: every element, its attributes, text and CSS | [rrweb](https://github.com/rrweb-io/rrweb) `record()`: a serialized snapshot of the DOM (`FullSnapshot`, type 2), then each change from a `MutationObserver` (`IncrementalSnapshot`, type 3, source 0) | The replayed page |
| Page size and URL | rrweb `Meta` event (type 4): `href`, `width`, `height` | Replay viewport; a navigation row |
| Mouse moves, clicks, focus/blur, touches | rrweb incremental events (sources 1 and 2) | Cursor and click ripples in the replay |
| Scrolling (page and inner elements) | rrweb scroll events (source 3) | Scroll positions in the replay |
| Window resize | rrweb viewport events (source 4) | Replay viewport changes |
| Typing | rrweb input events (source 5); **values of password/email/card/CVV/SSN/phone fields and `data-riq-mask` elements are masked in the browser** | Masked field contents in the replay |
| Fonts | rrweb `collectFonts` | Correct fonts in the replay |
| Clicks with a readable name | SDK `click` listener → `{subtype: "click", selector: "button#pay.primary"}` | Behaviour tab, AI analysis |
| Rage clicks | 3+ clicks on the same element within 700 ms → `rage_click` | Behaviour tab, timeline marker |
| Edited fields | SDK `input` listener → `{subtype: "input", selector}` (never the value) | Behaviour tab |
| Single-page-app navigation | `history.pushState` / `replaceState` / `popstate` / `hashchange` → `navigate` | Behaviour tab |
| `fetch` and `XMLHttpRequest` | Wrapped → `network` with method, full URL, status, duration, error, request and response headers and text bodies (response read from a clone in the background), size, protocol, cache hit and DNS/connect/TLS/TTFB/download timing (Resource Timing) | Network tab with a detail panel and Copy as cURL; timeline marker for failures |
| `console.debug/info/log/warn/error/trace` | Wrapped → `console` with `level`, `message`, structured `args` (depth ≤ 4, ≤ 8 KB) and the stack of an `Error` argument or `trace` | Console tab with level filters |
| `ReplayIQ.log` / `logError` / `fetch` / `recordNetwork` | Your code → the same `console` / `network` events | Console / Network tabs |
| Uncaught errors and promise rejections | `window` `error` / `unhandledrejection` → `js_error` with file, line, column, stack | Console tab, timeline marker, AI analysis |
| Your own events | `ReplayIQ.track(name, props)` → `custom_events` | Stored with the batch |

Recording only starts after the page has loaded and the browser is idle
(rrweb is loaded then); network, console and error capture start at once.
It pauses in a tab hidden for 60 s or idle for 10 min, and resumes with a
fresh snapshot.

## 2. What is sent

Every 5 s (or at 50 events, or when the tab hides) a gzipped batch:

```json
POST /api/v1/events
Authorization: Bearer <ingest key>
{
  "session_id": "8f0c…", "batch_id": "8f0c…-000017-k3x9", "platform": "web",
  "sdk": "replayiq-web/1.2.0", "data_mode": "masked",
  "events": [
    {"type": 4, "timestamp": 1795…000, "data": {"href": "https://shop.example.com/checkout", "width": 1440, "height": 900}},
    {"type": 2, "timestamp": 1795…001, "data": {"node": { …serialized DOM… }, "initialOffset": {"top": 0, "left": 0}}},
    {"type": 3, "timestamp": 1795…420, "data": {"source": 0, "adds": […], "removes": […], "attributes": […], "texts": […]}},
    {"type": 5, "subtype": "click", "selector": "button#pay.primary", "timestamp": 1795…900},
    {"type": 5, "subtype": "network", "method": "POST", "url": "https://api…/pay?order=42", "status": 502, "duration": 1900,
     "request": {"headers": {"authorization": "[redacted]"}, "body": "{\"amount\":65,\"card\":\"[redacted]\"}"},
     "response": {"headers": {"content-type": "application/json"}, "body": "{\"error\":\"gateway timeout\"}"},
     "timing": {"dns": 2, "connect": 18, "tls": 31, "ttfb": 1820, "download": 4}, "timestamp": …},
    {"type": 5, "subtype": "console", "level": "info", "message": "checkout loaded {\"cart\":3}", "args": [{"cart": 3}], "timestamp": …}
  ]
}
```

rrweb takes a new keyframe (Meta + FullSnapshot) at least every 30 s of
activity or every 200 events, so seeking never replays more than that.

## 3. What the server does

1. **Ingest** checks the key, accepts the batch and publishes it to Kafka.
2. **Transformer**: web batches are rrweb already, so they pass through.
   The always-redacted rules (secret headers, card numbers, sensitive keys)
   are applied again to every copy. Then, by `data_mode`:
   - `masked`: one copy, masked again on the server (PII patterns such as
     emails in text, attributes, console and network). The dashboard shows a
     "Masked at source" badge; there is no unmasked view.
   - `raw`: two copies. **raw**, as recorded; **masked**, built on the
     server: input values, `riq-mask` / `data-riq-masked` elements, and PII
     patterns in text, attributes, console lines, URLs, headers and bodies
     redacted. Replays show the masked copy by default, with a Masked /
     Unmasked switch.
3. **Storage** writes each batch to object storage under its `batch_id`
   (gzipped), with its time range and keyframe times as metadata, which is
   what makes seeking cheap.

## 4. How it renders on replay

The dashboard player is [rrweb-player](https://github.com/rrweb-io/rrweb):

- It rebuilds the page from the nearest FullSnapshot inside a sandboxed
  iframe, in the viewer's browser, then applies the recorded mutations,
  scrolls, inputs and mouse moves in time order. It is the same page, so the
  replay is pixel-faithful (fonts, layout and CSS all come from the page).
- It streams: it loads the first chunk, keeps ~15 s ahead of the playhead,
  and a jump fetches from the keyframe before the target (`events?at=`).
- Clicks, rage clicks, failed requests and errors appear as markers on the
  timeline; the `click`/`network`/`console`/`js_error` events fill the
  Behaviour, Console and Network tabs, and clicking a row seeks there.
- Sessions still recording play live (server-sent events push new batches).

## 5. Not captured

- Canvas and WebGL content (`recordCanvas` is off), video frames, cross-origin
  iframes' content.
- Binary, multipart and stream bodies (only their size); `FormData` and
  `Blob` request bodies; field values of masked fields; anything on the
  always-redacted list.
- The SDK's own requests to the ReplayIQ host.
