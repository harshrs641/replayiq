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

// ── Session Replay Player ────────────────────────────────────────────────────

function SessionReplay({ sessionId, onLoaded, playerApiRef, onTime }) {
  const wrapperRef = useRef(null); // always visible, safe to measure for width
  const containerRef = useRef(null); // hidden until ready, clientWidth would read 0
  const playerRef = useRef(null);
  const [status, setStatus] = useState("loading"); // loading | ready | empty | error
  const [errorMessage, setErrorMessage] = useState("");
  // Defaults to masked - the server stores a redacted copy of every session
  // alongside the raw one (see backend/internal/masking) and serves that by
  // default; flipping this re-fetches the raw, unmasked copy instead.
  const [masked, setMasked] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setStatus("loading");

    (async () => {
      try {
        const res = await fetch(`${API}/api/v1/sessions/${sessionId}/replay?masked=${masked}`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        const all = (data.batches || [])
          .flatMap(b => b.events || [])
          .sort((a, b) => a.timestamp - b.timestamp);
        // Behaviour / console / network tabs read the SDK's metadata events
        // (and Meta events for navigation) before they're stripped below.
        if (!cancelled) onLoaded?.(all);
        const events = all
          // type 5 (Custom) events are the SDK's synthetic network/console/
          // behavior metadata for AI analysis, not real rrweb DOM events.
          // rrweb-player expects Custom events to carry { tag, payload } in
          // `data` and crashes (reading data.tag off undefined) on ones that
          // don't - filter them out, they were never meant to be replayed.
          .filter(e => e.type !== 5);

        if (cancelled) return;

        // rrweb needs a FullSnapshot (type 2) to reconstruct the initial DOM
        // before it can apply incremental mutations on top of it - without
        // one the player can't render anything, regardless of event count.
        if (!events.some(e => e.type === 2)) {
          setStatus("empty");
          setErrorMessage("No full page snapshot was captured for this session (it may predate a fix, or recording was interrupted). Record a new session to replay it.");
          return;
        }

        containerRef.current.innerHTML = "";
        playerRef.current = new RRWebPlayer({
          target: containerRef.current,
          props: { events, width: wrapperRef.current.clientWidth, height: 480, autoPlay: false },
        });
        const player = playerRef.current;
        player.addEventListener?.("ui-update-current-time", e => onTime?.(e.payload));
        if (playerApiRef) {
          playerApiRef.current = {
            // offset is ms from the player's first event
            seek: offset => player.goto(Math.max(0, offset), false),
          };
        }
        setStatus("ready");
      } catch (e) {
        if (!cancelled) {
          console.error("Failed to load replay:", e);
          setErrorMessage(e.message || "Unknown error");
          setStatus("error");
        }
      }
    })();

    return () => {
      cancelled = true;
      playerRef.current?.$destroy?.();
      playerRef.current = null;
      if (playerApiRef) playerApiRef.current = null;
      if (containerRef.current) containerRef.current.innerHTML = "";
    };
  }, [sessionId, masked]);

  return (
    <div ref={wrapperRef} style={{ position: "relative" }}>
      <div style={{ display: "flex", justifyContent: "flex-end", marginBottom: 8 }}>
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
      {/* Player mount point: React only ever sets attributes here, never
          children - rrweb-player owns everything inside it imperatively. */}
      <div ref={containerRef} style={{
        background: C.bgSubtle, borderRadius: 8, border: `1px solid ${C.border}`,
        overflow: "hidden", display: status === "ready" ? "block" : "none",
      }} />
    </div>
  );
}

// ── Behaviour / Console / Network ─────────────────────────────────────────────

function clock(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

// Splits the session's raw events into the three activity lists. Offsets are
// relative to the first replayable (non-Custom) event, which is what
// rrweb-player's timeline starts at, so a row's time matches the scrubber.
function buildActivity(events) {
  const start = events.find(e => e.type !== 5)?.timestamp ?? events[0]?.timestamp ?? 0;
  const behaviour = [], consoleLogs = [], network = [];
  let lastHref = null;
  for (const e of events) {
    const at = e.timestamp - start;
    if (e.type === 4 && e.data?.href && e.data.href !== lastHref) {
      lastHref = e.data.href;
      behaviour.push({ at, kind: "navigate", label: "Navigate", detail: e.data.href });
      continue;
    }
    if (e.type !== 5) continue;
    switch (e.subtype) {
      case "click":
        behaviour.push({ at, kind: "click", label: "Click", detail: e.selector });
        break;
      case "rage_click":
        behaviour.push({ at, kind: "rage_click", label: "Rage click", detail: e.selector, strong: true });
        break;
      case "input":
        behaviour.push({ at, kind: "input", label: "Input", detail: e.selector });
        break;
      case "console":
        consoleLogs.push({ at, level: e.level || "log", message: e.message });
        break;
      case "js_error":
        consoleLogs.push({ at, level: "exception", message: e.message });
        break;
      case "network":
        network.push({ at, method: e.method || "GET", url: e.url, status: e.status, duration: e.duration });
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

function ActivityPanel({ events, currentTime, onSeek }) {
  const [tab, setTab] = useState("behaviour");
  const [errorsOnly, setErrorsOnly] = useState(false);
  const activity = useMemo(() => buildActivity(events || []), [events]);

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
    rows.forEach((r, i) => { if (r.at <= currentTime) activeIdx = i; });
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
                  <tr key={i} onClick={() => onSeek?.(r.at)} title="Jump to this moment in the replay" style={{
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
                      <td style={{ ...cell, ...mono, color: C.text, whiteSpace: "pre-wrap", wordBreak: "break-word" }}>{r.message}</td>
                    </>}
                    {tab === "network" && <>
                      <td style={{ ...cell, ...mono, width: 60, fontWeight: 600, color: C.text }}>{r.method}</td>
                      <td title={r.url} style={{ ...cell, ...mono, color: C.textMuted, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{r.url}</td>
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

function SessionDetail({ session, onAnalyze, onCreateJira }) {
  const [loading, setLoading] = useState(false);
  const [replayEvents, setReplayEvents] = useState(null);
  const [currentTime, setCurrentTime] = useState(null);
  const playerApiRef = useRef(null);
  useEffect(() => { setReplayEvents(null); setCurrentTime(null); }, [session.session_id]);
  const analyzed = session.ai_status === "complete" && session.ai_summary;

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
              {session.ai_frustrations.map((f, i) => (
                <div key={i} style={{ fontSize: 12, color: C.textMuted, marginBottom: 6, paddingLeft: 12, borderLeft: `2px solid ${C.ink}` }}>
                  {f}
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
      <div>
        <SectionHeader>Session Replay</SectionHeader>
        <SessionReplay
          sessionId={session.session_id}
          onLoaded={setReplayEvents}
          onTime={setCurrentTime}
          playerApiRef={playerApiRef}
        />
        <ActivityPanel
          events={replayEvents}
          currentTime={currentTime}
          onSeek={at => playerApiRef.current?.seek(at)}
        />
      </div>
    </div>
  );
}

// ── Issues Panel ──────────────────────────────────────────────────────────────

function IssuesPanel({ issues, onCreateJira }) {
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
                <div style={{ marginTop: 8, fontSize: 11, color: C.textFaint }}>
                  Session: <span style={{ color: C.textMuted, fontFamily: "monospace" }}>{issue.session_id.slice(0, 8)}</span>
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

export default function App() {
  const [sessions, setSessions] = useState([]);
  const [issues, setIssues] = useState([]);
  const [selectedSessionId, setSelectedSessionId] = useState(null);
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
  const selectedSession =
    sessions.find(s => s.session_id === selectedSessionId) ||
    displayedSessions.find(s => s.session_id === selectedSessionId) ||
    null;

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
                  onClick={() => setSelectedSessionId(s.session_id)}
                />
              ))
            )}
          </div>
        </div>

        {/* Right: Detail Panel */}
        <div style={{ flex: 1, overflow: "hidden" }}>
          {activeTab === "sessions" && (
            selectedSession
              ? <SessionDetail session={selectedSession} onAnalyze={handleAnalyze} onCreateJira={handleCreateJira} />
              : <EmptyState />
          )}
          {activeTab === "issues" && (
            <IssuesPanel issues={issues} onCreateJira={handleCreateJira} />
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
