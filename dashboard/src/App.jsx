import { useState, useEffect, useRef, useCallback, useMemo } from "react";
import RRWebPlayer from "rrweb-player";
import "rrweb-player/dist/style.css";

const API = "http://localhost:8080";
const PROJECT_ID = "demo";

// ── Palette ──────────────────────────────────────────────────────────────────
// Monochrome light theme: grayscale everywhere, with near-black ("ink") as
// the single reserved accent for emphasis (primary actions, active states,
// the most severe end of any scale). Severity/status is conveyed via shade
// and weight, not hue.
const C = {
  bg: "#ffffff",
  bgSubtle: "#fafafa",
  bgHover: "#f4f4f5",
  border: "#e4e4e7",
  borderStrong: "#d4d4d8",
  text: "#18181b",
  textMuted: "#71717a",
  textFaint: "#a1a1aa",
  ink: "#18181b",
};

// ── Helpers ──────────────────────────────────────────────────────────────────

function ago(dateStr) {
  if (!dateStr) return "—";
  const diff = Date.now() - new Date(dateStr).getTime();
  const s = Math.floor(diff / 1000);
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

function dur(ms) {
  if (!ms) return "—";
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60000)}m ${Math.floor((ms % 60000) / 1000)}s`;
}

// Strips protocol and query string so a long URL like
// "https://app.example.com/checkout?step=3&ref=email" becomes
// "app.example.com/checkout" — compact enough for the session list row.
// The full URL is always preserved as a title tooltip.
function shortUrl(url) {
  if (!url) return "—";
  try {
    const { host, pathname } = new URL(url);
    return host + (pathname === "/" ? "" : pathname);
  } catch {
    return url;
  }
}

function severityStyle(sev) {
  switch (sev) {
    case "P0": return { background: C.ink, color: "#fff", borderColor: C.ink };
    case "P1": return { background: "#52525b", color: "#fff", borderColor: "#52525b" };
    case "P2": return { background: "#f4f4f5", color: C.text, borderColor: C.borderStrong };
    default:   return { background: "#fff", color: C.textMuted, borderColor: C.border };
  }
}

function typeLabel(type) {
  return { bug: "BUG", ux: "UX", error: "ERR" }[type] || "ISSUE";
}

// ── Tag Pill ─────────────────────────────────────────────────────────────────

function Tag({ label }) {
  return (
    <span style={{
      display: "inline-block", padding: "2px 8px", borderRadius: 4,
      fontSize: 11, fontWeight: 600, letterSpacing: "0.02em",
      background: C.bgHover, color: C.textMuted, border: `1px solid ${C.border}`,
    }}>
      {label}
    </span>
  );
}

// ── AI Pipeline Status ───────────────────────────────────────────────────────

const PIPELINE_STAGES = [
  { key: "queued", label: "Queued" },
  { key: "analyzing", label: "Analyzing" },
  { key: "embedding", label: "Embedding" },
  { key: "complete", label: "Done" },
];

function AIPipelineStatus({ status, error, compact }) {
  if (!status || status === "pending") {
    return compact ? null : <div style={{ fontSize: 12, color: C.textMuted }}>Not analyzed yet.</div>;
  }

  if (status === "failed") {
    return (
      <div>
        <span style={{ fontSize: compact ? 11 : 12, fontWeight: 700, color: C.text }}>✕ Analysis failed</span>
        {!compact && error && <div style={{ marginTop: 4, fontSize: 11, color: C.textMuted }}>{error}</div>}
      </div>
    );
  }

  const idx = PIPELINE_STAGES.findIndex(s => s.key === status);

  if (compact) {
    const label = PIPELINE_STAGES[idx]?.label || status;
    return (
      <span style={{ fontSize: 11, color: C.textMuted, display: "inline-flex", alignItems: "center", gap: 6 }}>
        <span style={{
          width: 6, height: 6, borderRadius: "50%", background: C.ink,
          display: "inline-block", animation: status !== "complete" ? "pulse 1.4s infinite" : "none",
        }} />
        {label}…
      </span>
    );
  }

  return (
    <div style={{ display: "flex", alignItems: "flex-start" }}>
      {PIPELINE_STAGES.map((stage, i) => (
        <div key={stage.key} style={{ display: "flex", alignItems: "center", flex: i < PIPELINE_STAGES.length - 1 ? 1 : "0 0 auto" }}>
          <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 6 }}>
            <div style={{
              width: 10, height: 10, borderRadius: "50%",
              background: i <= idx ? C.ink : "#fff",
              border: `2px solid ${i <= idx ? C.ink : C.borderStrong}`,
              animation: i === idx && status !== "complete" ? "pulse 1.4s infinite" : "none",
            }} />
            <span style={{ fontSize: 10, color: i <= idx ? C.text : C.textFaint, fontWeight: i === idx ? 700 : 500, whiteSpace: "nowrap" }}>
              {stage.label}
            </span>
          </div>
          {i < PIPELINE_STAGES.length - 1 && (
            <div style={{ flex: 1, height: 2, background: i < idx ? C.ink : C.border, margin: "0 6px 14px" }} />
          )}
        </div>
      ))}
    </div>
  );
}

const IN_PROGRESS_STATUSES = ["queued", "analyzing", "embedding"];

// ── Session Row ───────────────────────────────────────────────────────────────

function SessionRow({ session, selected, onClick }) {
  const frustrated = session.ai_frustrations?.length > 0;
  const inProgress = IN_PROGRESS_STATUSES.includes(session.ai_status);
  return (
    <div onClick={onClick} style={{
      padding: "14px 20px", borderBottom: `1px solid ${C.border}`,
      cursor: "pointer", transition: "background 0.15s",
      background: selected ? C.bgHover : "transparent",
      borderLeft: selected ? `3px solid ${C.ink}` : "3px solid transparent",
    }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12 }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
            <span style={{ fontSize: 11, color: C.textMuted, fontFamily: "monospace" }}>
              {session.session_id?.slice(0, 8)}
            </span>
            {!session.ended_at && session.started_at && Date.now() - new Date(session.started_at).getTime() < 30 * 60000 && (
              // No end signal yet and recent: probably still recording
              // (the replay's manifest says for sure).
              <span style={{ fontSize: 10, fontWeight: 700, color: C.text, display: "inline-flex", alignItems: "center", gap: 4 }}>
                <span style={{ width: 6, height: 6, borderRadius: "50%", background: C.ink, animation: "pulse 1.4s infinite" }} />live
              </span>
            )}
            {frustrated && <span style={{ fontSize: 10, fontWeight: 700, color: C.text }}>▲ frustrated</span>}
            {session.ai_goal_achieved === true && <span style={{ fontSize: 10, color: C.textMuted }}>✓ goal met</span>}
            {session.ai_goal_achieved === false && <span style={{ fontSize: 10, color: C.textMuted }}>✕ goal missed</span>}
            {typeof session.similarity_score === "number" && (
              <span style={{ fontSize: 10, color: C.textMuted }}>≈ {Math.round(session.similarity_score * 100)}% match</span>
            )}
          </div>
          <div title={session.url} style={{ fontSize: 12, color: C.textMuted, marginBottom: 6, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
            {shortUrl(session.url)}
          </div>
          {session.ai_status === "complete" && session.ai_summary ? (
            <div style={{ fontSize: 12, color: C.text, lineHeight: 1.5, display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden" }}>
              {session.ai_summary}
            </div>
          ) : inProgress ? (
            <AIPipelineStatus status={session.ai_status} compact />
          ) : session.ai_status === "failed" ? (
            <AIPipelineStatus status="failed" error={session.ai_error} compact />
          ) : null}
          <div style={{ display: "flex", gap: 6, marginTop: 8, flexWrap: "wrap" }}>
            {session.ai_tags?.slice(0, 4).map(t => <Tag key={t} label={t} />)}
          </div>
        </div>
        <div style={{ textAlign: "right", whiteSpace: "nowrap", fontSize: 11, color: C.textFaint }}>
          <div>{ago(session.created_at)}</div>
          <div style={{ marginTop: 4 }}>{dur(session.duration_ms)}</div>
          <div style={{ marginTop: 4 }}>{session.event_count} events</div>
        </div>
      </div>
    </div>
  );
}

// ── Session Replay Player (streaming) ────────────────────────────────────────
//
// Plays like a video stream instead of downloading the whole session first:
//   1. GET .../replay/manifest: the timeline (start/end, keyframes) only.
//   2. Load the first CHUNK_MS and start the player; its scrubber already
//      spans the whole session thanks to an end marker event.
//   3. While playing, keep AHEAD_MS loaded past the playhead (forward ranges).
//   4. When the playhead lands in a part that isn't loaded (scrubber click,
//      activity row, or playing past the buffer), pause, fetch from the
//      nearest keyframe (.../replay/events?at=), then resume there.
// rrweb can only start rendering at a Meta + FullSnapshot pair, which is what
// the server's `at=` mode guarantees for every jump.

const CHUNK_MS = 20000;
const AHEAD_MS = 15000;
// Live sessions: how close to the newest event the playhead must be to
// count as watching live. New events are pushed by .../replay/live.
const LIVE_EDGE_MS = 4000;
// Empty tag + transparent colour: rrweb-player draws a marker for every
// custom event, and this one only exists to stretch the timeline.
const END_MARKER_TAG = "";

// Problems shown as ticks on the player's scrubber (rrweb-player draws one
// per Custom event, coloured via its `tags` map, with the tag as tooltip).
const MARKER_COLORS = { error: C.ink, network: "#52525b", rage: "#a1a1aa" };
const MAX_MARKERS = 300;

function countBy(list, key) {
  const out = {};
  for (const x of list) out[key(x)] = (out[key(x)] || 0) + 1;
  return out;
}

function buildMarkers(activityEvents, sessionStart) {
  const a = buildActivity(activityEvents, sessionStart);
  const out = [];
  const add = (r, kind, label) => out.push({ ts: r.ts, kind, tag: `${label} · ${clock(r.at)}` });
  a.console.filter(c => c.level === "error" || c.level === "exception")
    .forEach(c => add(c, "error", `Error: ${String(c.message || "").slice(0, 80)}`));
  a.network.filter(n => !n.status || n.status >= 400)
    .forEach(n => add(n, "network", `${n.method} ${shortUrl(n.url || "")} → ${n.status || "failed"}`));
  a.behaviour.filter(b => b.kind === "rage_click")
    .forEach(b => add(b, "rage", `Rage click: ${b.detail || ""}`));
  return out.sort((x, y) => x.ts - y.ts).slice(0, MAX_MARKERS);
}

// Custom (type 5) events without { tag, payload } are the SDK's analytics
// metadata, not replayable; rrweb-player crashes on them (data.tag of
// undefined). Mobile wireframes are type 5 too and aren't displayed.
const playable = e => e.type !== 5;

function insertSorted(arr, evs) {
  for (const e of evs) {
    let lo = 0, hi = arr.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (arr[mid].timestamp <= e.timestamp) lo = mid + 1; else hi = mid;
    }
    arr.splice(lo, 0, e);
  }
}

class ReplayStreamer {
  constructor({ sessionId, masked, mount, width, onState }) {
    Object.assign(this, { sessionId, masked, mount, width, onState });
    this.player = null;
    this.ranges = [];        // loaded [from, to) absolute ms, sorted, merged
    this.events = [];        // every playable event loaded so far, sorted
    this.loading = null;     // in-flight load promise
    this.playing = false;
    this.destroyed = false;
    this.listeners = new Set();
    this.loadedEvents = 0;
    if (import.meta.env?.DEV) window.__replayStreamer = this; // debugging aid
  }

  url(params) {
    const q = new URLSearchParams({ masked: String(this.masked) });
    for (const [k, v] of Object.entries(params)) q.set(k, String(Math.floor(v)));
    return `${API}/api/v1/sessions/${this.sessionId}/replay/events?${q}`;
  }

  async fetchRange(params) {
    const res = await fetch(this.url(params));
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const evs = (data.events || []).sort((a, b) => a.timestamp - b.timestamp);
    this.loadedEvents += evs.length;
    return { from: data.from, to: data.to, events: evs.filter(playable) };
  }

  async start() {
    const base = `${API}/api/v1/sessions/${this.sessionId}/replay`;
    const [res, activity] = await Promise.all([
      fetch(`${base}/manifest?masked=${this.masked}`),
      // Small (navigation + SDK-tagged events); feeds the scrubber markers
      // and the activity tabs. A failure only costs the markers.
      fetch(`${base}/activity?masked=${this.masked}`)
        .then(r => (r.ok ? r.json() : { events: [] }))
        .then(d => (d.events || []).sort((a, b) => a.timestamp - b.timestamp))
        .catch(() => []),
    ]);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const m = (this.manifest = await res.json());
    this.activity = activity;
    if (!m.events) return { empty: "No events were recorded for this session." };
    if (!m.keyframes.length) {
      return { empty: "No full page snapshot was captured for this session (it may predate a fix, or recording was interrupted). Record a new session to replay it." };
    }
    // Cover at least one keyframe so there is something to render.
    const to = Math.min(m.end + 1, Math.max(m.start, m.keyframes[0]) + CHUNK_MS);
    const first = await this.fetchRange({ from: m.start, to });
    if (this.destroyed) return {};
    this.events = first.events;
    this.zero = this.events[0]?.timestamp ?? m.start; // player time 0
    // End marker: makes the scrubber span the whole session from the start.
    insertSorted(this.events, [{ type: 5, timestamp: m.end, data: { tag: END_MARKER_TAG, payload: {} } }]);
    // rrweb-player places markers once, as a % of the timeline at creation;
    // on a live session that keeps growing they would drift. Live sessions
    // get them on our own bar instead (ownMarkers), updated as events arrive.
    this.ownMarkers = !!m.live;
    this.liveMarkers = m.live ? buildMarkers(activity, m.start) : [];
    this.markers = m.live ? [] : buildMarkers(activity, m.start).filter(k => k.ts >= this.zero && k.ts <= m.end);
    this.tags = { [END_MARKER_TAG]: "transparent" };
    for (const k of this.markers) this.tags[k.tag] = MARKER_COLORS[k.kind];
    insertSorted(this.events, this.markers.map(k => ({ type: 5, timestamp: k.ts, data: { tag: k.tag, payload: {} } })));
    this.ranges = [[m.start, to]];
    this.createPlayer(0, false);
    if (m.live) {
      // Like a live stream: open at the newest moment and keep following.
      this.openLive();
      this.goLive();
    }
    return { manifest: m, activity };
  }

  // ── Live sessions ──

  atLiveEdge() {
    return this.now != null && this.now >= this.manifest.end - LIVE_EDGE_MS;
  }

  goLive() {
    this.seekAbs(this.manifest.end - 2000, true);
  }

  // The server pushes each new manifest with the events stored since the
  // last one (server-sent events; EventSource reconnects by itself and
  // resumes from the last update's id).
  openLive() {
    const q = new URLSearchParams({ masked: String(this.masked), after: String(this.manifest.end) });
    const es = (this.live = new EventSource(`${API}/api/v1/sessions/${this.sessionId}/replay/live?${q}`));
    es.addEventListener("update", e => {
      try { this.onLiveUpdate(JSON.parse(e.data)); }
      catch (err) { console.error("live update failed", err); }
    });
    es.addEventListener("end", () => { es.close(); this.emit(); });
  }

  onLiveUpdate({ manifest: m, events }) {
    if (this.destroyed) return;
    events = (events || []).sort((a, b) => a.timestamp - b.timestamp);
    const oldEnd = this.manifest.end;
    const following = this.atLiveEdge();
    // rrweb's playback timer stops once it runs out of events, while the
    // player still reports "playing" (and doesn't always fire "finish"):
    // a playhead that hasn't moved since the last update has stalled there.
    const stalled = this.finished || this.now === this.lastUpdateNow;
    this.lastUpdateNow = this.now;
    this.manifest = m;

    // Activity tabs: navigation and SDK-tagged events.
    const act = events.filter(e => e.type === 4 || (e.type === 5 && e.subtype));
    if (act.length) {
      this.activity = [...(this.activity || []), ...act].sort((a, b) => a.timestamp - b.timestamp);
      this.onActivity?.(this.activity);
      this.liveMarkers = buildMarkers(this.activity, m.start);
    }

    // Extend the range that reaches the old end; ranges elsewhere load the
    // usual way when the playhead gets there.
    const r = this.ranges.find(([a, b]) => a <= oldEnd && oldEnd < b);
    if (r && m.end >= r[1]) {
      const from = r[1];
      const add = events.filter(e => playable(e) && e.timestamp >= from);
      this.loadedEvents += add.length;
      add.forEach(e => this.player.addEvent(e));
      insertSorted(this.events, add);
      this.addRange(from, m.end + 1);
      // Stopped at the old end: carry on from there with the new events.
      if (following && stalled && add.length) this.player.goto(this.now - this.zero, true);
    }
    if (!m.live) this.live?.close();
    this.emit();
  }

  createPlayer(offset, play) {
    this.player?.$destroy?.();
    this.mount.innerHTML = "";
    const player = new RRWebPlayer({
      target: this.mount,
      props: {
        events: [...this.events], width: this.width, height: 480, autoPlay: false,
        tags: this.tags,
        // rrweb's virtual DOM (used to fast-forward on seek) throws
        // "insertBefore ... node type does not support" when a seek lands on
        // a later FullSnapshot once the first one has rendered; seeking
        // straight into the iframe DOM works for every keyframe.
        useVirtualDom: false,
      },
    });
    this.player = player;
    // The replayer keeps its own copy of the event array; jumps insert into
    // it directly (see insertBehindPlayhead).
    this.replayerEvents = player.getReplayer?.()?.service?.state?.context?.events || null;
    player.addEventListener("ui-update-player-state", e => {
      this.playing = e.payload === "playing";
      if (this.playing) this.finished = false;
    });
    // Reached the end of what is loaded (a live session's newest event).
    player.addEventListener("finish", () => { this.finished = true; });
    player.addEventListener("ui-update-current-time", e => this.onTime(this.zero + e.payload));
    if (offset || play) player.goto(offset, play);
  }

  rangeAt(t) {
    return this.ranges.find(([a, b]) => a <= t && t < b) || null;
  }

  addRange(from, to) {
    const rs = [...this.ranges, [from, to]].sort((x, y) => x[0] - y[0]);
    const merged = [];
    for (const r of rs) {
      const last = merged[merged.length - 1];
      if (last && r[0] <= last[1]) last[1] = Math.max(last[1], r[1]);
      else merged.push([...r]);
    }
    this.ranges = merged;
  }

  nextRangeStart(t) {
    const next = this.ranges.find(([a]) => a > t);
    return next ? next[0] : this.manifest.end + 1;
  }

  keyframeAtOrBefore(t) {
    let k = null;
    for (const kf of this.manifest.keyframes) { if (kf <= t) k = kf; else break; }
    return k ?? this.manifest.start;
  }

  emit() {
    this.onState?.({
      live: !!this.manifest?.live,
      atLiveEdge: !!this.manifest && this.atLiveEdge(),
      end: this.manifest?.end,
      ranges: this.ranges.map(r => [...r]),
      buffering: this.buffering,
      failed: this.failed,
      loadedEvents: this.loadedEvents,
      markers: this.ownMarkers ? this.liveMarkers : null,
    });
  }

  onTime(t) {
    this.now = t;
    this.listeners.forEach(fn => fn(t));
    if (this.destroyed || this.loading || !this.manifest) return;
    t = Math.min(t, this.manifest.end);
    const r = this.rangeAt(t);
    if (r) {
      if (r[1] <= this.manifest.end && r[1] - t < AHEAD_MS) this.loadForward(r);
    } else {
      this.jumpTo(t, this.playing);
    }
  }

  // Extend a playing range; events land ahead of the playhead, so the
  // replayer's addEvent schedules them normally.
  loadForward(r) {
    const from = r[1];
    const to = Math.min(from + CHUNK_MS, this.nextRangeStart(from));
    this.loading = this.fetchRange({ from, to })
      .then(({ events }) => {
        if (this.destroyed) return;
        events.forEach(e => this.player.addEvent(e));
        insertSorted(this.events, events);
        this.addRange(from, to);
      })
      .catch(err => { console.error("replay prefetch failed", err); this.fail(); })
      .finally(() => { this.loading = null; this.emit(); });
    return this.loading;
  }

  // Load around t (from its keyframe) and resume there.
  async jumpTo(t, resume) {
    const p = (async () => {
      this.buffering = true;
      this.emit();
      this.player.pause();
      const k = this.keyframeAtOrBefore(t);
      const covering = this.ranges.find(([a, b]) => a <= k && k <= b);
      let from, to, events;
      if (covering) {
        // Keyframe already loaded (or adjacent): just extend that range.
        from = covering[1];
        to = Math.min(Math.max(t, from) + CHUNK_MS, this.nextRangeStart(from));
        ({ events } = await this.fetchRange({ from, to }));
      } else {
        to = Math.min(t + CHUNK_MS, this.nextRangeStart(t));
        ({ from, events } = await this.fetchRange({ at: t, to }));
      }
      if (this.destroyed) return;
      events = events.filter(e => e.timestamp >= this.zero);
      insertSorted(this.events, events);
      this.addRange(from, to);
      this.insertBehindPlayhead(events, t - this.zero, resume);
    })();
    this.loading = p;
    try { await p; }
    catch (err) { console.error("replay jump failed", err); this.fail(); }
    finally { this.loading = null; this.buffering = false; this.emit(); }
  }

  insertBehindPlayhead(events, offset, resume) {
    if (this.replayerEvents) {
      // Insert without casting: rrweb's addEvent would apply events older
      // than its current baseline to the live DOM immediately, out of order.
      insertSorted(this.replayerEvents, events);
      this.player.goto(offset, resume);
    } else {
      // Unknown player internals: rebuild with everything loaded so far.
      this.createPlayer(offset, resume);
    }
  }

  // Surface a failed load for a few seconds; the next seek or time update
  // retries it.
  fail() {
    this.failed = true;
    clearTimeout(this.failTimer);
    this.failTimer = setTimeout(() => { this.failed = false; this.emit(); }, 4000);
  }

  seekAbs(t, play = this.playing) {
    if (!this.manifest) return;
    t = Math.max(this.manifest.start, Math.min(t, this.manifest.end));
    if (this.rangeAt(t)) this.player.goto(t - this.zero, play);
    else if (!this.loading) this.jumpTo(t, play);
  }

  destroy() {
    this.destroyed = true;
    clearTimeout(this.failTimer);
    this.live?.close();
    this.player?.$destroy?.();
    this.player = null;
    this.listeners.clear();
  }
}

function SessionReplay({ sessionId, playerApiRef, onTime, onManifest, onActivity }) {
  const wrapperRef = useRef(null); // always visible, safe to measure for width
  const containerRef = useRef(null); // hidden until ready, clientWidth would read 0
  const [status, setStatus] = useState("loading"); // loading | ready | empty | error
  const [errorMessage, setErrorMessage] = useState("");
  const [stream, setStream] = useState({ ranges: [], buffering: false, loadedEvents: 0, live: false });
  const [manifest, setManifest] = useState(null);
  const [markerCounts, setMarkerCounts] = useState({});
  const [copied, setCopied] = useState(false);
  const streamerRef = useRef(null);
  // Defaults to masked - the server stores a redacted copy of every session
  // alongside the raw one (see backend/internal/masking) and serves that by
  // default; flipping this re-fetches the raw, unmasked copy instead.
  const [masked, setMasked] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setStatus("loading");
    setManifest(null);
    setMarkerCounts({});
    const streamer = new ReplayStreamer({
      sessionId, masked, mount: containerRef.current,
      width: wrapperRef.current.clientWidth,
      onState: s => { if (!cancelled) setStream(s); },
    });
    streamer.listeners.add(t => onTime?.(t));
    streamer.onActivity = a => { if (!cancelled) onActivity?.(a); }; // live refreshes
    streamerRef.current = streamer;

    streamer.start().then(r => {
      if (cancelled) return;
      if (r.empty) {
        onActivity?.(streamer.activity || []);
        setErrorMessage(r.empty);
        setStatus("empty");
        return;
      }
      if (playerApiRef) playerApiRef.current = { seek: t => streamer.seekAbs(t), now: () => streamer.now };
      setManifest(r.manifest);
      onManifest?.(r.manifest);
      onActivity?.(r.activity);
      setMarkerCounts(countBy(streamer.markers || [], k => k.kind));
      streamer.emit();
      setStatus("ready");
    }).catch(e => {
      if (cancelled) return;
      console.error("Failed to load replay:", e);
      setErrorMessage(e.message || "Unknown error");
      setStatus("error");
    });

    return () => {
      cancelled = true;
      streamer.destroy();
      if (playerApiRef) playerApiRef.current = null;
      if (containerRef.current) containerRef.current.innerHTML = "";
    };
  }, [sessionId, masked]);

  // The manifest grows while a session is live; the stream state has the
  // latest end.
  const end = stream.end ?? manifest?.end;
  const span = manifest ? Math.max(1, end - manifest.start) : 1;
  // Live sessions draw markers on the bar below (see ReplayStreamer.start).
  const counts = stream.markers ? countBy(stream.markers, k => k.kind) : markerCounts;

  return (
    <div ref={wrapperRef} style={{ position: "relative" }}>
      <div style={{ display: "flex", justifyContent: "flex-end", gap: 8, marginBottom: 8 }}>
        {status === "ready" && manifest && (
          <button
            onClick={async () => {
              const now = streamerRef.current?.now ?? manifest.start;
              const link = sessionLink(sessionId, (now - manifest.start) / 1000);
              try { await navigator.clipboard.writeText(link); } catch { window.prompt("Copy this link", link); return; }
              setCopied(true);
              setTimeout(() => setCopied(false), 1500);
            }}
            title="Copy a link that opens this session at the current moment"
            style={{
              padding: "5px 12px", borderRadius: 6, fontSize: 11, fontWeight: 600, cursor: "pointer",
              border: `1px solid ${C.borderStrong}`, background: "transparent", color: C.textMuted,
            }}
          >
            {copied ? "✓ Link copied" : "🔗 Copy link at this moment"}
          </button>
        )}
        {manifest?.device_masked ? (
          // Mobile: pixels were masked on the phone before upload, so there
          // is no unmasked copy to switch to.
          <span title="Masked on the device before upload (mobile recording). There is no unmasked copy." style={{
            display: "flex", alignItems: "center", gap: 6,
            padding: "5px 12px", borderRadius: 6, fontSize: 11, fontWeight: 600,
            border: `1px solid ${C.border}`, color: C.textMuted,
          }}>
            <span>🔒</span>Masked on device
          </span>
        ) : (
        <button
          onClick={() => setMasked(m => !m)}
          title={masked
            ? "PII is redacted in this replay (passwords, card numbers, emails, and anything tagged riq-mask). Click to reveal real values."
            : "Showing real, unmasked values captured during this session."}
          style={{
            display: "flex", alignItems: "center", gap: 6,
            padding: "5px 12px", borderRadius: 6, fontSize: 11, fontWeight: 600,
            cursor: "pointer", border: `1px solid ${masked ? C.borderStrong : C.ink}`,
            background: masked ? "transparent" : C.ink,
            color: masked ? C.textMuted : "#fff",
          }}
        >
          <span>{masked ? "🔒" : "🔓"}</span>
          {masked ? "Masked" : "Unmasked"}
        </button>
        )}
      </div>
      {/* Status overlay: a sibling React fully owns. It's never the same node
          rrweb-player writes into, so React and the player never fight over
          the same children (that conflict throws DOM NotFoundErrors). */}
      {status !== "ready" && (
        <div style={{
          background: C.bgSubtle, borderRadius: 8, border: `1px solid ${C.border}`,
          minHeight: 270, display: "flex", alignItems: "center", justifyContent: "center",
        }}>
          {status === "loading" && <div style={{ fontSize: 12, color: C.textMuted }}>Loading replay…</div>}
          {status === "empty" && (
            <div style={{ textAlign: "center", maxWidth: 360, padding: "0 16px" }}>
              <div style={{ fontSize: 28, marginBottom: 8, color: C.textFaint }}>▶</div>
              <div style={{ fontSize: 12, color: C.textMuted }}>{errorMessage || "Not enough events captured to replay this session."}</div>
            </div>
          )}
          {status === "error" && (
            <div style={{ textAlign: "center", maxWidth: 360, padding: "0 16px" }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: C.text, marginBottom: 4 }}>Failed to load replay for this session.</div>
              {errorMessage && <div style={{ fontSize: 11, color: C.textMuted }}>{errorMessage}</div>}
            </div>
          )}
        </div>
      )}
      <div style={{ position: "relative", display: status === "ready" ? "block" : "none" }}>
        {/* Player mount point: React only ever sets attributes here, never
            children - rrweb-player owns everything inside it imperatively. */}
        <div ref={containerRef} style={{
          background: C.bgSubtle, borderRadius: 8, border: `1px solid ${C.border}`, overflow: "hidden",
        }} />
        {(stream.buffering || stream.failed) && (
          <div style={{
            position: "absolute", top: 12, left: "50%", transform: "translateX(-50%)",
            padding: "4px 12px", borderRadius: 12, background: C.ink, color: "#fff",
            fontSize: 11, fontWeight: 600, pointerEvents: "none",
            animation: stream.failed ? "none" : "pulse 1.2s infinite",
          }}>{stream.failed ? "Couldn't load this part of the replay. Seek again to retry." : "Buffering…"}</div>
        )}
      </div>
      {status === "ready" && manifest && (
        <div style={{ marginTop: 8 }}>
          {/* Loaded parts of the timeline, like a video player's buffer bar. */}
          <div title="Loaded parts of the session" style={{ position: "relative", height: 4, borderRadius: 2, background: C.border, overflow: "hidden" }}>
            {stream.ranges.map(([a, b], i) => (
              <div key={i} style={{
                position: "absolute", top: 0, bottom: 0, background: C.textFaint,
                left: `${((a - manifest.start) / span) * 100}%`,
                width: `${(Math.min(b, end + 1) - a) / span * 100}%`,
              }} />
            ))}
          </div>
          {stream.markers?.length > 0 && (
            // Problems so far, on a timeline that grows with the session.
            <div style={{ position: "relative", height: 12, marginTop: 3 }}>
              {stream.markers.map((k, i) => (
                <button
                  key={i}
                  onClick={() => streamerRef.current?.seekAbs(k.ts)}
                  title={k.tag}
                  aria-label={k.tag}
                  style={{
                    position: "absolute", top: 0, height: 12, width: 3, padding: 0, border: 0, borderRadius: 1,
                    cursor: "pointer", background: MARKER_COLORS[k.kind],
                    left: `calc(${Math.min(100, ((k.ts - manifest.start) / span) * 100)}% - 1px)`,
                  }}
                />
              ))}
            </div>
          )}
          <div style={{ display: "flex", justifyContent: "space-between", gap: 12, flexWrap: "wrap", marginTop: 4, fontSize: 10, color: C.textFaint }}>
            <span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}>
              {stream.live && (
                // Live session: jump to the newest moment and follow it.
                <button
                  onClick={() => streamerRef.current?.goLive()}
                  title={stream.atLiveEdge ? "Watching live" : "Jump to the newest moment and follow it"}
                  style={{
                    display: "inline-flex", alignItems: "center", gap: 5,
                    padding: "1px 8px", borderRadius: 10, fontSize: 10, fontWeight: 700, letterSpacing: "0.04em",
                    cursor: "pointer", border: `1px solid ${C.ink}`,
                    background: stream.atLiveEdge ? C.ink : "transparent",
                    color: stream.atLiveEdge ? "#fff" : C.ink,
                  }}
                >
                  <span style={{ width: 6, height: 6, borderRadius: "50%", background: stream.atLiveEdge ? "#fff" : C.ink, animation: "pulse 1.4s infinite" }} />
                  {stream.atLiveEdge ? "LIVE" : "GO LIVE"}
                </button>
              )}
              Streaming · {stream.loadedEvents} events loaded · {manifest.keyframes.length} keyframe{manifest.keyframes.length === 1 ? "" : "s"}
            </span>
            {/* Legend for the marker ticks (rrweb-player's scrubber, or the
                bar above for live sessions). */}
            <span style={{ display: "flex", gap: 10 }}>
              {[["error", "errors"], ["network", "failed requests"], ["rage", "rage clicks"]]
                .filter(([k]) => counts[k])
                .map(([k, label]) => (
                  <span key={k} style={{ display: "inline-flex", alignItems: "center", gap: 4 }}>
                    <span style={{ width: 3, height: 9, borderRadius: 1, background: MARKER_COLORS[k] }} />
                    {counts[k]} {label}
                  </span>
                ))}
            </span>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Behaviour / Console / Network ─────────────────────────────────────────────

function clock(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

// Splits the session's activity events into the three lists. `ts` is the
// absolute time (used to seek and to highlight the row at the playhead);
// `at` is relative to the session start, matching the player's clock.
function buildActivity(events, sessionStart) {
  const start = sessionStart ?? events.find(e => e.type !== 5)?.timestamp ?? events[0]?.timestamp ?? 0;
  const behaviour = [], consoleLogs = [], network = [];
  let lastHref = null;
  for (const e of events) {
    const ts = e.timestamp, at = ts - start;
    // Page/screen changes come from Meta events and from app-reported
    // navigations (mobile companion); show each change once.
    const href = e.type === 4 ? e.data?.href : e.type === 5 && e.subtype === "navigate" ? e.url : null;
    if (href) {
      const key = href.replace(/\/+$/, "");
      if (key !== lastHref) {
        lastHref = key;
        behaviour.push({ ts, at, kind: "navigate", label: "Navigate", detail: href });
      }
      continue;
    }
    if (e.type !== 5) continue;
    switch (e.subtype) {
      case "click":
        behaviour.push({ ts, at, kind: "click", label: "Click", detail: e.selector });
        break;
      case "rage_click":
        behaviour.push({ ts, at, kind: "rage_click", label: "Rage click", detail: e.selector, strong: true });
        break;
      case "input":
        behaviour.push({ ts, at, kind: "input", label: "Input", detail: e.selector });
        break;
      case "console":
        consoleLogs.push({ ts, at, level: e.level || "log", message: e.message, stack: e.stack });
        break;
      case "js_error":
        consoleLogs.push({
          ts, at, level: "exception", message: e.message, stack: e.stack,
          source: e.filename ? `${shortUrl(e.filename)}${e.lineno ? `:${e.lineno}` : ""}${e.colno ? `:${e.colno}` : ""}` : null,
        });
        break;
      case "network":
        network.push({ ts, at, method: e.method || "GET", url: e.url, status: e.status, duration: e.duration, error: e.error });
        break;
    }
  }
  // Inputs fire per keystroke; collapse a run on the same field into one row.
  const merged = [];
  for (const b of behaviour) {
    const prev = merged[merged.length - 1];
    if (b.kind === "input" && prev?.kind === "input" && prev.detail === b.detail) {
      prev.count = (prev.count || 1) + 1;
      continue;
    }
    merged.push({ ...b });
  }
  return { behaviour: merged, console: consoleLogs, network };
}

const ACTIVITY_TABS = [
  { key: "behaviour", label: "Behaviour" },
  { key: "console", label: "Console" },
  { key: "network", label: "Network" },
];

function ActivityPanel({ events, start, currentTime, onSeek }) {
  const [tab, setTab] = useState("behaviour");
  const [errorsOnly, setErrorsOnly] = useState(false);
  const activity = useMemo(() => buildActivity(events || [], start), [events, start]);

  const errorCount = {
    behaviour: activity.behaviour.filter(b => b.kind === "rage_click").length,
    console: activity.console.filter(c => c.level === "error" || c.level === "exception").length,
    network: activity.network.filter(n => !n.status || n.status >= 400).length,
  };

  let rows = activity[tab];
  if (errorsOnly) {
    rows = rows.filter(r =>
      tab === "behaviour" ? r.kind === "rage_click"
      : tab === "console" ? r.level === "error" || r.level === "exception"
      : !r.status || r.status >= 400);
  }
  // Last row at or before the playhead, highlighted as "now".
  let activeIdx = -1;
  if (typeof currentTime === "number") {
    rows.forEach((r, i) => { if (r.ts <= currentTime) activeIdx = i; });
  }

  const cell = { padding: "7px 10px", fontSize: 12, verticalAlign: "top" };
  const mono = { fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace" };

  return (
    <div style={{ marginTop: 16, border: `1px solid ${C.border}`, borderRadius: 8, overflow: "hidden" }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", borderBottom: `1px solid ${C.border}`, background: C.bgSubtle, padding: "0 8px" }}>
        <div style={{ display: "flex" }}>
          {ACTIVITY_TABS.map(t => {
            const active = tab === t.key;
            return (
              <button key={t.key} onClick={() => setTab(t.key)} style={{
                padding: "10px 12px", fontSize: 12, fontWeight: 600, cursor: "pointer",
                background: "transparent", border: "none",
                borderBottom: `2px solid ${active ? C.ink : "transparent"}`,
                color: active ? C.text : C.textMuted, marginBottom: -1,
              }}>
                {t.label}
                <span style={{ marginLeft: 6, fontSize: 10, color: C.textFaint }}>{activity[t.key].length}</span>
                {errorCount[t.key] > 0 && (
                  <span style={{ marginLeft: 4, fontSize: 10, fontWeight: 700, padding: "0 5px", borderRadius: 8, background: C.ink, color: "#fff" }}>
                    {errorCount[t.key]}
                  </span>
                )}
              </button>
            );
          })}
        </div>
        <label style={{ fontSize: 11, color: C.textMuted, display: "flex", alignItems: "center", gap: 6, cursor: "pointer" }}>
          <input type="checkbox" checked={errorsOnly} onChange={e => setErrorsOnly(e.target.checked)} />
          {tab === "behaviour" ? "Frustration only" : "Errors only"}
        </label>
      </div>

      <div style={{ maxHeight: 320, overflowY: "auto" }}>
        {events === null ? (
          <div style={{ padding: 20, fontSize: 12, color: C.textMuted, textAlign: "center" }}>Loading activity…</div>
        ) : rows.length === 0 ? (
          <div style={{ padding: 20, fontSize: 12, color: C.textFaint, textAlign: "center" }}>
            {errorsOnly ? "Nothing matches this filter." : {
              behaviour: "No clicks, inputs or navigation captured.",
              console: "No console warnings or errors captured.",
              network: "No network requests captured (the mobile SDK does not record them yet).",
            }[tab]}
          </div>
        ) : (
          <table style={{ width: "100%", borderCollapse: "collapse", tableLayout: "fixed" }}>
            <tbody>
              {rows.map((r, i) => {
                const isError = tab === "console" ? (r.level === "error" || r.level === "exception")
                  : tab === "network" ? (!r.status || r.status >= 400)
                  : r.strong;
                return (
                  <tr key={i} onClick={() => onSeek?.(r.ts)} title="Jump to this moment in the replay" style={{
                    cursor: "pointer", borderBottom: `1px solid ${C.border}`,
                    background: i === activeIdx ? C.bgHover : "transparent",
                    boxShadow: isError ? `inset 3px 0 0 ${C.ink}` : "none",
                  }}>
                    <td style={{ ...cell, ...mono, width: 56, color: C.textFaint }}>{clock(r.at)}</td>
                    {tab === "behaviour" && <>
                      <td style={{ ...cell, width: 96, fontWeight: r.strong ? 700 : 600, color: C.text }}>{r.label}</td>
                      <td style={{ ...cell, ...mono, color: C.textMuted, wordBreak: "break-all" }}>
                        {r.detail || "—"}{r.count > 1 && <span style={{ color: C.textFaint }}> ×{r.count}</span>}
                      </td>
                    </>}
                    {tab === "console" && <>
                      <td style={{ ...cell, width: 80, fontWeight: isError ? 700 : 600, color: isError ? C.text : C.textMuted, textTransform: "uppercase", fontSize: 10, letterSpacing: "0.04em" }}>{r.level}</td>
                      <td style={{ ...cell, ...mono, color: C.text, whiteSpace: "pre-wrap", wordBreak: "break-word" }}>
                        {r.message}
                        {r.source && <div style={{ fontSize: 11, color: C.textMuted, marginTop: 2 }}>at {r.source}</div>}
                        {r.stack && (
                          // Clicking the stack toggles it; it must not also seek.
                          <details onClick={e => e.stopPropagation()} style={{ marginTop: 4 }}>
                            <summary style={{ fontSize: 11, color: C.textMuted, cursor: "pointer" }}>Stack trace</summary>
                            <pre style={{ ...mono, fontSize: 11, color: C.textMuted, whiteSpace: "pre-wrap", margin: "4px 0 0", maxHeight: 200, overflow: "auto" }}>{r.stack}</pre>
                          </details>
                        )}
                      </td>
                    </>}
                    {tab === "network" && <>
                      <td style={{ ...cell, ...mono, width: 60, fontWeight: 600, color: C.text }}>{r.method}</td>
                      <td title={r.url} style={{ ...cell, ...mono, color: C.textMuted, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                        {r.url}
                        {r.error && <div style={{ fontSize: 11, color: C.text, whiteSpace: "normal" }}>{r.error}</div>}
                      </td>
                      <td style={{ ...cell, ...mono, width: 60, textAlign: "right", fontWeight: isError ? 700 : 500, color: isError ? C.text : C.textMuted }}>{r.status || "failed"}</td>
                      <td style={{ ...cell, ...mono, width: 70, textAlign: "right", color: C.textFaint }}>{r.duration == null ? "—" : r.duration === 0 ? "0ms" : dur(r.duration)}</td>
                    </>}
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}

// ── Session Detail ────────────────────────────────────────────────────────────

// A "▶ 00:19" button that jumps the replay to a finding's moment.
function JumpButton({ ts, start, source, onSeek }) {
  if (!ts) return null;
  return (
    <button
      onClick={() => onSeek(ts)}
      title={source === "matched"
        ? "Jump the replay here (matched from the session's events)"
        : "Jump the replay to this moment"}
      style={{
        flex: "0 0 auto", padding: "1px 8px", borderRadius: 10, fontSize: 11, fontWeight: 600,
        fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
        border: `1px solid ${C.borderStrong}`, background: C.bg, color: C.text, cursor: "pointer",
      }}
    >
      ▶ {start != null ? clock(ts - start) : "play"}{source === "matched" ? " ≈" : ""}
    </button>
  );
}

function SessionDetail({ session, onAnalyze, onCreateJira, pendingSeek, onSeekDone }) {
  const [loading, setLoading] = useState(false);
  const [activityEvents, setActivityEvents] = useState(null);
  const [replayStart, setReplayStart] = useState(null);
  const [currentTime, setCurrentTime] = useState(null); // absolute ms
  const [moments, setMoments] = useState(null);
  const playerApiRef = useRef(null);
  const replayRef = useRef(null);
  // The activity tabs read the light activity feed (navigation + SDK-tagged
  // events), which the replay loads alongside its manifest.
  useEffect(() => {
    setActivityEvents(null);
    setReplayStart(null);
    setCurrentTime(null);
  }, [session.session_id]);
  const analyzed = session.ai_status === "complete" && session.ai_summary;

  // When each AI finding happened, for the jump buttons.
  useEffect(() => {
    let cancelled = false;
    setMoments(null);
    if (!analyzed) return;
    fetch(`${API}/api/v1/sessions/${session.session_id}/moments`)
      .then(r => (r.ok ? r.json() : null))
      .then(d => { if (!cancelled) setMoments(d); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [session.session_id, analyzed]);

  const seek = ts => {
    playerApiRef.current?.seek(ts);
    replayRef.current?.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  // Deep links and "open replay" from the Issues tab: seek once the replay
  // (and, for an issue, its moment) is known.
  useEffect(() => {
    if (!pendingSeek || replayStart == null || !playerApiRef.current) return;
    let ts = null;
    if (pendingSeek.kind === "offset") ts = replayStart + pendingSeek.sec * 1000;
    else if (pendingSeek.kind === "abs") ts = pendingSeek.ts;
    else if (pendingSeek.kind === "issue") {
      if (!moments && analyzed) return; // wait for moments
      ts = moments?.issues?.find(m => m.id === pendingSeek.id)?.ts || null;
    }
    if (ts) seek(ts);
    onSeekDone?.();
  }, [pendingSeek, replayStart, moments, analyzed]);

  const handleAnalyze = async () => {
    setLoading(true);
    await onAnalyze(session.session_id);
    setLoading(false);
  };

  return (
    <div style={{ height: "100%", overflowY: "auto", padding: "24px" }}>
      {/* Header */}
      <div style={{ marginBottom: 24 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 12 }}>
          <div>
            <div style={{ fontSize: 11, color: C.textMuted, marginBottom: 4, fontFamily: "monospace" }}>
              SESSION ID
            </div>
            <div style={{ fontSize: 13, color: C.text, fontFamily: "monospace" }}>
              {session.session_id}
            </div>
          </div>
          <div style={{ display: "flex", gap: 8 }}>
            <button onClick={handleAnalyze} disabled={loading} style={{
              padding: "8px 16px", borderRadius: 6, border: `1px solid ${C.ink}`,
              background: loading ? C.bgHover : C.ink, color: loading ? C.textMuted : "#fff", fontSize: 12, fontWeight: 600,
              cursor: loading ? "not-allowed" : "pointer",
            }}>
              {loading ? "Analyzing…" : "Analyze with AI"}
            </button>
          </div>
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 12 }}>
          {[
            ["URL", session.url?.slice(0, 24) + "…"],
            ["Duration", dur(session.duration_ms)],
            ["Events", session.event_count],
            ["User", session.user_id || "—"],
            ["Started", ago(session.started_at)],
            ["Screen", `${session.screen_width}×${session.screen_height}`],
          ].map(([k, v]) => (
            <div key={k} style={{ background: C.bgSubtle, borderRadius: 6, padding: "10px 14px", border: `1px solid ${C.border}` }}>
              <div style={{ fontSize: 10, color: C.textMuted, marginBottom: 4, fontWeight: 600, letterSpacing: "0.05em" }}>{k}</div>
              <div style={{ fontSize: 12, color: C.text, wordBreak: "break-all" }}>{v || "—"}</div>
            </div>
          ))}
        </div>
      </div>

      {/* AI Analysis */}
      {analyzed ? (
        <div style={{ marginBottom: 24 }}>
          <SectionHeader>AI Session Intelligence</SectionHeader>

          {/* Summary */}
          <div style={{ background: C.bgSubtle, borderRadius: 8, padding: 16, border: `1px solid ${C.border}`, marginBottom: 12 }}>
            <div style={{ fontSize: 11, color: C.textMuted, marginBottom: 8, fontWeight: 600 }}>NARRATIVE</div>
            <div style={{ fontSize: 13, color: C.text, lineHeight: 1.7 }}>{session.ai_summary}</div>
          </div>

          {/* Goal */}
          <div style={{
            background: session.ai_goal_achieved ? C.bgHover : "#fff",
            borderRadius: 8, padding: 16,
            border: session.ai_goal_achieved ? `1px solid ${C.border}` : `1px dashed ${C.borderStrong}`,
            marginBottom: 12,
          }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: C.text }}>
              {session.ai_goal_achieved ? "✓ GOAL ACHIEVED" : "✕ GOAL NOT ACHIEVED"}
            </div>
          </div>

          {/* Frustrations */}
          {session.ai_frustrations?.length > 0 && (
            <div style={{ background: C.bgSubtle, borderRadius: 8, padding: 16, border: `1px solid ${C.border}`, marginBottom: 12 }}>
              <div style={{ fontSize: 11, color: C.text, marginBottom: 10, fontWeight: 700 }}>FRUSTRATIONS DETECTED</div>
              {session.ai_frustrations.map((f, i) => {
                const m = moments?.frustrations?.[i];
                return (
                  <div key={i} style={{ display: "flex", gap: 8, alignItems: "flex-start", justifyContent: "space-between", fontSize: 12, color: C.textMuted, marginBottom: 6, paddingLeft: 12, borderLeft: `2px solid ${C.ink}` }}>
                    <span>{f}</span>
                    <JumpButton ts={m?.ts} source={m?.source} start={replayStart} onSeek={seek} />
                  </div>
                );
              })}
            </div>
          )}

          {/* This session's issues, with where they happened */}
          {moments?.issues?.length > 0 && (
            <div style={{ background: C.bgSubtle, borderRadius: 8, padding: 16, border: `1px solid ${C.border}`, marginBottom: 12 }}>
              <div style={{ fontSize: 11, color: C.text, marginBottom: 10, fontWeight: 700 }}>ISSUES</div>
              {moments.issues.map(m => (
                <div key={m.id} style={{ display: "flex", gap: 8, alignItems: "flex-start", justifyContent: "space-between", fontSize: 12, color: C.textMuted, marginBottom: 6, paddingLeft: 12, borderLeft: `2px solid ${C.borderStrong}` }}>
                  <span>{m.text}</span>
                  <JumpButton ts={m.ts} source={m.source} start={replayStart} onSeek={seek} />
                </div>
              ))}
            </div>
          )}

          {/* Tags */}
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            {session.ai_tags?.map(t => <Tag key={t} label={t} />)}
          </div>
        </div>
      ) : (
        <div style={{ background: C.bgSubtle, borderRadius: 8, padding: 24, textAlign: "center", border: `1px dashed ${C.border}`, marginBottom: 24 }}>
          <div style={{ marginBottom: 16 }}>
            <AIPipelineStatus status={session.ai_status} error={session.ai_error} />
          </div>
          <div style={{ fontSize: 13, color: C.textMuted }}>
            {session.ai_status === "failed"
              ? 'Click "Analyze with AI" to retry.'
              : IN_PROGRESS_STATUSES.includes(session.ai_status)
              ? "Analyzing this session…"
              : 'No AI analysis yet. Click "Analyze with AI" to generate insights.'}
          </div>
        </div>
      )}

      {/* Session Replay */}
      <div ref={replayRef} style={{ scrollMarginTop: 12 }}>
        <SectionHeader>Session Replay</SectionHeader>
        <SessionReplay
          sessionId={session.session_id}
          onManifest={m => setReplayStart(m.start)}
          onActivity={setActivityEvents}
          onTime={setCurrentTime}
          playerApiRef={playerApiRef}
        />
        <ActivityPanel
          events={activityEvents}
          start={replayStart}
          currentTime={currentTime}
          onSeek={ts => playerApiRef.current?.seek(ts)}
        />
      </div>
    </div>
  );
}

// ── Issues Panel ──────────────────────────────────────────────────────────────

function IssuesPanel({ issues, onCreateJira, onOpenIssue }) {
  return (
    <div style={{ height: "100%", overflowY: "auto", padding: "24px" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 20 }}>
        <div style={{ fontSize: 14, fontWeight: 600, color: C.text }}>AI-Generated Issues</div>
        <Tag label={`${issues.length} issues`} />
      </div>

      {issues.length === 0 ? (
        <div style={{ textAlign: "center", padding: "60px 0", color: C.textFaint, fontSize: 13 }}>
          No issues yet. Analyze sessions to detect problems automatically.
        </div>
      ) : (
        issues.map(issue => {
          const sevStyle = severityStyle(issue.severity);
          return (
            <div key={issue.id} style={{
              background: C.bg, borderRadius: 8, padding: 16,
              border: `1px solid ${C.border}`, marginBottom: 12,
            }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 8 }}>
                <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                  <span style={{
                    fontSize: 10, fontWeight: 700, padding: "2px 6px", borderRadius: 3,
                    letterSpacing: "0.02em",
                    background: sevStyle.background, color: sevStyle.color, border: `1px solid ${sevStyle.borderColor}`,
                  }}>
                    {issue.severity}
                  </span>
                  <span style={{ fontSize: 10, fontWeight: 700, color: C.textMuted, letterSpacing: "0.04em" }}>{typeLabel(issue.type)}</span>
                </div>
                <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                  {issue.jira_key ? (
                    <a href={issue.jira_url} target="_blank" rel="noreferrer" style={{
                      fontSize: 11, color: C.text, textDecoration: "none", fontWeight: 600,
                      border: `1px solid ${C.borderStrong}`, borderRadius: 4, padding: "2px 8px",
                    }}>
                      {issue.jira_key} ↗
                    </a>
                  ) : (
                    <button onClick={() => onCreateJira(issue)} style={{
                      fontSize: 11, padding: "4px 10px", borderRadius: 4,
                      border: `1px solid ${C.borderStrong}`, background: "transparent",
                      color: C.text, cursor: "pointer",
                    }}>
                      Push to Jira
                    </button>
                  )}
                </div>
              </div>
              <div style={{ fontSize: 13, fontWeight: 600, color: C.text, marginBottom: 6 }}>{issue.title}</div>
              <div style={{ fontSize: 12, color: C.textMuted, lineHeight: 1.6, marginBottom: 10 }}>{issue.description}</div>
              <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                {issue.tags?.map(t => <Tag key={t} label={t} />)}
              </div>
              {issue.session_id && (
                <div style={{ marginTop: 8, fontSize: 11, color: C.textFaint, display: "flex", alignItems: "center", gap: 10 }}>
                  <span>Session: <span style={{ color: C.textMuted, fontFamily: "monospace" }}>{issue.session_id.slice(0, 8)}</span></span>
                  <button onClick={() => onOpenIssue?.(issue)} style={{
                    fontSize: 11, padding: "2px 10px", borderRadius: 10, fontWeight: 600,
                    border: `1px solid ${C.borderStrong}`, background: "transparent", color: C.text, cursor: "pointer",
                  }}>
                    ▶ Watch in replay
                  </button>
                </div>
              )}
            </div>
          );
        })
      )}
    </div>
  );
}

// ── Stream Feed ───────────────────────────────────────────────────────────────

function StreamFeed({ sessions }) {
  return (
    <div style={{ height: "100%", overflowY: "auto", padding: "24px" }}>
      <div style={{ marginBottom: 20 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
          <span style={{ width: 8, height: 8, borderRadius: "50%", background: C.ink, display: "inline-block", animation: "pulse 2s infinite" }} />
          <span style={{ fontSize: 14, fontWeight: 600, color: C.text }}>session-context.stream</span>
        </div>
        <div style={{ fontSize: 11, color: C.textFaint }}>Live tokenized session context feed</div>
      </div>

      {sessions.slice(0, 8).map(s => (
        <div key={s.session_id} style={{
          background: C.bgSubtle, borderRadius: 8, padding: 14,
          border: `1px solid ${C.border}`, marginBottom: 10, fontFamily: "monospace",
        }}>
          <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 6 }}>
            <span style={{ fontSize: 11, color: C.text }}>ses_{s.session_id?.slice(0, 7)}</span>
            <div style={{ display: "flex", gap: 8 }}>
              <span style={{ fontSize: 10, color: C.textFaint }}>{dur(s.duration_ms)}</span>
              <span style={{ fontSize: 10, color: C.textFaint }}>web</span>
            </div>
          </div>
          <div style={{ fontSize: 12, color: C.text, lineHeight: 1.6, marginBottom: 8 }}>
            {s.ai_status === "complete" && s.ai_summary ? (
              s.ai_summary
            ) : IN_PROGRESS_STATUSES.includes(s.ai_status) ? (
              <AIPipelineStatus status={s.ai_status} compact />
            ) : s.ai_status === "failed" ? (
              <AIPipelineStatus status="failed" compact />
            ) : (
              <span style={{ color: C.textFaint }}>Session pending AI analysis…</span>
            )}
          </div>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            {s.ai_tags?.slice(0, 3).map(t => (
              <span key={t} style={{
                fontSize: 10, padding: "2px 6px", borderRadius: 3,
                background: C.bgHover, color: C.textMuted,
              }}>{t}</span>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

// ── Shared ────────────────────────────────────────────────────────────────────

function SectionHeader({ children }) {
  return (
    <div style={{ fontSize: 11, fontWeight: 700, letterSpacing: "0.08em", color: C.textMuted, textTransform: "uppercase", marginBottom: 12, paddingBottom: 8, borderBottom: `1px solid ${C.border}` }}>
      {children}
    </div>
  );
}

// ── App ───────────────────────────────────────────────────────────────────────

// Deep link: ?session=<id>&t=<seconds from the start of the replay>.
function readDeepLink() {
  try {
    const q = new URLSearchParams(window.location.search);
    const t = Number(q.get("t"));
    return { session: q.get("session"), t: Number.isFinite(t) && t > 0 ? t : null };
  } catch {
    return { session: null, t: null };
  }
}

function sessionLink(sessionId, offsetSec) {
  const u = new URL(window.location.href);
  u.search = "";
  u.searchParams.set("session", sessionId);
  if (offsetSec > 0) u.searchParams.set("t", String(Math.floor(offsetSec)));
  return u.toString();
}

export default function App() {
  const deepLink = useRef(readDeepLink()).current;
  const [sessions, setSessions] = useState([]);
  const [issues, setIssues] = useState([]);
  const [selectedSessionId, setSelectedSessionId] = useState(deepLink.session);
  // Where to put the playhead once the selected session's replay is ready.
  const [pendingSeek, setPendingSeek] = useState(deepLink.t ? { kind: "offset", sec: deepLink.t } : null);
  // A linked session that isn't in the loaded list (older than the first page).
  const [linkedSession, setLinkedSession] = useState(null);
  const [activeTab, setActiveTab] = useState("sessions"); // sessions | issues | stream
  const [loading, setLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState("");
  const [stats, setStats] = useState({ total: 0, frustrated: 0, goalMet: 0 });
  const [semanticResults, setSemanticResults] = useState(null); // null = not in semantic search mode
  const [semanticLoading, setSemanticLoading] = useState(false);
  const [semanticError, setSemanticError] = useState(null);

  const fetchSessions = useCallback(async () => {
    try {
      const res = await fetch(`${API}/api/v1/sessions?project_id=${PROJECT_ID}&limit=50`);
      const data = await res.json();
      const list = data.sessions || [];
      setSessions(list);
      setStats({
        total: data.total || list.length,
        frustrated: list.filter(s => s.ai_frustrations?.length > 0).length,
        goalMet: list.filter(s => s.ai_goal_achieved === true).length,
      });
    } catch (e) {
      // Demo mode: show mock data
      const mock = generateMockSessions();
      setSessions(mock);
      setStats({ total: mock.length, frustrated: 2, goalMet: 3 });
    }
    setLoading(false);
  }, []);

  const fetchIssues = useCallback(async () => {
    try {
      const res = await fetch(`${API}/api/v1/issues?project_id=${PROJECT_ID}`);
      const data = await res.json();
      setIssues(data.issues || []);
    } catch (e) {
      setIssues(generateMockIssues());
    }
  }, []);

  useEffect(() => {
    fetchSessions();
    fetchIssues();
    // Frequent enough to feel live while an AI pipeline stage is in flight,
    // without hammering a local dev backend.
    const interval = setInterval(() => { fetchSessions(); fetchIssues(); }, 3000);
    return () => clearInterval(interval);
  }, [fetchSessions, fetchIssues]);

  const handleAnalyze = async (sessionId) => {
    try {
      await fetch(`${API}/api/v1/sessions/${sessionId}/analyze`, { method: "POST" });
      setTimeout(fetchSessions, 500);
    } catch (e) { console.error(e); }
  };

  const handleCreateJira = async (issue) => {
    try {
      await fetch(`${API}/api/v1/jira/issues`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          session_id: issue.session_id,
          issue_id: issue.id,
          summary: issue.title,
          description: issue.description,
          issue_type: issue.type === "bug" ? "Bug" : "Task",
          priority: { P0: "Highest", P1: "High", P2: "Medium", P3: "Low" }[issue.severity] || "Medium",
        }),
      });
      fetchIssues();
    } catch (e) { console.error(e); }
  };

  const handleSemanticSearch = async () => {
    if (!searchQuery.trim()) return;
    setSemanticLoading(true);
    setSemanticError(null);
    try {
      const res = await fetch(`${API}/api/v1/sessions/search?project_id=${PROJECT_ID}&q=${encodeURIComponent(searchQuery)}`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setSemanticResults(data.sessions || []);
    } catch (e) {
      setSemanticError("Semantic search unavailable.");
      setSemanticResults([]);
    }
    setSemanticLoading(false);
  };

  const clearSemanticSearch = () => {
    setSemanticResults(null);
    setSemanticError(null);
  };

  const filteredSessions = sessions.filter(s =>
    !searchQuery ||
    s.url?.includes(searchQuery) ||
    s.ai_summary?.toLowerCase().includes(searchQuery.toLowerCase()) ||
    s.ai_tags?.some(t => t.includes(searchQuery))
  );

  const displayedSessions = semanticResults !== null ? semanticResults : filteredSessions;

  // Look up the live session object by id on every render, rather than
  // holding a frozen snapshot, so the detail panel reflects AI pipeline
  // progress as fetchSessions() polls in fresh data.
  const listedSession =
    sessions.find(s => s.session_id === selectedSessionId) ||
    displayedSessions.find(s => s.session_id === selectedSessionId) ||
    null;
  const selectedSession = listedSession ||
    (linkedSession?.session_id === selectedSessionId ? linkedSession : null);

  // Keep the address bar pointing at the open session, so it can be shared.
  useEffect(() => {
    try {
      const url = selectedSessionId ? sessionLink(selectedSessionId, pendingSeek?.kind === "offset" ? pendingSeek.sec : 0) : window.location.pathname;
      window.history.replaceState(null, "", url);
    } catch { /* non-browser or sandboxed */ }
  }, [selectedSessionId]);

  // Fetch a linked session that the first page of the list doesn't include.
  useEffect(() => {
    if (!selectedSessionId || listedSession || loading || linkedSession?.session_id === selectedSessionId) return;
    let cancelled = false;
    fetch(`${API}/api/v1/sessions/${selectedSessionId}`)
      .then(r => (r.ok ? r.json() : null))
      .then(s => { if (!cancelled && s) setLinkedSession({ ...s, session_id: s.session_id || s.id }); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [selectedSessionId, listedSession, loading]);

  const selectSession = id => {
    setPendingSeek(null);
    setSelectedSessionId(id);
  };

  const openIssue = issue => {
    setActiveTab("sessions");
    setSelectedSessionId(issue.session_id);
    setPendingSeek(issue.moment_ts ? { kind: "abs", ts: issue.moment_ts } : { kind: "issue", id: issue.id });
  };

  return (
    <div style={{
      height: "100vh", display: "flex", flexDirection: "column",
      background: C.bg, color: C.text, fontFamily: "'Inter', -apple-system, sans-serif",
    }}>
      <style>{`
        * { box-sizing: border-box; margin: 0; padding: 0; }
        ::-webkit-scrollbar { width: 4px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: ${C.border}; border-radius: 2px; }
        @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.35} }
        button:hover { opacity: 0.8; }
      `}</style>

      {/* Top Bar */}
      <div style={{
        display: "flex", alignItems: "center", justifyContent: "space-between",
        padding: "0 24px", height: 52, borderBottom: `1px solid ${C.border}`,
        background: C.bg,
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <div style={{ width: 24, height: 24, borderRadius: 6, background: C.ink, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 11, fontWeight: 800, color: "#fff" }}>R</div>
            <span style={{ fontSize: 14, fontWeight: 700, color: C.text }}>ReplayIQ</span>
            <span style={{ fontSize: 11, color: C.textFaint, borderLeft: `1px solid ${C.border}`, paddingLeft: 12, marginLeft: 4 }}>Enterprise</span>
          </div>

          {/* Stats */}
          <div style={{ display: "flex", gap: 20, paddingLeft: 20, borderLeft: `1px solid ${C.border}` }}>
            {[
              ["Sessions", stats.total],
              ["Frustrated", stats.frustrated],
              ["Goal Met", stats.goalMet],
              ["Issues", issues.length],
            ].map(([label, val]) => (
              <div key={label} style={{ display: "flex", gap: 6, alignItems: "center" }}>
                <span style={{ fontSize: 15, fontWeight: 700, color: C.text }}>{val}</span>
                <span style={{ fontSize: 11, color: C.textFaint }}>{label}</span>
              </div>
            ))}
          </div>
        </div>

        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <div style={{ display: "flex", gap: 4 }}>
            {["sessions", "issues", "stream"].map(tab => (
              <button key={tab} onClick={() => setActiveTab(tab)} style={{
                padding: "5px 14px", borderRadius: 5, border: "1px solid",
                borderColor: activeTab === tab ? C.ink : C.border,
                background: activeTab === tab ? C.ink : "transparent",
                color: activeTab === tab ? "#fff" : C.textMuted,
                fontSize: 12, cursor: "pointer", textTransform: "capitalize", fontWeight: 600,
              }}>
                {tab}
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* Main Layout */}
      <div style={{ flex: 1, display: "flex", overflow: "hidden" }}>

        {/* Left: Session List */}
        <div style={{ width: 380, borderRight: `1px solid ${C.border}`, display: "flex", flexDirection: "column" }}>
          <div style={{ padding: "12px 16px", borderBottom: `1px solid ${C.border}` }}>
            <div style={{ display: "flex", gap: 6 }}>
              <input
                value={searchQuery}
                onChange={e => { setSearchQuery(e.target.value); if (semanticResults !== null) clearSemanticSearch(); }}
                onKeyDown={e => { if (e.key === "Enter") handleSemanticSearch(); }}
                placeholder="Search sessions, tags, URLs… (Enter to search by meaning)"
                style={{
                  flex: 1, padding: "8px 12px", borderRadius: 6,
                  border: `1px solid ${C.border}`, background: C.bgSubtle,
                  color: C.text, fontSize: 12, outline: "none",
                }}
              />
              <button
                onClick={handleSemanticSearch}
                disabled={semanticLoading || !searchQuery.trim()}
                title="Search by meaning using AI embeddings"
                style={{
                  padding: "8px 12px", borderRadius: 6, border: `1px solid ${C.borderStrong}`,
                  background: "transparent", color: C.text, fontSize: 12, fontWeight: 700,
                  cursor: semanticLoading || !searchQuery.trim() ? "not-allowed" : "pointer",
                  opacity: semanticLoading || !searchQuery.trim() ? 0.4 : 1,
                }}
              >
                {semanticLoading ? "…" : "≈"}
              </button>
            </div>
            {semanticResults !== null && (
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 8, fontSize: 11, color: C.textMuted }}>
                <span>{semanticError || `${semanticResults.length} result${semanticResults.length === 1 ? "" : "s"} by meaning`}</span>
                <span onClick={clearSemanticSearch} style={{ cursor: "pointer", color: C.textFaint }}>Clear ✕</span>
              </div>
            )}
          </div>
          <div style={{ flex: 1, overflowY: "auto" }}>
            {loading ? (
              <div style={{ padding: 32, textAlign: "center", color: C.textFaint, fontSize: 12 }}>Loading sessions…</div>
            ) : displayedSessions.length === 0 ? (
              <div style={{ padding: 32, textAlign: "center" }}>
                <div style={{ fontSize: 11, color: C.textFaint, marginBottom: 16 }}>No sessions yet.</div>
                <div style={{ background: C.bgSubtle, borderRadius: 8, padding: 16, border: `1px solid ${C.border}`, textAlign: "left" }}>
                  <div style={{ fontSize: 11, color: C.textMuted, marginBottom: 8, fontWeight: 600 }}>INJECT SDK ON ANY SITE</div>
                  <div style={{ fontSize: 10, color: C.textMuted, fontFamily: "monospace", background: C.bgHover, padding: 12, borderRadius: 6, lineHeight: 1.8, wordBreak: "break-all" }}>
                    {`(function(){function createScriptURL(url){if(window.trustedTypes){try{const policy=trustedTypes.getPolicy('replayiq')||trustedTypes.createPolicy('replayiq',{createScriptURL:input=>input});if(policy&&typeof policy.createScriptURL==='function')return policy.createScriptURL(url);}catch(e){}}return url;}var s=document.createElement('script');s.setAttribute('src',createScriptURL('http://localhost:8080/sdk/replayiq.js'));s.onload=function(){ReplayIQ.init({endpoint:'http://localhost:8080',projectId:'demo'});};document.head.appendChild(s);})()`}
                  </div>
                  <div style={{ fontSize: 11, color: C.textFaint, marginTop: 8 }}>Paste in browser console on any tab</div>
                </div>
              </div>
            ) : (
              displayedSessions.map(s => (
                <SessionRow
                  key={s.session_id}
                  session={s}
                  selected={selectedSessionId === s.session_id}
                  onClick={() => selectSession(s.session_id)}
                />
              ))
            )}
          </div>
        </div>

        {/* Right: Detail Panel */}
        <div style={{ flex: 1, overflow: "hidden" }}>
          {activeTab === "sessions" && (
            selectedSession
              ? <SessionDetail
                  session={selectedSession}
                  onAnalyze={handleAnalyze}
                  onCreateJira={handleCreateJira}
                  pendingSeek={pendingSeek}
                  onSeekDone={() => setPendingSeek(null)}
                />
              : <EmptyState />
          )}
          {activeTab === "issues" && (
            <IssuesPanel issues={issues} onCreateJira={handleCreateJira} onOpenIssue={openIssue} />
          )}
          {activeTab === "stream" && (
            <StreamFeed sessions={sessions} />
          )}
        </div>
      </div>
    </div>
  );
}

function EmptyState() {
  return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "center", height: "100%", flexDirection: "column", gap: 12 }}>
      <div style={{ width: 48, height: 48, borderRadius: "50%", border: `2px solid ${C.borderStrong}` }} />
      <div style={{ fontSize: 16, fontWeight: 600, color: C.text }}>Select a session</div>
      <div style={{ fontSize: 13, color: C.textFaint }}>Click any session to view replay and AI analysis</div>
    </div>
  );
}

// ── Mock Data ─────────────────────────────────────────────────────────────────

function generateMockSessions() {
  return [
    {
      session_id: "3a9f2c1d-0001-4abc-beef-000000000001",
      project_id: "demo",
      user_id: "user_abc123",
      url: "https://app.example.com/signup",
      started_at: new Date(Date.now() - 8 * 60000).toISOString(),
      duration_ms: 134000,
      event_count: 87,
      ai_summary: "User abandoned signup at payment step after card-validation error returned twice on the same input.",
      ai_tags: ["form_error", "abandoned", "billing", "payment"],
      ai_goal_achieved: false,
      ai_frustrations: ["Card validation error shown twice without explanation", "Submit button unresponsive after first error"],
      ai_status: "complete",
      created_at: new Date(Date.now() - 8 * 60000).toISOString(),
    },
    {
      session_id: "8b2c47e0-0002-4abc-beef-000000000002",
      project_id: "demo",
      user_id: "user_def456",
      url: "https://app.example.com/pricing",
      started_at: new Date(Date.now() - 22 * 60000).toISOString(),
      duration_ms: 47000,
      event_count: 23,
      ai_summary: "User browsed the demo gallery for under a minute, scrolled to the pricing section, and left before opening any item.",
      ai_tags: ["bounce", "pricing"],
      ai_goal_achieved: false,
      ai_frustrations: [],
      ai_status: "complete",
      created_at: new Date(Date.now() - 22 * 60000).toISOString(),
    },
    {
      session_id: "5e1d09a0-0003-4abc-beef-000000000003",
      project_id: "demo",
      user_id: "user_ghi789",
      url: "https://app.example.com/checkout",
      started_at: new Date(Date.now() - 45 * 60000).toISOString(),
      duration_ms: 242000,
      event_count: 134,
      ai_summary: "User reached checkout, received a 500 error when submitting with promo + gift card combined, then opened support chat.",
      ai_tags: ["error_5xx", "support_handoff", "checkout"],
      ai_goal_achieved: false,
      ai_frustrations: ["500 error on checkout submit", "No error message shown to user"],
      ai_status: "complete",
      created_at: new Date(Date.now() - 45 * 60000).toISOString(),
    },
    {
      session_id: "c4f8b3a1-0004-4abc-beef-000000000004",
      project_id: "demo",
      user_id: "user_jkl012",
      url: "https://app.example.com/dashboard",
      started_at: new Date(Date.now() - 2 * 3600000).toISOString(),
      duration_ms: 380000,
      event_count: 201,
      ai_summary: "Power user session — created 3 reports, exported to CSV, and navigated confidently across all dashboard sections.",
      ai_tags: ["success", "power_user", "export"],
      ai_goal_achieved: true,
      ai_frustrations: [],
      ai_status: "complete",
      created_at: new Date(Date.now() - 2 * 3600000).toISOString(),
    },
    {
      session_id: "d7a2e190-0005-4abc-beef-000000000005",
      project_id: "demo",
      user_id: "user_mno345",
      url: "https://app.example.com/onboarding",
      started_at: new Date(Date.now() - 5 * 3600000).toISOString(),
      duration_ms: 91000,
      event_count: 48,
      ai_summary: "New user completed onboarding but rage-clicked the 'Next' button 4 times on step 3, suggesting a loading delay issue.",
      ai_tags: ["rage_click", "onboarding", "performance"],
      ai_goal_achieved: true,
      ai_frustrations: ["Rage-clicked Next button 4 times on step 3 — likely slow load"],
      ai_status: "complete",
      created_at: new Date(Date.now() - 5 * 3600000).toISOString(),
    },
  ];
}

function generateMockIssues() {
  return [
    {
      id: "issue_001",
      session_id: "3a9f2c1d-0001-4abc-beef-000000000001",
      project_id: "demo",
      type: "bug",
      title: "Card-validation error blocks first-time signup",
      description: "User received duplicate card validation errors on the same input field. The form failed to clear the error state after the first attempt, causing the submit button to become unresponsive.",
      severity: "P1",
      tags: ["form_error", "billing", "signup"],
      jira_key: null,
      created_at: new Date(Date.now() - 5 * 60000).toISOString(),
    },
    {
      id: "issue_002",
      session_id: "5e1d09a0-0003-4abc-beef-000000000003",
      project_id: "demo",
      type: "bug",
      title: "Checkout returns 500 when promo + gift card combined",
      description: "When a user applies both a promo code and a gift card simultaneously, the checkout API returns a 500 with no user-facing error message. The user was left on a broken state with no way to recover.",
      severity: "P0",
      tags: ["checkout", "error_5xx", "payment"],
      jira_key: "ENG-142",
      jira_url: "https://yourcompany.atlassian.net/browse/ENG-142",
      created_at: new Date(Date.now() - 30 * 60000).toISOString(),
    },
    {
      id: "issue_003",
      session_id: "d7a2e190-0005-4abc-beef-000000000005",
      project_id: "demo",
      type: "ux",
      title: "Onboarding step 3 has unacceptable load delay",
      description: "Multiple users rage-clicked the 'Next' button on onboarding step 3. This indicates the step transition is slow (likely waiting on an API call) with no loading indicator shown to the user.",
      severity: "P2",
      tags: ["onboarding", "performance", "rage_click"],
      jira_key: null,
      created_at: new Date(Date.now() - 3 * 3600000).toISOString(),
    },
  ];
}
