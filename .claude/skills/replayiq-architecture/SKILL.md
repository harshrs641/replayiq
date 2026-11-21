---
name: replayiq-architecture
description: Map of the ReplayIQ repo (Go backend services, Kafka pipeline, rrweb transform, storage, dashboard, SDK folders, wire-format specs) plus the local dev loop. Use before changing or explaining anything in backend/, dashboard/, docs/sdk/ or dev.sh, or when you need to know where a piece of behaviour lives without re-reading the code.
---

# ReplayIQ architecture

ReplayIQ is session replay as a SaaS. SDKs record apps, the backend turns
what they send into **rrweb** events, and the dashboard plays them with
rrweb-player. Every platform ends up as rrweb, so the player is the same for
web and mobile.

```
SDK ──POST gzip JSON──▶ gateway :8080 ──▶ ingest :8081 ──Kafka (Redpanda)──▶ processor ──▶ MinIO + Postgres
                                     └──▶ query :8082 (read API) ◀── dashboard :3000
```

## Services (backend/cmd)

| Binary | What it does |
|---|---|
| `gateway` | Reverse proxy on :8080. Write paths go to ingest, reads go to query. SDKs and the dashboard only talk to :8080 |
| `ingest` | `POST /api/v1/sessions`, `/sessions/{id}/end`, `/events`, `/assets`. Checks the key, checks `device_masked`, publishes unchanged to Kafka. Rate limit per project (`api/ratelimit.go`) |
| `processor` | Kafka consumers. **Transform runs here, at ingest time**: SDK events become rrweb before storage. Writes a raw copy (`sessions` bucket) and a PII-masked copy (`sessions-masked`), the replay index, and session rows. Also queues AI analysis |
| `query` | Read API: sessions, search, `/sessions/{id}/replay` (full), `/replay/{part}` (streamed chunks), `/replay/live` (SSE), moments, issues, Jira, assets |
| `server` | Legacy all-in-one binary |
| `backfill-index`, `backfill-mask` | One-off maintenance jobs |

Because transform happens before storage, **a transform fix only affects
sessions recorded after the processor restarts**. Old sessions keep their
old rendering.

## backend/internal

| Package | Look here for |
|---|---|
| `transform/transform.go` | Entry: routes each SDK event to the right converter |
| `transform/nativedom.go` | Native DOM (`ui_snapshot`/`ui_mutation`, API v1.1) → rrweb FullSnapshot + mutations. Node styling, text, inputs (`inputDisplay`, `inputCSS`), masks, islands |
| `transform/screens.go`, `screens_mask.go` | Screenshot mode (`screen` events) and touches → rrweb |
| `ingest/processor.go`, `split.go` | Batch → Kafka messages, split under the broker size limit |
| `kafka/kafka.go` | Producer/consumer over segmentio/kafka-go. Writer uses `BatchTimeout: 10ms`. The 1 s default made every ingest request wait 1 s |
| `masking/always.go` | Always-masked rules (API v1.2 §4): secret headers, Luhn card numbers, sensitive keys. Mirrors each SDK's `Redactor` |
| `masking/masking.go` | PII scrub of the masked copy |
| `models/event_extra.go` | Custom event (type 5) fields that rrweb doesn't name |
| `storage/storage.go` | Postgres (`sessions`, `ai_issues`) + MinIO client |
| `storage/replay_index.go` | Streaming replay: time ranges, keyframes, chunk lookup. Objects at `sessions/<id>/…` |
| `api/*` | HTTP handlers. `router.go` lists every route. `replay_stream.go` serves chunks, `replay_live.go` serves SSE |
| `ai/`, `pipeline/` | Ollama analysis (frustrations, issues), moments on the timeline, retention |

## Wire formats (read these instead of SDK code for payload questions)

- `docs/sdk/recording-api-v1.md`: sessions, batches, `batch_id`, retries, the core custom events.
- `docs/sdk/recording-api-v1.1-native-dom.md`: Native DOM nodes (`view`, `text`, `image`, `input`, `island`, `scroll`, `mask`), styles, assets, mobile signals. Input nodes take `tx`, `pc`, `pad`, `filled`, `len`, and never the value.
- `docs/sdk/recording-api-v1.2-data-mode.md`: masked vs raw data mode, console, network, always-masked rules.
- Each SDK has a `RECORDING.md` (capture → payload → server → replay) and a README (setup).

When you change the wire format, update the spec, the backend transform, its
tests, and every SDK that sends the field.

## Dashboard (dashboard/src/App.jsx, single file)

- `API = http://localhost:8080`.
- `ReplayStreamer` (~line 271) fetches replay chunks. In dev builds it is
  exposed as `window.__replayStreamer`, and `player.goto(ms)` seeks.
- `SessionReplay`, `ActivityPanel`, `NetworkDetail`, `SessionDetail`, `IssuesPanel`.
- Deep link: `sessionLink(id, offsetSec)`.

## SDKs (each has its own skill under `sdk/<name>/.claude/skills/`)

| Folder | Platform | Notes |
|---|---|---|
| `sdk/ios` | Swift package (UIKit, SwiftUI) | Also the engine under React Native on iOS |
| `sdk/android` | Kotlin library (Views, Compose) | Also the engine under React Native on Android |
| `sdk/flutter` | Dart package | Own walker over Flutter's render tree |
| `sdk/react-native` | TS bridge over the iOS and Android SDKs | JS errors, console, screen names |
| `sdk/web` | Browser JS (rrweb based) | Already sends rrweb |
| `sdk/replayiq.js`, `sdk/rrweb.min.js` | Built web bundle served at `/sdk/` | |

The mobile SDKs share the same design (session store → recorder → disk queue
→ uploader; DOM walker → differ → assets). A fix in one usually needs porting
to the other two. Check all three.

## Dev loop

```bash
./dev.sh up        # Postgres (native), MinIO, Ollama, Redpanda, 4 Go services, dashboard
./dev.sh status
./dev.sh logs processor
./dev.sh build     # rebuild Go binaries only
./dev.sh down
```

- After editing Go code: `./dev.sh down && ./dev.sh up`. If `status` still
  shows an old PID for a service, run `./dev.sh up` again.
- Tests: `cd backend && go test ./...`. Transform only: `go test ./internal/transform/`.
- Postgres: `postgres://replayiq:replayiq_secret@localhost:5432/replayiq?sslmode=disable`.
- Example apps record with ingest key `verify` to `localhost:8080`.

For investigating a specific recording, use the `debug-replay` skill.
