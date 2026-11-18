#!/usr/bin/env node
/**
 * Mixpanel Session Replay SDK  ->  ReplayIQ adapter (proof of concept)
 *
 * The Mixpanel Flutter SDK lets you override its server URL. It then POSTs
 * gzipped rrweb-format event batches to <serverUrl>/record. This adapter
 * pretends to be that endpoint and forwards the data to ReplayIQ's existing
 * public API (/api/v1/sessions, /api/v1/events, /api/v1/sessions/{id}/end),
 * so the Go backend needs no changes.
 *
 * What it does:
 *   - Auth: token = Basic-auth username  -> ReplayIQ project_id
 *   - replay_id -> session_id, distinct_id -> user_id
 *   - gunzips the payload and forwards the rrweb events, in size-bounded chunks
 *   - adds `href` to Meta events (ReplayIQ's tokenizer reads it as "navigate")
 *   - derives ReplayIQ semantic events from touches so the AI has something to read:
 *       touchStart  -> {subtype:"click", selector:'button:"Pay now"'}
 *       3+ fast taps -> {subtype:"rage_click"}
 *     (the element label comes from Mixpanel's wireframe events)
 *   - ends the ReplayIQ session after SESSION_IDLE_MS without batches, which
 *     also triggers ReplayIQ's AI analysis
 *
 * Zero dependencies. Node 18+.
 */
'use strict';

const http = require('http');
const zlib = require('zlib');
const { URL } = require('url');

const DEFAULTS = {
  port: 9090,
  replayiqUrl: 'http://localhost:8080',
  idleMs: 30000,               // no batches for this long => end the session
  maxChunkBytes: 900000,       // keep each ReplayIQ POST well under the 5MB cap / Kafka 1MB default
  maxBodyBytes: 25 * 1024 * 1024,
  allowedTokens: [],           // empty = accept any token (do NOT leave empty on a public tunnel)
  projectId: '',               // optional: force every session into one ReplayIQ project
  href: 'app://flutter',
  rageWindowMs: 700,
  rageRadiusPx: 48,
  rageMinTaps: 3,
  rageCooldownMs: 1000,
  keyframeMs: 30000,           // send a real FullSnapshot at least this often (seek speed); frames in between become img src swaps
  log: () => {},
};

// rrweb numeric constants (same values Mixpanel's SDK uses)
const T_FULL_SNAPSHOT = 2;
const T_INCREMENTAL = 3;
const T_META = 4;
const T_CUSTOM = 5;
const SRC_MUTATION = 0;
const SRC_MOUSE_INTERACTION = 2;
const MOUSE_TOUCH_START = 7;
const WIREFRAME_TAG = 'mp_wireframe';

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new HttpError(413, 'payload too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function basicUser(header) {
  if (!header || !/^Basic /i.test(header)) return '';
  const decoded = Buffer.from(header.slice(6).trim(), 'base64').toString('utf8');
  return decoded.split(':')[0];
}

const isGzip = (b) => b.length > 2 && b[0] === 0x1f && b[1] === 0x8b;

/**
 * Pick what the user tapped. A button/input containing the point wins over the
 * text label inside it (the tap target is the control, not its caption). If a
 * button has no text of its own, borrow the smallest text label drawn inside it.
 */
function hitTest(wireframe, x, y) {
  if (!wireframe || !Array.isArray(wireframe.elements)) return '';
  const hits = [];
  for (const el of wireframe.elements) {
    const b = el && el.bounds;
    if (!Array.isArray(b) || b.length < 4) continue;
    const [l, t, w, h] = b;
    if (x < l || x > l + w || y < t || y > t + h) continue;
    hits.push({ el, area: w * h, l, t, w, h });
  }
  if (!hits.length) return '';
  const smallest = (list) => list.reduce((m, c) => (!m || c.area < m.area ? c : m), null);
  const controls = hits.filter((c) => c.el.role === 'button' || c.el.role === 'input');
  const best = smallest(controls) || smallest(hits);
  let text = best.el.text || '';
  if (!text && best.el.role === 'button') {
    const inside = wireframe.elements
      .filter((o) => o.role === 'text' && o.text && Array.isArray(o.bounds)
        && o.bounds[0] >= best.l && o.bounds[1] >= best.t
        && o.bounds[0] + o.bounds[2] <= best.l + best.w && o.bounds[1] + o.bounds[3] <= best.t + best.h)
      .map((o) => ({ el: o, area: o.bounds[2] * o.bounds[3] }));
    const s = smallest(inside);
    if (s) text = s.el.text;
  }
  return `${best.el.role}${text ? `:${JSON.stringify(text)}` : ''}`;
}

/**
 * Split a Mixpanel screenshot FullSnapshot into its layout and its images.
 * Every frame is the same tiny page (<div class="screen"><img src="data:...">)
 * with only the img src changing, so `shape` (the tree with srcs blanked) is
 * identical frame to frame and `imgs` carries what actually changed.
 */
function frameParts(node) {
  const imgs = [];
  const strip = (n) => {
    if (!n || typeof n !== 'object') return n;
    const out = { ...n };
    if (n.tagName === 'img' && n.attributes && typeof n.attributes.src === 'string') {
      imgs.push({ id: n.id, src: n.attributes.src });
      out.attributes = { ...n.attributes, src: '' };
    }
    if (Array.isArray(n.childNodes)) out.childNodes = n.childNodes.map(strip);
    return out;
  };
  const shape = JSON.stringify(strip(node));
  return { shape, imgs };
}

/**
 * Turn repeated screenshot FullSnapshots into an img src mutation. A
 * FullSnapshot makes rrweb-player tear down and rebuild the whole replay
 * iframe (a visible flash at every frame); a src mutation just swaps the
 * picture. Returns the event to forward, or null to drop an identical frame.
 */
function compactFrame(e, s, keyframeMs) {
  const node = e.data && e.data.node;
  if (!node) return e;
  const { shape, imgs } = frameParts(node);
  const keyframeDue = !s.lastKeyframeAt || e.timestamp - s.lastKeyframeAt >= keyframeMs;
  if (shape !== s.frameShape || keyframeDue || !imgs.length) {
    s.frameShape = shape;
    s.frameSrcs = new Map(imgs.map((i) => [i.id, i.src]));
    s.lastKeyframeAt = e.timestamp;
    return e;
  }
  const changed = imgs.filter((i) => s.frameSrcs.get(i.id) !== i.src);
  if (!changed.length) return null;
  for (const i of changed) s.frameSrcs.set(i.id, i.src);
  return {
    type: T_INCREMENTAL,
    timestamp: e.timestamp,
    data: {
      source: SRC_MUTATION,
      texts: [],
      attributes: changed.map((i) => ({ id: i.id, attributes: { src: i.src } })),
      removes: [],
      adds: [],
    },
  };
}

function chunkEvents(events, maxBytes) {
  const chunks = [];
  let cur = [];
  let size = 0;
  for (const e of events) {
    const n = Buffer.byteLength(JSON.stringify(e));
    if (cur.length && size + n > maxBytes) { chunks.push(cur); cur = []; size = 0; }
    cur.push(e);
    size += n;
  }
  if (cur.length) chunks.push(cur);
  return chunks;
}

function createAdapter(userConfig = {}) {
  const cfg = { ...DEFAULTS, ...userConfig };
  const base = cfg.replayiqUrl.replace(/\/+$/, '');
  const sessions = new Map();

  async function riq(path, body, projectId) {
    let res;
    try {
      res = await fetch(base + path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Project-ID': projectId },
        body: JSON.stringify(body),
      });
    } catch (e) {
      throw new HttpError(502, `ReplayIQ unreachable: ${e.message}`);
    }
    if (!res.ok) throw new HttpError(502, `ReplayIQ ${path} -> HTTP ${res.status}`);
  }

  function stateFor(replayId) {
    let s = sessions.get(replayId);
    if (!s) {
      s = {
        replayId, created: false, projectId: '', userId: '', startedAt: 0, lastTs: 0,
        width: 0, height: 0, wireframe: null, taps: [], lastRageAt: 0, timer: null,
        frameShape: null, frameSrcs: new Map(), lastKeyframeAt: 0,
      };
      sessions.set(replayId, s);
    }
    return s;
  }

  function normalizeMeta(e, s) {
    const d = e.data || {};
    return { ...e, data: { href: cfg.href, ...d, width: d.width || s.width, height: d.height || s.height } };
  }

  function deriveFromTouch(e, s) {
    const x = Number(e.data.x) || 0;
    const y = Number(e.data.y) || 0;
    const ts = e.timestamp;
    const selector = hitTest(s.wireframe, x, y) || `screen@${Math.round(x)},${Math.round(y)}`;
    const out = [{ type: T_CUSTOM, subtype: 'click', selector, timestamp: ts, session_id: s.replayId }];

    s.taps.push({ x, y, t: ts });
    s.taps = s.taps.filter((t) => ts - t.t <= cfg.rageWindowMs);
    const near = s.taps.filter((t) => Math.hypot(t.x - x, t.y - y) <= cfg.rageRadiusPx);
    if (near.length >= cfg.rageMinTaps && ts - s.lastRageAt > cfg.rageCooldownMs) {
      s.lastRageAt = ts;
      out.push({ type: T_CUSTOM, subtype: 'rage_click', x, y, selector, timestamp: ts, session_id: s.replayId });
    }
    return out;
  }

  // Creates the ReplayIQ session on first sight of a replay_id, from either
  // the SDK's screenshots or the companion's events (whichever lands first).
  async function ensureSession(s, meta, events) {
    s.projectId = meta.projectId;
    s.userId = meta.distinctId || s.userId || 'anonymous';
    if (!s.startedAt) {
      const firstTs = events.reduce((m, e) => (e.timestamp && (!m || e.timestamp < m) ? e.timestamp : m), 0);
      s.startedAt = meta.startedAtMs || firstTs || Date.now();
    }
    if (!s.created) {
      await riq('/api/v1/sessions', {
        session_id: s.replayId,
        user_id: s.userId,
        project_id: s.projectId,
        url: cfg.href,
        user_agent: `mixpanel-flutter-session-replay/${meta.libVersion || 'unknown'} (${meta.os || 'mobile'})`,
        screen_width: s.width,
        screen_height: s.height,
        sdk_version: 'mixpanel-adapter-poc/0.1',
        metadata: { platform: 'mobile', framework: 'flutter', os: meta.os || '', source: 'mixpanel-sdk', lib_version: meta.libVersion || '' },
        started_at: new Date(s.startedAt).toISOString(),
      }, s.projectId);
      s.created = true;
    }
  }

  function armIdleTimer(s) {
    clearTimeout(s.timer);
    s.timer = setTimeout(() => endSession(s.replayId).catch((e) => cfg.log('end failed', e.message)), cfg.idleMs);
    if (s.timer.unref) s.timer.unref();
  }

  async function processBatch(meta, events) {
    const s = stateFor(meta.replayId);
    clearTimeout(s.timer);
    for (const e of events) {
      if (e.type === T_META && e.data && e.data.width) { s.width = e.data.width; s.height = e.data.height; }
    }
    await ensureSession(s, meta, events);

    const ordered = events
      .map((e, i) => [e, i])
      .sort((a, b) => ((a[0].timestamp || 0) - (b[0].timestamp || 0)) || (a[1] - b[1]))
      .map(([e]) => e);

    const out = [];
    for (const e of ordered) {
      if (e.timestamp > s.lastTs) s.lastTs = e.timestamp;
      if (e.type === T_META) { out.push(normalizeMeta(e, s)); continue; }
      if (e.type === T_CUSTOM && e.data && e.data.tag === WIREFRAME_TAG) {
        s.wireframe = e.data.payload || null;
        out.push(e);
        continue;
      }
      if (e.type === T_FULL_SNAPSHOT) {
        const hadKeyframe = Boolean(s.lastKeyframeAt);
        const frame = compactFrame(e, s, cfg.keyframeMs);
        if (!frame) continue;
        // rrweb seeks from the last Meta event, and the SDK sends only one, at
        // the start. Without a Meta here, seeking past a later keyframe replays
        // the src swaps and then rebuilds the page mid-seek, which throws
        // inside rrweb-player. rrweb's own checkouts emit Meta + FullSnapshot
        // the same way.
        const prev = out[out.length - 1];
        if (frame.type === T_FULL_SNAPSHOT && hadKeyframe && !(prev && prev.type === T_META)) {
          out.push(normalizeMeta({ type: T_META, timestamp: frame.timestamp, data: {} }, s));
        }
        out.push(frame);
        continue;
      }
      out.push(e);
      if (e.type === T_INCREMENTAL && e.data && e.data.source === SRC_MOUSE_INTERACTION && e.data.type === MOUSE_TOUCH_START) {
        out.push(...deriveFromTouch(e, s));
      }
    }

    for (const chunk of chunkEvents(out, cfg.maxChunkBytes)) {
      await riq('/api/v1/events', {
        session_id: s.replayId,
        project_id: s.projectId,
        events: chunk,
        custom_events: [],
        flushed_at: new Date().toISOString(),
        // The SDK masks pixels on the phone; ReplayIQ's text masking can't
        // redact pixels, so it skips the second (masked) copy.
        device_masked: true,
      }, s.projectId);
    }

    armIdleTimer(s);
    cfg.log(`batch ok replay=${s.replayId} in=${events.length} out=${out.length}`);
  }

  // Console, network, error and navigation events from the app (the Flutter
  // companion in flutter_poc/lib/replayiq_companion.dart), in the web SDK's
  // shapes. The Mixpanel SDK doesn't record these; the companion tags them
  // with the SDK's replay id so they land in the same session.
  const COMPANION_SUBTYPES = new Set(['console', 'network', 'js_error', 'navigate']);
  const COMPANION_FIELDS = ['subtype', 'level', 'message', 'url', 'status', 'method', 'duration', 'filename', 'lineno', 'colno', 'stack', 'error'];

  async function handleCompanion(req, res) {
    const token = basicUser(req.headers.authorization);
    if (cfg.allowedTokens.length && !cfg.allowedTokens.includes(token)) throw new HttpError(401, 'unknown token');
    const body = await readBody(req, cfg.maxBodyBytes);
    let payload;
    try {
      payload = JSON.parse((isGzip(body) ? zlib.gunzipSync(body) : body).toString('utf8'));
    } catch (e) {
      throw new HttpError(400, `invalid payload: ${e.message}`);
    }
    const replayId = payload && typeof payload.replay_id === 'string' ? payload.replay_id : '';
    if (!replayId) throw new HttpError(400, 'replay_id is required');
    if (!Array.isArray(payload.events)) throw new HttpError(400, 'events must be an array');

    // Only known event kinds and fields pass through.
    const events = payload.events
      .filter((e) => e && COMPANION_SUBTYPES.has(e.subtype) && Number.isFinite(e.timestamp))
      .map((e) => {
        const out = { type: T_CUSTOM, timestamp: Math.round(e.timestamp), session_id: replayId };
        for (const k of COMPANION_FIELDS) if (e[k] !== undefined && e[k] !== null) out[k] = e[k];
        return out;
      });
    if (events.length) {
      const s = stateFor(replayId);
      clearTimeout(s.timer);
      await ensureSession(s, {
        replayId,
        projectId: cfg.projectId || token || 'mobile',
        distinctId: typeof payload.distinct_id === 'string' ? payload.distinct_id : '',
        os: typeof payload.os === 'string' ? payload.os : '',
      }, events);
      s.lastTs = Math.max(s.lastTs || 0, ...events.map((e) => e.timestamp));
      for (const chunk of chunkEvents(events, cfg.maxChunkBytes)) {
        await riq('/api/v1/events', {
          session_id: replayId,
          project_id: s.projectId,
          events: chunk,
          custom_events: [],
          flushed_at: new Date().toISOString(),
          // Same session as the screenshots, which are masked on the phone;
          // ReplayIQ still redacts these events' text fields.
          device_masked: true,
        }, s.projectId);
      }
      armIdleTimer(s);
      cfg.log(`companion ok replay=${replayId} events=${events.length}`);
    }
    send(res, 200, { status: 'ok', accepted: events.length });
  }

  async function endSession(replayId) {
    const s = sessions.get(replayId);
    if (!s) return;
    clearTimeout(s.timer);
    sessions.delete(replayId);
    const endedAt = s.lastTs || Date.now();
    await riq(`/api/v1/sessions/${encodeURIComponent(replayId)}/end`, {
      ended_at: new Date(endedAt).toISOString(),
      duration_ms: Math.max(0, endedAt - s.startedAt),
    }, s.projectId);
    cfg.log(`session ended replay=${replayId}`);
  }

  async function endAll() {
    await Promise.all([...sessions.keys()].map((id) => endSession(id).catch(() => {})));
  }

  async function handleRecord(req, res, url) {
    const token = basicUser(req.headers.authorization);
    if (cfg.allowedTokens.length && !cfg.allowedTokens.includes(token)) throw new HttpError(401, 'unknown token');
    const q = url.searchParams;
    const replayId = q.get('replay_id');
    if (!replayId) throw new HttpError(400, 'replay_id is required');

    const body = await readBody(req, cfg.maxBodyBytes);
    let events;
    try {
      const raw = isGzip(body) ? zlib.gunzipSync(body) : body;
      events = JSON.parse(raw.toString('utf8'));
    } catch (e) {
      throw new HttpError(400, `invalid payload: ${e.message}`);
    }
    if (!Array.isArray(events)) throw new HttpError(400, 'payload must be a JSON array of rrweb events');

    if (events.length) {
      const startSec = parseFloat(q.get('replay_start_time'));
      await processBatch({
        replayId,
        projectId: cfg.projectId || token || 'mobile',
        distinctId: q.get('distinct_id') || '',
        os: q.get('$os') || '',
        libVersion: q.get('$lib_version') || '',
        startedAtMs: Number.isFinite(startSec) ? Math.round(startSec * 1000) : 0,
      }, events);
    }
    send(res, 200, { status: 'ok' });
  }

  function send(res, status, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
    res.end(body);
  }

  const server = http.createServer(async (req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    try {
      const url = new URL(req.url, 'http://adapter.local');
      const path = url.pathname.replace(/\/+$/, '');
      if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
      if (req.method === 'GET' && path.endsWith('/health')) return send(res, 200, { status: 'ok', active_sessions: sessions.size });
      if (req.method === 'GET' && path.endsWith('/settings')) return send(res, 200, {});
      if (req.method === 'POST' && path.endsWith('/record')) return await handleRecord(req, res, url);
      if (req.method === 'POST' && path.endsWith('/riq/events')) return await handleCompanion(req, res);
      send(res, 404, { error: 'not found' });
    } catch (e) {
      const status = e instanceof HttpError ? e.status : 500;
      cfg.log(`error ${status}: ${e.message}`);
      send(res, status, { error: e.message });
    }
  });

  return { server, sessions, endSession, endAll };
}

module.exports = { createAdapter, hitTest, chunkEvents, compactFrame };

if (require.main === module) {
  const env = process.env;
  const adapter = createAdapter({
    port: Number(env.PORT) || DEFAULTS.port,
    replayiqUrl: env.REPLAYIQ_URL || DEFAULTS.replayiqUrl,
    idleMs: Number(env.SESSION_IDLE_MS) || DEFAULTS.idleMs,
    maxChunkBytes: Number(env.MAX_CHUNK_BYTES) || DEFAULTS.maxChunkBytes,
    keyframeMs: Number(env.KEYFRAME_MS) || DEFAULTS.keyframeMs,
    allowedTokens: (env.ALLOWED_TOKENS || '').split(',').map((t) => t.trim()).filter(Boolean),
    projectId: env.PROJECT_ID || '',
    log: (...a) => console.log(new Date().toISOString(), ...a),
  });
  const port = Number(env.PORT) || DEFAULTS.port;
  adapter.server.listen(port, () => {
    console.log(`mixpanel->replayiq adapter on :${port}  (ReplayIQ: ${env.REPLAYIQ_URL || DEFAULTS.replayiqUrl})`);
    if (!env.ALLOWED_TOKENS) console.log('WARNING: ALLOWED_TOKENS not set; any token is accepted. Set it before exposing this via a tunnel.');
  });
  const shutdown = async () => { await adapter.endAll(); process.exit(0); };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}
