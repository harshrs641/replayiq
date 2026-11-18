'use strict';
/**
 * End-to-end test: synthetic Mixpanel-SDK uploads -> adapter -> mock ReplayIQ.
 * Run:  node --test test.js
 *
 * The payload shapes mirror what mixpanel_flutter_session_replay's
 * RRWebEvent builder emits (Meta=4 with dimension, FullSnapshot=2 with a fake
 * <img> DOM, touch events as MouseInteraction 7/9 and TouchMove source 6,
 * wireframes as Custom=5 tag "mp_wireframe").
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const zlib = require('node:zlib');
const { createAdapter, hitTest, chunkEvents, compactFrame } = require('./adapter');
const { createMock } = require('./mock-replayiq');

const PNG_1PX = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

const meta = (ts) => ({ type: 4, timestamp: ts, data: { discriminator: 'dimension', width: 390, height: 844 } });
const fullSnapshot = (ts) => ({
  type: 2, timestamp: ts,
  data: {
    discriminator: 'node',
    node: {
      type: 0, id: 1, childNodes: [
        { type: 1, name: 'html', publicId: '', systemId: '', id: 2 },
        { type: 2, tagName: 'html', attributes: {}, id: 3, childNodes: [
          { type: 2, tagName: 'head', attributes: {}, id: 4, childNodes: [] },
          { type: 2, tagName: 'body', attributes: {}, id: 25, childNodes: [
            { type: 2, tagName: 'div', attributes: { class: 'screen' }, id: 29, childNodes: [
              { type: 2, tagName: 'img', attributes: { src: `data:image/png;base64,${PNG_1PX}` }, id: 28, childNodes: [] },
            ] },
          ] },
        ] },
      ],
    },
  },
});
const wireframe = (ts, elements) => ({ type: 5, timestamp: ts, data: { tag: 'mp_wireframe', payload: { viewport: [390, 844], elements } } });
const touchStart = (ts, x, y) => ({ type: 3, timestamp: ts, data: { source: 2, type: 7, id: 28, x, y } });
const touchEnd = (ts, x, y) => ({ type: 3, timestamp: ts, data: { source: 2, type: 9, id: 28, x, y } });

const ELEMENTS = [
  { role: 'text', text: 'Checkout', bounds: [40, 120, 200, 30] },
  { role: 'input', text: null, bounds: [40, 300, 310, 44] },
  { role: 'button', text: 'Pay now', bounds: [100, 700, 190, 48] },
  { role: 'text', text: 'Pay now', bounds: [150, 712, 90, 24] },
];

// Mirror of tokenizeEvents() in backend/internal/ai/ollama.go (only the switch we depend on).
function tokenize(events) {
  const out = [];
  for (const e of events) {
    if (e.subtype === 'rage_click') out.push({ action: 'rage_click', target: e.selector });
    else if (e.subtype === 'click') out.push({ action: 'click', target: e.selector });
    else if (e.subtype === 'input') out.push({ action: 'input', target: e.selector });
    else if (e.type === 3) continue;
    else if (e.subtype === 'network') { if (e.status >= 400) out.push({ action: 'network_error', target: e.url }); }
    else if (e.subtype === 'js_error') out.push({ action: 'js_error', target: e.message });
    else if (e.type === 4) out.push({ action: 'navigate', target: e.data && e.data.href });
  }
  return out;
}

async function harness(t, adapterCfg = {}) {
  const mock = createMock();
  await new Promise((r) => mock.server.listen(0, r));
  const adapter = createAdapter({ replayiqUrl: `http://127.0.0.1:${mock.server.address().port}`, idleMs: 150, ...adapterCfg });
  await new Promise((r) => adapter.server.listen(0, r));
  const port = adapter.server.address().port;

  async function upload(events, { replayId = 'rp_test_1', token = 'demo', distinct = 'user_42', seq = 0, gzip = true, raw } = {}) {
    const q = new URLSearchParams({
      format: 'gzip', distinct_id: distinct, seq: String(seq), replay_id: replayId,
      batch_start_time: String(Date.now() / 1000), replay_length_ms: '1000',
      replay_start_time: String(1_800_000_000), $lib_version: '2.1.0', $os: 'Android', mp_lib: 'flutter',
    });
    const json = JSON.stringify(events);
    const body = raw ?? (gzip ? zlib.gzipSync(json) : Buffer.from(json));
    return fetch(`http://127.0.0.1:${port}/mp/record?${q}`, {
      method: 'POST',
      headers: { Authorization: 'Basic ' + Buffer.from(`${token}:`).toString('base64'), 'Content-Type': 'application/octet-stream' },
      body,
    });
  }
  const close = async () => {
    for (const s of [adapter.server, mock.server]) {
      if (s.closeAllConnections) s.closeAllConnections();
      await new Promise((r) => s.close(() => r()));
    }
  };
  t.after(async () => { await adapter.endAll().catch(() => {}); await close(); });
  return { mock, adapter, upload, close, port };
}

const eventsSent = (mock) => mock.calls.filter((c) => c.path === '/api/v1/events').flatMap((c) => c.body.events);

test('creates the session once, with project/user/screen/metadata mapped', async (t) => {
  const h = await harness(t, );
  const t0 = 1_800_000_000_000;
  let res = await h.upload([meta(t0), fullSnapshot(t0 + 5), wireframe(t0 + 10, ELEMENTS)]);
  assert.equal(res.status, 200);
  res = await h.upload([touchStart(t0 + 500, 150, 720)], { seq: 1 });
  assert.equal(res.status, 200);

  const creates = h.mock.calls.filter((c) => c.path === '/api/v1/sessions');
  assert.equal(creates.length, 1, 'session created exactly once');
  const s = creates[0].body;
  assert.equal(creates[0].projectHeader, 'demo');
  assert.equal(s.session_id, 'rp_test_1');
  assert.equal(s.project_id, 'demo');
  assert.equal(s.user_id, 'user_42');
  assert.equal(s.screen_width, 390);
  assert.equal(s.screen_height, 844);
  assert.equal(s.metadata.framework, 'flutter');
  assert.equal(s.metadata.os, 'Android');
  assert.match(s.user_agent, /mixpanel-flutter-session-replay\/2\.1\.0 \(Android\)/);
  assert.equal(new Date(s.started_at).getTime(), 1_800_000_000_000);
  await h.adapter.endAll();
  await h.close();
});

test('forwards rrweb events and adds href to Meta (so the tokenizer sees "navigate")', async (t) => {
  const h = await harness(t, );
  const t0 = 1_800_000_000_000;
  await h.upload([meta(t0), fullSnapshot(t0 + 5), wireframe(t0 + 10, ELEMENTS)]);
  const evs = eventsSent(h.mock);
  assert.ok(evs.some((e) => e.type === 2), 'full snapshot forwarded (dashboard needs it)');
  const m = evs.find((e) => e.type === 4);
  assert.equal(m.data.href, 'app://flutter');
  assert.equal(m.data.width, 390);
  assert.deepEqual(tokenize(evs).filter((t) => t.action === 'navigate'), [{ action: 'navigate', target: 'app://flutter' }]);
  const batch = h.mock.calls.find((c) => c.path === '/api/v1/events').body;
  assert.equal(batch.session_id, 'rp_test_1');
  assert.equal(batch.device_masked, true, 'mobile batches are already masked on the device');
  assert.equal(batch.project_id, 'demo');
  assert.ok(Array.isArray(batch.custom_events));
  await h.adapter.endAll();
  await h.close();
});

test('taps become labelled click events; wireframe state persists across batches', async (t) => {
  const h = await harness(t, );
  const t0 = 1_800_000_000_000;
  await h.upload([meta(t0), fullSnapshot(t0 + 5), wireframe(t0 + 10, ELEMENTS)]);
  // second upload has NO wireframe: label must come from the previous batch
  await h.upload([touchStart(t0 + 1000, 150, 720), touchEnd(t0 + 1050, 150, 720), touchStart(t0 + 3000, 60, 310), touchStart(t0 + 5000, 5, 5)], { seq: 1 });
  const clicks = eventsSent(h.mock).filter((e) => e.subtype === 'click').map((e) => e.selector);
  assert.deepEqual(clicks, ['button:"Pay now"', 'input', 'screen@5,5']);
  assert.equal(eventsSent(h.mock).filter((e) => e.subtype === 'rage_click').length, 0);
  await h.adapter.endAll();
  await h.close();
});

test('three fast taps on one spot => exactly one rage_click', async (t) => {
  const h = await harness(t, );
  const t0 = 1_800_000_000_000;
  await h.upload([meta(t0), fullSnapshot(t0 + 5), wireframe(t0 + 10, ELEMENTS)]);
  await h.upload([touchStart(t0 + 1000, 150, 720), touchStart(t0 + 1200, 152, 721), touchStart(t0 + 1400, 149, 719), touchStart(t0 + 1500, 150, 720)], { seq: 1 });
  const rage = eventsSent(h.mock).filter((e) => e.subtype === 'rage_click');
  assert.equal(rage.length, 1);
  assert.equal(rage[0].selector, 'button:"Pay now"');
  const actions = tokenize(eventsSent(h.mock)).map((t) => t.action);
  assert.ok(actions.includes('rage_click') && actions.includes('click'));
  await h.adapter.endAll();
  await h.close();
});

test('slow taps far apart are not rage', async (t) => {
  const h = await harness(t, );
  const t0 = 1_800_000_000_000;
  await h.upload([meta(t0), wireframe(t0 + 10, ELEMENTS), touchStart(t0 + 1000, 150, 720), touchStart(t0 + 2000, 150, 720), touchStart(t0 + 3000, 150, 720)]);
  assert.equal(eventsSent(h.mock).filter((e) => e.subtype === 'rage_click').length, 0);
  await h.adapter.endAll();
  await h.close();
});

test('idle timeout ends the session with a sane duration (this is what triggers AI analysis)', async (t) => {
  const h = await harness(t, { idleMs: 100 });
  const t0 = 1_800_000_000_000;
  await h.upload([meta(t0), fullSnapshot(t0 + 5), touchStart(t0 + 8000, 10, 10)]);
  await new Promise((r) => setTimeout(r, 400));
  const end = h.mock.calls.find((c) => c.path === '/api/v1/sessions/rp_test_1/end');
  assert.ok(end, 'end call made');
  assert.equal(end.body.duration_ms, 8000);
  assert.equal(end.body.ended_at, new Date(t0 + 8000).toISOString());
  assert.equal(h.adapter.sessions.size, 0);
  await h.close();
});

test('large uploads are split into bounded chunks, in order', async (t) => {
  const h = await harness(t, { maxChunkBytes: 1500 });
  const t0 = 1_800_000_000_000;
  const big = Array.from({ length: 40 }, (_, i) => touchStart(t0 + 100 + i * 2000, 5, 5 + i));
  await h.upload([meta(t0), fullSnapshot(t0 + 5), ...big]);
  const posts = h.mock.calls.filter((c) => c.path === '/api/v1/events');
  assert.ok(posts.length > 3, `expected several chunks, got ${posts.length}`);
  for (const p of posts) assert.ok(Buffer.byteLength(JSON.stringify(p.body.events)) <= 1500 + 800, 'chunk bounded (a chunk may exceed the cap by at most one event)');
  const ts = eventsSent(h.mock).map((e) => e.timestamp);
  assert.deepEqual(ts, [...ts].sort((a, b) => a - b), 'timestamps stay ordered');
  await h.adapter.endAll();
  await h.close();
});

test('rejects unknown tokens when ALLOWED_TOKENS is set, accepts known ones', async (t) => {
  const h = await harness(t, { allowedTokens: ['good'] });
  const t0 = 1_800_000_000_000;
  assert.equal((await h.upload([meta(t0)], { token: 'evil' })).status, 401);
  assert.equal(h.mock.calls.length, 0, 'nothing forwarded');
  assert.equal((await h.upload([meta(t0)], { token: 'good' })).status, 200);
  await h.adapter.endAll();
  await h.close();
});

test('bad payloads => 400; ReplayIQ down => 502 so the SDK retries', async (t) => {
  const h = await harness(t, );
  const t0 = 1_800_000_000_000;
  assert.equal((await h.upload(null, { raw: Buffer.from('not json at all') })).status, 400);
  assert.equal((await h.upload({ not: 'an array' })).status, 400);
  h.mock.state.failEvents = true;
  const res = await h.upload([meta(t0), fullSnapshot(t0 + 5)], { replayId: 'rp_fail' });
  assert.equal(res.status, 502);
  await h.adapter.endAll();
  await h.close();
});

test('uncompressed JSON is also accepted; /settings and /health respond', async (t) => {
  const h = await harness(t, );
  const t0 = 1_800_000_000_000;
  assert.equal((await h.upload([meta(t0)], { gzip: false })).status, 200);
  assert.equal((await fetch(`http://127.0.0.1:${h.port}/mp/settings`)).status, 200);
  assert.equal((await (await fetch(`http://127.0.0.1:${h.port}/health`)).json()).status, 'ok');
  await h.adapter.endAll();
  await h.close();
});

test('hitTest prefers the smallest box, then button over text', () => {
  const wf = { elements: [
    { role: 'text', text: 'Pay now', bounds: [100, 700, 100, 40] },
    { role: 'button', text: 'Pay now', bounds: [100, 700, 100, 40] },
    { role: 'image', text: null, bounds: [0, 0, 390, 844] },
  ] };
  assert.equal(hitTest(wf, 120, 710), 'button:"Pay now"'); // control beats the text drawn on it
  assert.equal(hitTest(wf, 10, 10), 'image');
  assert.equal(hitTest(null, 1, 1), '');
  // control without text borrows the label drawn inside it
  const icon = { elements: [
    { role: 'button', text: null, bounds: [0, 0, 100, 50] },
    { role: 'text', text: 'Save', bounds: [20, 10, 60, 30] },
  ] };
  assert.equal(hitTest(icon, 50, 25), 'button:"Save"');
});

test('chunkEvents keeps an oversized single event rather than dropping it', () => {
  const chunks = chunkEvents([{ a: 'x'.repeat(100) }, { b: 1 }], 10);
  assert.equal(chunks.length, 2);
  assert.equal(chunks[0].length, 1);
});

// ─── Screenshot frame compaction ─────────────────────────────────────────────
const frame = (ts, src, extra = {}) => ({
  type: 2,
  timestamp: ts,
  data: { node: { type: 0, id: 1, childNodes: [{ type: 2, id: 29, tagName: 'div', attributes: { class: 'screen', ...extra }, childNodes: [
    { type: 2, id: 28, tagName: 'img', attributes: { src }, childNodes: [] },
  ] }] } },
});
const freshState = () => ({ frameShape: null, frameSrcs: new Map(), lastKeyframeAt: 0 });

test('first frame stays a FullSnapshot; later frames become an img src mutation', () => {
  const s = freshState();
  assert.equal(compactFrame(frame(1000, 'data:a'), s, 30000).type, 2);
  const m = compactFrame(frame(1250, 'data:b'), s, 30000);
  assert.equal(m.type, 3);
  assert.equal(m.timestamp, 1250);
  assert.deepEqual(m.data, { source: 0, texts: [], attributes: [{ id: 28, attributes: { src: 'data:b' } }], removes: [], adds: [] });
});

test('an identical frame is dropped', () => {
  const s = freshState();
  compactFrame(frame(1000, 'data:a'), s, 30000);
  assert.equal(compactFrame(frame(1250, 'data:a'), s, 30000), null);
});

test('a layout change or the keyframe interval forces a real FullSnapshot', () => {
  const s = freshState();
  compactFrame(frame(1000, 'data:a'), s, 30000);
  assert.equal(compactFrame(frame(1250, 'data:b', { style: 'x' }), s, 30000).type, 2, 'shape changed');
  assert.equal(compactFrame(frame(1500, 'data:c', { style: 'x' }), s, 30000).type, 3);
  assert.equal(compactFrame(frame(31250, 'data:d', { style: 'x' }), s, 30000).type, 2, 'keyframe due');
});

test('end to end: frames become swaps, and every later keyframe gets its own Meta', async (t) => {
  const h = await harness(t, { keyframeMs: 1000 });
  const t0 = 1_800_000_000_000;
  await h.upload([meta(t0), frame(t0 + 5, 'data:a'), frame(t0 + 300, 'data:b'), frame(t0 + 600, 'data:b'), frame(t0 + 1100, 'data:c')]);
  const shape = eventsSent(h.mock).map((e) => [e.type, e.timestamp - t0]);
  assert.deepEqual(shape, [[4, 0], [2, 5], [3, 300], [4, 1100], [2, 1100]]);
  const metas = eventsSent(h.mock).filter((e) => e.type === 4);
  assert.equal(metas[1].data.width, 390, 'keyframe Meta carries the screen size');
  await h.adapter.endAll();
  await h.close();
});

// ── Companion events (console / network / errors / navigation from the app) ──

function companionPost(h, body, { token = 'demo' } = {}) {
  return fetch(`http://127.0.0.1:${h.port}/riq/events`, {
    method: 'POST',
    headers: { Authorization: 'Basic ' + Buffer.from(`${token}:`).toString('base64'), 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

test('companion events join the replay session, filtered to known kinds and fields', async (t) => {
  const h = await harness(t, { allowedTokens: ['demo'] });
  const t0 = 1_800_000_000_000;
  await h.upload([meta(t0), fullSnapshot(t0 + 5)]);
  const res = await companionPost(h, {
    replay_id: 'rp_test_1', distinct_id: 'user_42', os: 'iOS',
    events: [
      { subtype: 'navigate', url: 'app://flutter/order-summary', timestamp: t0 + 1000 },
      { subtype: 'network', method: 'POST', url: 'https://api.test/pay', status: 0, error: 'SocketException', duration: 12, timestamp: t0 + 2000 },
      { subtype: 'js_error', message: 'Bad state', stack: '#0 main', timestamp: t0 + 3000, secret: 'dropped' },
      { subtype: 'rrweb_hack', timestamp: t0 + 4000 },   // unknown kind: dropped
      { subtype: 'console', level: 'log', message: 'no timestamp' }, // dropped
    ],
  });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).accepted, 3);
  assert.equal(h.mock.calls.filter((c) => c.path === '/api/v1/sessions').length, 1, 'reuses the session the screenshots created');
  const post = h.mock.calls.filter((c) => c.path === '/api/v1/events').at(-1).body;
  assert.equal(post.session_id, 'rp_test_1');
  assert.equal(post.device_masked, true);
  const [nav, net, err] = post.events;
  assert.deepEqual(nav, { type: 5, timestamp: t0 + 1000, session_id: 'rp_test_1', subtype: 'navigate', url: 'app://flutter/order-summary' });
  assert.equal(net.error, 'SocketException');
  assert.equal(net.status, 0);
  assert.equal(err.stack, '#0 main');
  assert.equal(err.secret, undefined, 'unknown fields are not forwarded');
});

test('companion events can arrive before any screenshot and create the session', async (t) => {
  const h = await harness(t);
  const res = await companionPost(h, { replay_id: 'rp_new', distinct_id: 'u', events: [{ subtype: 'console', level: 'error', message: 'boom', timestamp: 1_800_000_000_500 }] });
  assert.equal(res.status, 200);
  const create = h.mock.calls.find((c) => c.path === '/api/v1/sessions').body;
  assert.equal(create.session_id, 'rp_new');
  assert.equal(new Date(create.started_at).getTime(), 1_800_000_000_500);
});

test('companion route rejects unknown tokens and malformed bodies', async (t) => {
  const h = await harness(t, { allowedTokens: ['demo'] });
  assert.equal((await companionPost(h, { replay_id: 'x', events: [] }, { token: 'nope' })).status, 401);
  assert.equal((await companionPost(h, { events: [] })).status, 400);
  assert.equal((await companionPost(h, { replay_id: 'x', events: 'no' })).status, 400);
  assert.equal(h.mock.calls.length, 0);
});
