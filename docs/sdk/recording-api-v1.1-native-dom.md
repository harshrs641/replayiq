# ReplayIQ Recording API v1.1: Native DOM and mobile signals

Additions to [Recording API v1](recording-api-v1.md). Same endpoints, same
envelope, same auth, gzip, `batch_id` and retry rules; v1 SDKs keep working.
Status: **draft**. Server side implemented (`backend/internal/transform`, `internal/ingest`, `/api/v1/assets`). Flutter prototype measured on the iPhone simulator (debug build, same scripted minute): 43 KB/min vs 1.45 MB/min for screenshots (34x less), tree walk 0.49 ms p50 / 1.28 ms p95 (2026-11).

## Why

v1 records mobile screens as screenshots: exact, but heavy (10–40 KB per
frame), choppy (≤2 fps), and opaque to search and the AI. v1.1 records the
app's UI the way rrweb records a web page: as a tree of nodes plus small
changes, which the server turns into rrweb events. Views that can't be
described (maps, video, custom drawing) are sent as small bitmaps ("raster
islands"). Screenshots (`screen` events) remain the fallback.

A recording mode is chosen per screen by the SDK. A session may mix modes:
the server inserts a keyframe whenever the mode changes.

## 1. Native DOM

### Node

```json
{
  "id": 42,
  "k": "view",
  "f": [16, 120, 361, 56],
  "s": {
    "bg": "#FF1F2937",
    "r": [12, 12, 12, 12],
    "bw": 1, "bc": "#FFE5E7EB",
    "sh": [0, 2, 8, 0, "#33000000"],
    "o": 1,
    "t": [1, 0, 0, 1, 0, 0],
    "clip": true,
    "grad": { "type": "linear", "angle": 90, "stops": [["#FFFF0000", 0], ["#FF0000FF", 1]] }
  },
  "role": "button",
  "label": "Pay now",
  "c": [ ...children, painted back to front... ]
}
```

| Field | Meaning |
|---|---|
| `id` | Integer ≥ 1, **stable for the node's lifetime**, never reused within a session. |
| `k` | Kind: `view`, `text`, `image`, `input`, `island`, `scroll`, `web`, `mask`. |
| `f` | Frame `[x, y, w, h]` in logical points/dp, **relative to the inside of the parent's border** (its padding box: a parent with a 2 pt border puts a child at `[0, 0]` 2 pt in from its outer edge). For `scroll` children: relative to the scroll content, see `so`. |
| `s` | Style; every field optional. Colours are `#AARRGGBB`. `r` corner radii `[tl, tr, br, bl]`; `bw`/`bc` border width/colour; `sh` shadow `[dx, dy, blur, spread, colour]`; `o` opacity 0–1; `t` 2D affine transform `[a, b, c, d, tx, ty]` about the node's centre; `clip` clips children; `grad` linear/radial gradient. |
| `role`, `label` | Optional accessibility role and label, used for tap selectors and the AI. Never the value of an input. |
| `c` | Children, back to front. |

Kind-specific fields:

| Kind | Fields |
|---|---|
| `text` | `"approx": true` marks text rebuilt from accessibility data (e.g. SwiftUI text that iOS draws into bitmaps): its font and exact position are estimates. Cheaper than an `island`, and searchable. `tx`: `{ "v": "Total $65.00", "font": "Inter", "size": 17, "w": 600, "i": false, "col": "#FF111827", "al": "left", "lh": 22, "ml": 2 }` (value, family, size, weight 100–900, italic, colour, align, line height, max lines). Rich text: `"spans": [{"v": "...", ...style overrides}]` instead of `v` (prototype server: spans are joined and drawn in the first span's style). |
| `image` | `img`: `{ "a": "<sha256 hex>", "fit": "cover" }` (`cover`, `contain`, `fill`, `none`). The bitmap is uploaded once as an asset (§3). |
| `island` | Same as `image`; marks a view captured as pixels because it can't be described (map, video, chart canvas, custom painter, Lottie). When the platform can't capture its pixels (e.g. Flutter platform views), omit `img` and set `hint` (`map`, `video`, `camera`, `web`, `unknown`): it replays as an empty labelled box. |
| `input` | `in`: `{ "type": "text", "ph": "Card number", "len": 16, "focus": true }`. **The value is never sent**; `ph` and `len` are optional (Flutter draws hints and labels as separate `text` nodes). |
| `scroll` | `so`: `[x, y]` content offset; children are laid out in content coordinates (their frames don't change while scrolling; only the scroll node's `so` does). |
| `web` | A WebView. Its content is recorded by rrweb inside the page (§5); the node is a placeholder. |
| `mask` | A masked region: rendered as a solid block. The SDK sends no children, text or image for it. |

### Events

All are Custom events (`type: 5`) in `events`, like v1.

**`ui_snapshot`**: the whole screen. Sent on the first frame, when the
screen (route) changes, on orientation/size change, when switching from
screenshot mode, and at least every 30 s of activity.

```json
{ "type": 5, "subtype": "ui_snapshot", "timestamp": 1795000000000,
  "width": 393, "height": 852, "density": 3, "bg": "#FFFFFFFF",
  "fonts": [{ "family": "Inter", "w": 600, "a": "<sha256>" }],
  "root": { ...node } }
```

**`ui_mutation`**: changes since the previous snapshot or mutation.

```json
{ "type": 5, "subtype": "ui_mutation", "timestamp": 1795000000420,
  "adds":    [{ "p": 7, "next": 9, "n": { ...node with children } }],
  "removes": [{ "p": 7, "id": 8 }],
  "updates": [{ "id": 42, "f": [16, 120, 361, 56], "s": { ... }, "tx": { ... } }] }
```

- `adds`: insert node `n` under parent `p`, before sibling `next` (omit
  `next` to append).
- `removes`: remove node `id` (and its subtree) from parent `p`.
- `updates`: node `id`'s **complete own fields**, everything except its
  children: `k`, `f`, `s`, and `tx` / `img` / `in` / `so` as applicable
  (send the whole node minus `c`). Its children are untouched. The server
  converts each batch on its own, without remembering earlier ones, so an
  update must describe the node fully.
- Coalesce changes: at most one `ui_mutation` per 33 ms (30/s). Animations
  are just `updates` of `f`/`s.o`/`s.t` on the moving nodes, sampled while
  they run.

### Masking (required)

- Text inputs never carry their value; secure inputs are `input` nodes with
  `"type": "password"`.
- Views marked sensitive by the app become `mask` nodes. Their children,
  text and images are never serialized or uploaded.
- Batches still set `device_masked: true`.

### Recording guidance

- Walk the tree only when the platform reports a redraw; do nothing while
  the screen is static. Budget: ≤ 2 ms per walk on the main thread,
  diffing/serialising/compressing off it.
- Fall back to `screen` events (v1) for a screen when most of its area is
  islands (games, camera); switch back when that screen goes away.

## 2. Mobile signals

Custom events (`type: 5`), alongside v1's `navigate`, `click`, `rage_click`,
`input`, `console`, `js_error`, `network`:

| `subtype` | Fields | When |
|---|---|---|
| `gesture` | `kind` (`tap`, `double_tap`, `long_press`, `swipe`, `pinch`, `pan`), `selector`, `x`, `y`, `dx`, `dy`, `scale` | Recognised gestures (taps also keep `click`). |
| `focus` / `blur` | `selector` | A field gains/loses focus. |
| `scroll` | `selector`, `x`, `y` | Scroll settled (also visible as `so` updates). |
| `lifecycle` | `state` (`foreground`, `background`, `terminate`), `cold` (bool) | App state changes. |
| `app_start` | `kind` (`cold`, `warm`), `duration` (ms) | First frame after launch. |
| `screen_load` | `screen`, `duration` (ms) | Route pushed → first frame of its content. |
| `jank` | `screen`, `dropped`, `frozen`, `worst` (ms), `window` (ms), `budget` (ms) | Every 5 s that had dropped or frozen (>700 ms) frames. A frame is dropped when it takes longer than `budget`, the display's frame time (16.7 ms at 60 Hz, 8.3 ms at 120 Hz). |
| `hang` | `duration` (ms), `stack` | Main thread blocked ≥ 2 s (ANR on Android). |
| `memory` | `level` (`warning`, `critical`), `used` (MB) | OS memory warnings. |
| `keyboard` | `visible` (bool), `height` | Software keyboard shown/hidden. |
| `orientation` | `value` (`portrait`, `landscape`) | Rotation. |
| `connectivity` | `network` (`wifi`, `cellular`, `none`), `quality` | Network changes / offline. (Never a field named `type`: that is the event's own type.) |
| `deeplink` | `url` | App opened from a link. |
| `push_open` | `campaign` | App opened from a notification (no message text). |
| `permission` | `name`, `result` (`granted`, `denied`, `limited`) | Permission prompts answered. |
| `thermal` / `power` | `state` / `low_power` (bool) | Thermal state, low-power mode changes. |

Session `metadata` (v1 §1) should add `device`, `os_version`, `app_version`,
`locale`, `text_scale` and `screen_density`.

## 3. Assets: `POST /api/v1/assets`

Images, islands and fonts are uploaded once and referenced by hash.

```
POST /api/v1/assets
Authorization: Bearer <ingest key>
Content-Type: image/webp | image/jpeg | image/png | font/ttf | font/otf
X-Asset-Hash: <sha256 hex of the body>
<raw bytes, ≤ 2 MB>
```

- `201` stored, `200` already stored (the SDK may skip uploads it knows
  about: `HEAD /api/v1/assets/<hash>` returns `200` or `404`).
- `400` if the hash doesn't match the body.
- Assets are per project (by key) and kept as long as any session that
  references them.
- Upload an asset **before** the batch that references it. A batch whose
  asset is missing still replays, with an empty box until the asset arrives.
- Masked views are never uploaded. User-content images (avatars, photos)
  should be masked or downscaled by app policy; the SDK default is to
  upload images at ≤ 1x scale.

Islands change: upload each changed island frame as a new asset (≤ 5/s per
island) and `update` the node's `img.a`.

## 4. Server behaviour

The ingest API stores batches as received (the native copy) and a
transformer stage converts them for replay:

- `ui_snapshot` → rrweb Meta + FullSnapshot of an HTML page in which every
  node is an absolutely positioned element with its styles; `text` →
  styled text, `image`/`island` → `<img>` of the asset URL, `mask` → solid
  block, fonts → `@font-face`.
- `ui_mutation` → one rrweb mutation event (adds, removes, attributes,
  texts).
- `screen`/`touch` (v1) → as before.
- Signals and app events pass through to the Behaviour/Console/Network tabs
  and the AI.

Implementation notes:
- `image` and `island` nodes always replay as `<img>`; until their asset
  is uploaded they show a transparent placeholder (islands: a grey box), and
  an update carrying the hash fills them in. No need to re-add the node.
- Events that don't fit the schema are dropped one by one; the rest of the
  batch is kept and the response says `"dropped": n`.
- Batches larger than a Kafka message are split by the server (parts keep
  the batch id with a `.pN` suffix), so the v1 5 MB body limit stands.
- Text is not clipped to its frame (the viewer may substitute a slightly
  wider font, e.g. for Apple's system font), and a frame one line tall
  stays on one line.
- v1 `touch` events work in Native DOM sessions too: they land on the
  screen container.
- rrweb ids are derived from node ids (`1000 + 4·id`, text child `+1`), so
  node ids must be unique and stable within a session.
- UI text and labels pass through the same PII redaction as console text.
- Assets are served to the player at
  `GET /api/v1/assets/<project>/<hash>` (immutable, cached for a year),
  addressed by `PUBLIC_API_URL`. Like the rest of the read API this is not
  yet authenticated.

## 5. WebViews

Mobile SDKs should inject the ReplayIQ web SDK into WebViews they own (or
offer a helper to do so) with the same `session_id`, so web content inside
the app is recorded as real rrweb and stitched into the same session.
(Prototype: not yet.)
