/*!
 * ReplayIQ web SDK
 * Implements the ReplayIQ Recording API v1 (docs/sdk/recording-api-v1.md).
 */

// Replaced at build time (build.mjs).
/* global __SDK_VERSION__, __UMD__ */
const SDK_VERSION = typeof __SDK_VERSION__ !== 'undefined' ? __SDK_VERSION__ : 'dev';
const SDK_NAME = `replayiq-web/${SDK_VERSION}`;

const BATCH_SIZE = 50;
const FLUSH_INTERVAL_MS = 5000;
// Recording pauses (rrweb stops observing the DOM) after a tab has been
// hidden this long, or nobody has interacted for this long, and resumes
// with a fresh snapshot when the user is back. Both configurable.
const PAUSE_WHEN_HIDDEN_MS = 60 * 1000;
const PAUSE_WHEN_IDLE_MS = 10 * 60 * 1000;
const ACTIVITY_EVENTS = ['mousemove', 'mousedown', 'keydown', 'scroll', 'touchstart', 'wheel'];
// Unsent batches kept while the server is unreachable (oldest dropped).
const MAX_QUEUED_EVENTS = 1000;
const MAX_BACKOFF_MS = 60 * 1000;
// Chromium refuses keepalive request bodies over 64 KiB.
const KEEPALIVE_MAX_BYTES = 60000;
// rrweb's numeric event types: FullSnapshot=2, IncrementalSnapshot=3, Meta=4,
// Custom=5. SDK events are Custom with a `subtype`.
const EVENT_TYPE_CUSTOM = 5;

// ─── Storage helpers (never throw: storage can be blocked) ────────────────────
function store(kind) {
  try { return kind === 'local' ? window.localStorage : window.sessionStorage; } catch (e) { return null; }
}
function getItem(kind, key) {
  try { return store(kind)?.getItem(key) ?? null; } catch (e) { return null; }
}
function setItem(kind, key, value) {
  try { store(kind)?.setItem(key, value); } catch (e) { /* ignore */ }
}
function removeItem(kind, key) {
  try { store(kind)?.removeItem(key); } catch (e) { /* ignore */ }
}

function generateId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

function getOrCreate(kind, key) {
  let v = getItem(kind, key);
  if (!v) { v = generateId(); setItem(kind, key, v); }
  return v;
}

// Sampling is decided once per session (not per page load), so a sampled
// session is recorded on every page and an unsampled one on none.
function isSessionSampled(rate) {
  const saved = getItem('session', '__riq_sampled');
  if (saved === '1' || saved === '0') return saved === '1';
  const sampled = Math.random() < rate;
  setItem('session', '__riq_sampled', sampled ? '1' : '0');
  return sampled;
}

// Batch sequence for the session, shared by its page loads, so batch ids
// stay unique (the server stores a batch under its id).
function nextBatchId(sessionId) {
  const n = Number(getItem('session', '__riq_seq') || 0) + 1;
  setItem('session', '__riq_seq', String(n));
  return `${sessionId}-${String(n).padStart(6, '0')}-${Math.random().toString(36).slice(2, 6)}`;
}

function createScriptURL(url) {
  if (typeof trustedTypes !== 'undefined' && trustedTypes) {
    try {
      const policy = (typeof trustedTypes.getPolicy === 'function' ? trustedTypes.getPolicy('replayiq') : null)
        || trustedTypes.createPolicy('replayiq', { createScriptURL: input => input });
      if (policy && typeof policy.createScriptURL === 'function') return policy.createScriptURL(url);
    } catch (err) { /* fall back to the raw URL */ }
  }
  return url;
}

function loadScript(url) {
  return new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.setAttribute('src', createScriptURL(url));
    script.onload = resolve;
    script.onerror = () => reject(new Error('Failed to load ' + url));
    document.head.appendChild(script);
  });
}

// The CDN/script-tag build loads rrweb from next to itself (same host, same
// version), so pages need no third-party script host in their CSP.
const scriptBase = (() => {
  try {
    const src = document.currentScript && document.currentScript.src;
    return src ? src.slice(0, src.lastIndexOf('/') + 1) : '';
  } catch (e) { return ''; }
})();

function loadRecorder(config) {
  if (typeof window !== 'undefined' && window.rrweb && window.rrweb.record) return Promise.resolve(window.rrweb);
  if (typeof __UMD__ !== 'undefined' && __UMD__) {
    const url = config.rrwebUrl || (scriptBase ? scriptBase + 'rrweb.min.js' : '');
    if (!url) return Promise.reject(new Error('rrwebUrl is required when the SDK is not loaded from a script tag'));
    return loadScript(url).then(() => window.rrweb);
  }
  // npm build: the app's bundler splits rrweb into its own chunk.
  return import('rrweb');
}

// Runs fn once the page has loaded and the browser is idle, so loading and
// starting the recorder never competes with the page's own startup.
function whenIdle(fn) {
  const idle = () => (window.requestIdleCallback ? window.requestIdleCallback(fn, { timeout: 2000 }) : setTimeout(fn, 1));
  if (document.readyState === 'complete') idle();
  else window.addEventListener('load', idle, { once: true });
}

async function gzip(text) {
  if (typeof CompressionStream === 'undefined') return null;
  try {
    const stream = new Blob([text]).stream().pipeThrough(new CompressionStream('gzip'));
    return new Uint8Array(await new Response(stream).arrayBuffer());
  } catch (e) {
    return null;
  }
}

// ─── PII Masking ─────────────────────────────────────────────────────────────
const PII_SELECTORS = [
  'input[type="password"]',
  'input[type="email"]',
  'input[name*="card"]',
  'input[name*="cvv"]',
  'input[name*="ssn"]',
  'input[name*="phone"]',
  '[data-riq-mask]',
];

function buildBlockClass(custom = []) {
  // rrweb's blockClass option only accepts a string or a RegExp, not an
  // array, so multiple class names have to be combined into one RegExp.
  const classes = ['riq-mask', ...custom];
  return classes.length === 1
    ? classes[0]
    : new RegExp(classes.map(c => c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'));
}

// ─── Network Capture ─────────────────────────────────────────────────────────
function interceptNetwork(onEvent, isOwnRequest) {
  const origFetch = window.fetch;
  const origXHR = window.XMLHttpRequest.prototype.open;

  window.fetch = async function (...args) {
    const start = Date.now();
    const url = typeof args[0] === 'string' ? args[0] : args[0]?.url;
    const method = args[1]?.method || args[0]?.method || 'GET';
    if (isOwnRequest(url)) return origFetch.apply(this, args);
    try {
      const res = await origFetch.apply(this, args);
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'network', method, url, status: res.status, duration: Date.now() - start, timestamp: Date.now() });
      return res;
    } catch (err) {
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'network', method, url, status: 0, error: err.message, duration: Date.now() - start, timestamp: Date.now() });
      throw err;
    }
  };

  window.XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    this._riq_method = method;
    this._riq_url = url;
    this._riq_start = Date.now();
    if (!isOwnRequest(String(url))) {
      this.addEventListener('loadend', () => {
        onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'network', method: this._riq_method, url: this._riq_url, status: this.status, duration: Date.now() - this._riq_start, timestamp: Date.now() });
      });
    }
    return origXHR.apply(this, [method, url, ...rest]);
  };
}

// ─── Console / error capture ─────────────────────────────────────────────────
function stackOf(err) {
  // Stacks can be long (minified bundles); keep enough to locate the frame.
  return err && typeof err.stack === 'string' ? err.stack.slice(0, 4000) : undefined;
}

function interceptConsole(onEvent) {
  ['error', 'warn'].forEach(level => {
    const orig = console[level].bind(console);
    console[level] = function (...args) {
      const err = args.find(a => a instanceof Error);
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'console', level, message: args.map(String).join(' '), stack: stackOf(err), timestamp: Date.now() });
      orig(...args);
    };
  });
  window.addEventListener('error', e => {
    onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'js_error', message: e.message, filename: e.filename, lineno: e.lineno, colno: e.colno, stack: stackOf(e.error), timestamp: Date.now() });
  });
  window.addEventListener('unhandledrejection', e => {
    const r = e.reason;
    onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'js_error', message: 'Unhandled rejection: ' + (r && r.message ? r.message : String(r)), stack: stackOf(r), timestamp: Date.now() });
  });
}

// ─── Clicks, rage clicks, inputs, navigation ─────────────────────────────────
function getSelector(el) {
  if (!el || !el.tagName || el === document.body) return 'body';
  const id = el.id ? `#${el.id}` : '';
  const cls = el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.') : '';
  return `${el.tagName.toLowerCase()}${id}${cls === '.' ? '' : cls}`;
}

function detectBehaviors(onEvent) {
  const clicks = [];
  document.addEventListener('click', e => {
    const now = Date.now();
    clicks.push({ t: now, target: e.target });
    // rrweb's own click events only carry a node id; the selector is what
    // the dashboard and the AI analysis can read.
    onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'click', selector: getSelector(e.target), timestamp: now });
    const recent = clicks.filter(c => now - c.t < 700 && c.target === e.target);
    if (recent.length >= 3) {
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'rage_click', x: e.clientX, y: e.clientY, selector: getSelector(e.target), timestamp: now });
    }
    if (clicks.length > 10) clicks.shift();
  }, true);
  document.addEventListener('input', e => {
    onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'input', selector: getSelector(e.target), timestamp: Date.now() });
  }, true);
}

// Single-page apps change the URL without a page load; report each change.
function watchNavigation(onEvent) {
  let last = location.href;
  const check = () => {
    if (location.href === last) return;
    last = location.href;
    onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'navigate', url: last, message: document.title, timestamp: Date.now() });
  };
  for (const m of ['pushState', 'replaceState']) {
    const orig = history[m];
    history[m] = function (...args) {
      const r = orig.apply(this, args);
      check();
      return r;
    };
  }
  window.addEventListener('popstate', check);
  window.addEventListener('hashchange', check);
}

// ─── Core ────────────────────────────────────────────────────────────────────
class ReplayIQSDK {
  constructor(config) {
    const key = config.key || config.projectId;
    this.config = {
      endpoint: (config.endpoint || 'http://localhost:8080').replace(/\/+$/, ''),
      key,
      projectId: config.projectId || '',
      sampleRate: config.sampleRate ?? 1.0,
      maskSelectors: config.maskSelectors || [],
      pauseWhenHiddenMs: config.pauseWhenHiddenMs ?? PAUSE_WHEN_HIDDEN_MS,
      pauseWhenIdleMs: config.pauseWhenIdleMs ?? PAUSE_WHEN_IDLE_MS,
      rrwebUrl: config.rrwebUrl,
      debug: !!config.debug,
      metadata: config.metadata || {},
    };
    this.sessionId = getOrCreate('session', '__riq_sid');
    this.userId = getItem('local', '__riq_user') || getOrCreate('local', '__riq_uid');
    this.events = [];
    this.customEvents = [];   // track() calls
    this.queue = [];          // unsent batches: { id, events }
    this.sending = false;
    this.backoffMs = 0;
    this.stopped = false;     // 401/403, opt-out or stop()
    this.stopFn = null;
    this.flushTimer = null;
    this.sessionStarted = Date.now();
    this.sampled = false;
    this.rrweb = null;
    this.paused = false;
    // Callers (e.g. a browser extension running this in a page with a
    // restrictive CSP) can supply their own transport. It returns a
    // promise of a Response (or of nothing, when the status is unknown).
    this.transport = typeof config.transport === 'function'
      ? config.transport
      : (url, options) => fetch(url, options);
  }

  log(...args) {
    if (this.config.debug) console.log('[ReplayIQ]', ...args);
  }

  getSessionId() {
    return this.sessionId;
  }

  identify(userId, traits = {}) {
    this.userId = String(userId);
    setItem('local', '__riq_user', this.userId);
    this.config.metadata = { ...this.config.metadata, ...traits };
    this.log('Identified user:', userId);
  }

  track(name, properties = {}) {
    if (this.stopped || !this.sampled) return;
    this.customEvents.push({ name: String(name), properties, timestamp: Date.now() });
  }

  _headers(extra = {}) {
    const h = { 'Content-Type': 'application/json', Authorization: `Bearer ${this.config.key}`, ...extra };
    if (this.config.projectId) h['X-Project-ID'] = this.config.projectId; // servers before API v1
    return h;
  }

  _post(path, body, { keepalive = false } = {}) {
    return this.transport(`${this.config.endpoint}${path}`, {
      method: 'POST',
      headers: this._headers(),
      body: JSON.stringify(body),
      keepalive,
    });
  }

  _isOwnRequest(url) {
    return typeof url === 'string' && url.startsWith(this.config.endpoint + '/api/');
  }

  _push(e) {
    if (this.stopped) return;
    this.events.push({ ...e, session_id: this.sessionId });
    if (this.events.length >= BATCH_SIZE) this._flush();
  }

  _initSession() {
    this._post('/api/v1/sessions', {
      session_id: this.sessionId,
      user_id: this.userId,
      project_id: this.config.projectId || undefined,
      url: location.href,
      user_agent: navigator.userAgent,
      screen_width: screen.width,
      screen_height: screen.height,
      sdk_version: SDK_NAME,
      metadata: { platform: 'web', ...this.config.metadata },
      started_at: new Date(this.sessionStarted).toISOString(),
    }, { keepalive: true }).catch(e => this.log('Session init error:', e));
  }

  // Moves buffered events into the send queue and sends it. With
  // `unloading`, sends synchronously-started keepalive requests instead
  // (the page may be gone before anything async runs).
  _flush(unloading = false) {
    if (this.events.length || this.customEvents.length) {
      this.queue.push({ id: nextBatchId(this.sessionId), events: this.events, custom: this.customEvents });
      this.events = [];
      this.customEvents = [];
      let total = this.queue.reduce((n, b) => n + b.events.length, 0);
      while (total > MAX_QUEUED_EVENTS && this.queue.length > 1) total -= this.queue.shift().events.length;
    }
    if (unloading) {
      for (const b of this.queue) this._sendBatch(b, true).catch(() => {});
      this.queue = [];
      return;
    }
    this._drain();
  }

  async _drain() {
    if (this.sending || this.stopped || this.backoffMs) return;
    this.sending = true;
    try {
      while (this.queue.length && !this.stopped) {
        const batch = this.queue[0];
        const result = await this._sendBatch(batch, false);
        if (result === 'retry') {
          this.backoffMs = Math.min(Math.max(this.backoffMs * 2, 1000), MAX_BACKOFF_MS);
          setTimeout(() => { this.backoffMs = 0; this._drain(); }, this.backoffMs);
          break;
        }
        this.queue.shift();
        if (result === 'split' && batch.events.length > 1) {
          const half = Math.ceil(batch.events.length / 2);
          this.queue.unshift(
            { id: nextBatchId(this.sessionId), events: batch.events.slice(0, half) },
            { id: nextBatchId(this.sessionId), events: batch.events.slice(half) },
          );
        }
      }
    } finally {
      this.sending = false;
    }
  }

  // Returns 'ok', 'drop', 'split' or 'retry' (recording API v1 errors).
  async _sendBatch(batch, unloading) {
    const json = JSON.stringify({
      session_id: this.sessionId,
      project_id: this.config.projectId || undefined,
      batch_id: batch.id,
      platform: 'web',
      sdk: SDK_NAME,
      events: batch.events,
      custom_events: batch.custom || [],
      flushed_at: new Date().toISOString(),
    });
    let body = json;
    let headers = this._headers();
    if (!unloading && json.length > 1024) {
      const zipped = await gzip(json);
      if (zipped) { body = zipped; headers = this._headers({ 'Content-Encoding': 'gzip' }); }
    }
    const size = typeof body === 'string' ? body.length : body.byteLength;
    let res;
    try {
      res = await this.transport(`${this.config.endpoint}/api/v1/events`, {
        method: 'POST', headers, body, keepalive: unloading && size < KEEPALIVE_MAX_BYTES,
      });
    } catch (e) {
      this.log('Flush error:', e);
      return 'retry';
    }
    const status = res && typeof res.status === 'number' ? res.status : 202;
    if (status < 300) return 'ok';
    if (status === 401 || status === 403) {
      this.log('Ingest key rejected; recording stopped.');
      this._halt();
      return 'drop';
    }
    if (status === 413) return 'split';
    if (status === 429 || status >= 500) return 'retry';
    this.log(`Batch rejected (HTTP ${status}); dropped.`);
    return 'drop';
  }

  _startFlushLoop() {
    this.flushTimer = setInterval(() => this._flush(), FLUSH_INTERVAL_MS);
    // Hidden tabs are often never unloaded properly (mobile browsers kill
    // them without beforeunload): send what we have when the tab hides.
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') this._flush();
    });
    window.addEventListener('pagehide', () => {
      if (this.stopped) return;
      this._flush(true);
      this._post(`/api/v1/sessions/${this.sessionId}/end`, {
        ended_at: new Date().toISOString(), duration_ms: Date.now() - this.sessionStarted,
      }, { keepalive: true }).catch(() => {});
    });
  }

  // Starts the session: network/console/behaviour capture right away, and
  // the DOM recorder (rrweb) once the page is idle. Returns false when this
  // session isn't sampled, or the user opted out: nothing is recorded or
  // downloaded then.
  start() {
    if (getItem('local', '__riq_optout') === '1') {
      this.log('User opted out; not recording.');
      return false;
    }
    this.sampled = isSessionSampled(this.config.sampleRate);
    if (!this.sampled) {
      this.log('Session not sampled, skipping.');
      return false;
    }
    this._initSession();
    this._startFlushLoop();
    const push = e => this._push(e);
    interceptNetwork(push, url => this._isOwnRequest(url));
    interceptConsole(push);
    detectBehaviors(push);
    watchNavigation(push);
    this._watchActivity();
    whenIdle(() => {
      loadRecorder(this.config)
        .then(rrweb => { this.rrweb = rrweb; this._record(); })
        .catch(e => this.log('Recorder failed to load:', e));
    });
    this.log(`Session started: ${this.sessionId}`);
    return true;
  }

  _record() {
    if (!this.rrweb || this.stopFn || this.paused || this.stopped) return;
    this.stopFn = this.rrweb.record({
      emit: event => {
        this.events.push(event);
        if (this.events.length >= BATCH_SIZE) this._flush();
      },
      blockClass: buildBlockClass(this.config.maskSelectors),
      maskInputOptions: { password: true, email: false },
      maskInputSelector: PII_SELECTORS.join(','),
      collectFonts: true,
      recordCanvas: false,
      // Keyframes (Meta + FullSnapshot) that replay can start from: at
      // least every 30 s of activity, so a seek replays at most that.
      checkoutEveryNth: 200,
      checkoutEveryNms: 30000,
    });
  }

  // Stops observing the DOM (a hidden or abandoned tab can keep mutating
  // it: tickers, timers, polling). Resuming starts with a full snapshot.
  _pause(reason) {
    if (this.paused) return;
    this.paused = true;
    if (this.stopFn) { this.stopFn(); this.stopFn = null; }
    this._flush();
    this.log('Recording paused:', reason);
  }

  _resume() {
    if (!this.paused || this.stopped) return;
    this.paused = false;
    this._record();
    this.log('Recording resumed');
  }

  _watchActivity() {
    const { pauseWhenHiddenMs, pauseWhenIdleMs } = this.config;
    let hiddenTimer = null;
    let idleTimer = null;
    const armIdle = () => {
      clearTimeout(idleTimer);
      if (pauseWhenIdleMs > 0) idleTimer = setTimeout(() => this._pause('idle'), pauseWhenIdleMs);
    };
    let last = 0; // throttle: mousemove and scroll fire constantly
    const onActivity = () => {
      const now = Date.now();
      if (now - last < 1000) return;
      last = now;
      armIdle();
      if (!document.hidden) this._resume();
    };
    ACTIVITY_EVENTS.forEach(t => window.addEventListener(t, onActivity, { capture: true, passive: true }));
    document.addEventListener('visibilitychange', () => {
      clearTimeout(hiddenTimer);
      if (document.hidden) {
        if (pauseWhenHiddenMs > 0) hiddenTimer = setTimeout(() => this._pause('hidden'), pauseWhenHiddenMs);
      } else {
        armIdle();
        this._resume();
      }
    });
    armIdle();
  }

  _halt() {
    this.stopped = true;
    this.paused = true;
    if (this.stopFn) { this.stopFn(); this.stopFn = null; }
    clearInterval(this.flushTimer);
  }

  stop() {
    this._flush();
    this._halt();
  }
}

// ─── Public API ──────────────────────────────────────────────────────────────
const ReplayIQ = {
  _instance: null,
  version: SDK_VERSION,

  /**
   * Starts recording. Resolves at once with the instance (`sampled` says
   * whether this session is recorded).
   *   ReplayIQ.init({ endpoint: 'https://ingest.example.com', key: '<ingest key>' })
   */
  init(config) {
    if (typeof window === 'undefined') return Promise.reject(new Error('ReplayIQ requires a browser environment'));
    if (!config || !(config.key || config.projectId)) return Promise.reject(new Error('ReplayIQ.init: `key` is required'));
    if (this._instance) return Promise.resolve(this._instance);
    const instance = (this._instance = new ReplayIQSDK(config));
    instance.start();
    return Promise.resolve(instance);
  },

  identify(userId, traits) { this._instance?.identify(userId, traits); },
  track(name, properties) { this._instance?.track(name, properties); },
  stop() { this._instance?.stop(); },
  getSessionId() { return this._instance?.sessionId; },

  /** Stops recording now and on future visits, until optIn(). */
  optOut() {
    setItem('local', '__riq_optout', '1');
    this._instance?._halt();
  },

  /** Allows recording again; takes effect on the next init (page load). */
  optIn() {
    removeItem('local', '__riq_optout');
  },

  isOptedOut() {
    return getItem('local', '__riq_optout') === '1';
  },
};

export default ReplayIQ;
