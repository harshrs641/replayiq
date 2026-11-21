---
name: debug-replay
description: Investigate why a recorded ReplayIQ session replays wrong (missing or misdrawn UI, text boxes, wrong screen, lag, gaps). Use when the user gives a session id or says a replay is inaccurate. Covers pulling the session from Postgres and the query API, counting events, rendering it in the dashboard, and tracing a problem back to the SDK or the transform.
---

# Debugging a replay

Start with `./dev.sh status`. If services are down, run `./dev.sh up`.

## 1. Find the session

```bash
P="postgres://replayiq:replayiq_secret@localhost:5432/replayiq?sslmode=disable"
psql "$P" -x -c "select * from sessions where id = '<id>'"
```

The row gives the platform, SDK and version, duration, and device. The SDK
tells you which `sdk/<name>` skill applies. React Native sessions run on the
iOS or Android native SDK.

Session ids of the manual test runs are kept in `testing/<platform>/session_id.txt`.

## 2. Pull what was stored (query service, :8082 or via gateway :8080)

| Endpoint | Returns |
|---|---|
| `GET /api/v1/sessions/<id>` | Session row |
| `GET /api/v1/sessions/<id>/replay` | `{session_id, masked, device_masked, batches:[{batch_id, platform, sdk, events:[…]}]}`. Each batch's events are **already rrweb** (types 2 FullSnapshot, 3 incremental, 4 Meta) plus type-5 custom events (`click`, `navigate`, `console`, `jank`, …) |
| `GET …/replay/manifest` | start, end, duration, event count, bytes, keyframe timestamps |
| `GET …/replay/events?at=<ms>&to=<ms>` | A self-contained chunk starting at the keyframe before `at` |
| `GET …/replay/activity` | Only navigation and custom events |

All endpoints take `masked=false` to read the raw copy instead of the
PII-masked one.

Save the JSON to the scratchpad and analyse it with Python. Don't print it
whole. Start by counting events per type:

```bash
curl -s localhost:8082/api/v1/sessions/<id>/replay -o /path/to/scratchpad/s.json
python3 -I - /path/to/scratchpad/s.json <<'EOF'
import json,sys,collections
d=json.load(open(sys.argv[1])); c=collections.Counter()
for b in d["batches"]:
  for e in b["events"]: c[(e.get("type"), e.get("subtype") or (e.get("data") or {}).get("source"))]+=1
print(c.most_common(20))
EOF
```

What to look for:
- **Gaps in timestamps** between events: the app froze, or the SDK stopped walking.
- **`hang`, `jank`, `screen_load` durations**: lag the user felt.
- **`console` flood** (tens of thousands of events): XCTest or the system
  logging into stdout. The iOS SDK caps this at 50 lines a second.
- **Many FullSnapshots (type 2)**: screen changes, size changes, or the
  30 s keyframe rule.

## 3. Look at the rendered replay, not just the snapshots

**Lesson learned:** text inside FullSnapshots alone is misleading. The
screen is often updated by the mutations (type 3, source 0) between
snapshots. A "wrong screen" in a snapshot can be correct once mutations
apply. Always confirm in the player before calling something a bug.

- Open `http://localhost:3000`, select the session, and seek. In dev builds,
  `window.__replayStreamer` is the streamer and `player.goto(ms)` seeks.
- Use the built-in browser and take a screenshot at the timestamp in question.

## 4. Decide where the bug is

| Symptom | Likely place |
|---|---|
| Node missing or wrong in the stored rrweb, but SDK sent it right | `backend/internal/transform/nativedom.go` |
| SDK never sent the node or style | The SDK's walker (`DomWalker.swift`, `ViewWalker.kt`/`ComposeDom.kt`, `walker.dart`) |
| Inputs look unlike the app | SDK `input` node fields (`tx`, `pc`, `pad`, `filled`, `len`) and `inputDisplay`/`inputCSS` in the transform |
| Replay right, but the app lagged | SDK main-thread cost: check `Diagnostics` / `Stats` walk times. 1 to 4 ms per walk is normal. Long freezes on the first keyboard appearance are iOS, not the SDK |
| Every upload slow | Ingest → Kafka publish latency (`kafka.go` `BatchTimeout`) |

## 5. Verify a fix

Transform runs in the processor **before storage**, so existing sessions
don't change. To verify a fix:

1. Restart the services.
2. Record a new session with the example app for that SDK (ingest key `verify`).
3. Check the new session the same way.

If the simulator app keeps sending into an old session, it is draining its
disk queue. Uninstall the app to get a fresh session:

```bash
xcrun simctl uninstall booted io.replayiq.example
```
