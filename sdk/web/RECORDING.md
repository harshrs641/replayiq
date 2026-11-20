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
| `fetch` and `XMLHttpRequest` | Wrapped → `network` with method, URL, status, duration, error | Network tab, timeline marker for failures |
| `console.warn` / `console.error` | Wrapped → `console` (with the stack of an `Error` argument) | Console tab |
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
  "sdk": "replayiq-web/1.1.0",
  "events": [
    {"type": 4, "timestamp": 1795…000, "data": {"href": "https://shop.example.com/checkout", "width": 1440, "height": 900}},
    {"type": 2, "timestamp": 1795…001, "data": {"node": { …serialized DOM… }, "initialOffset": {"top": 0, "left": 0}}},
    {"type": 3, "timestamp": 1795…420, "data": {"source": 0, "adds": […], "removes": […], "attributes": […], "texts": […]}},
    {"type": 5, "subtype": "click", "selector": "button#pay.primary", "timestamp": 1795…900},
    {"type": 5, "subtype": "network", "method": "POST", "url": "https://api…/pay", "status": 502, "duration": 1900, "timestamp": …}
  ]
}
```

rrweb takes a new keyframe (Meta + FullSnapshot) at least every 30 s of
activity or every 200 events, so seeking never replays more than that.

## 3. What the server does

1. **Ingest** checks the key, accepts the batch and publishes it to Kafka.
2. **Transformer**: web batches are rrweb already, so they pass through
   unchanged. Two copies are kept:
   - **raw**, exactly as recorded;
   - **masked**: input values, text inside `riq-mask` elements and PII
     patterns (emails, card numbers…) in text and attributes redacted on the
     server too. Replays show this copy by default.
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
- Request/response headers and bodies; field values of masked fields.
- The SDK's own requests to the ReplayIQ host.
