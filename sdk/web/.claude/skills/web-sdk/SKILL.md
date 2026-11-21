---
name: web-sdk
description: Map of the ReplayIQ web SDK (@replayiq/web in sdk/web) - rrweb-based browser recorder, console/network capture, redaction, the esbuild outputs and the copy served at /sdk/replayiq.js, plus the Safari extension. Use before reading or changing anything in sdk/web, sdk/replayiq.js or safari-extension.
---

# ReplayIQ web SDK

Browser recorder built on **rrweb**. It sends rrweb events directly, so the
backend transform mostly passes them through. Native DOM conversion is for
mobile only.

- What is captured: `sdk/web/RECORDING.md`
- Setup: `sdk/web/README.md`
- Wire formats: `docs/sdk/recording-api-v1.md`, `docs/sdk/recording-api-v1.2-data-mode.md`

## Files

| File | Role |
|---|---|
| `src/index.js` | The SDK. A recorder class (session, batching, rrweb `record`, flush on `beforeunload`, opt-out) and a `ReplayIQ` facade with `init(keyOrConfig, options)`, `identify`, `track`, `log`, `logError`, `recordNetwork`, `fetch`, `stop`, `getSessionId`, `optOut`/`optIn`/`isOptedOut` |
| `src/capture.js` | Console + fetch/XHR capture (API v1.2 §2–3), Resource Timing for timing/protocol/cache |
| `src/redact.js` | Always-masked rules. Must match `backend/internal/masking/always.go` and the mobile `Redactor`s |
| `index.d.ts` | Public types. Update with any API change |
| `build.mjs` | esbuild outputs: `dist/index.mjs` (ESM), `dist/index.cjs` (CJS), and `dist/replayiq.js` / `replayiq.min.js` (IIFE, global `__riq`, rrweb external, es2019) |

## Build

```bash
cd sdk/web && npm install && npm run build
cp dist/replayiq.js ../replayiq.js      # the copy the query service serves at /sdk/replayiq.js
```

`sdk/replayiq.js` must stay identical to `sdk/web/dist/replayiq.js`.
`sdk/rrweb.min.js` is the rrweb build it loads.

## Related

- `safari-extension/` (repo root) is a content-script recorder (`content.js`,
  `init.js`, `background.js`, its own `rrweb.min.js`) for recording arbitrary sites.
- The dashboard player (`dashboard/src/App.jsx`) uses `rrweb-player`. rrweb
  version mismatches between recorder and player show up as broken replays.
