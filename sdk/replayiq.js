/*!
 * ReplayIQ SDK v1.0.0
 * Self-hosted session intelligence for enterprise
 * https://github.com/your-org/replayiq
 */
(function (global, factory) {
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = factory();
  } else {
    global.ReplayIQ = factory();
  }
})(typeof window !== 'undefined' ? window : typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  // ─── Constants ──────────────────────────────────────────────────────────────
  const SDK_VERSION = '1.0.0';
  const RRWEB_CDN = 'https://cdn.jsdelivr.net/npm/rrweb@1.1.3/dist/rrweb.min.js';
  const BATCH_SIZE = 50;
  const FLUSH_INTERVAL_MS = 5000;
  // Recording pauses (rrweb stops observing the DOM) after a tab has been
  // hidden this long, or nobody has interacted for this long, and resumes
  // with a fresh snapshot when the user is back. Both configurable.
  const PAUSE_WHEN_HIDDEN_MS = 60 * 1000;
  const PAUSE_WHEN_IDLE_MS = 10 * 60 * 1000;
  const ACTIVITY_EVENTS = ['mousemove', 'mousedown', 'keydown', 'scroll', 'touchstart', 'wheel'];

  // ─── Utilities ──────────────────────────────────────────────────────────────
  function generateId() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
      const r = (Math.random() * 16) | 0;
      return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
    });
  }

  function getOrCreateSessionId() {
    const KEY = '__riq_sid';
    let sid = sessionStorage.getItem(KEY);
    if (!sid) { sid = generateId(); sessionStorage.setItem(KEY, sid); }
    return sid;
  }

  // Sampling is decided once per session (not per page load), so a sampled
  // session is recorded on every page and an unsampled one on none.
  function isSessionSampled(rate) {
    const KEY = '__riq_sampled';
    try {
      const saved = sessionStorage.getItem(KEY);
      if (saved === '1' || saved === '0') return saved === '1';
      const sampled = Math.random() < rate;
      sessionStorage.setItem(KEY, sampled ? '1' : '0');
      return sampled;
    } catch (e) {
      return Math.random() < rate;
    }
  }

  // Runs fn once the page has loaded and the browser is idle, so loading
  // and starting the recorder never competes with the page's own startup.
  function whenIdle(fn) {
    const idle = () => (window.requestIdleCallback ? window.requestIdleCallback(fn, { timeout: 2000 }) : setTimeout(fn, 1));
    if (document.readyState === 'complete') idle();
    else window.addEventListener('load', idle, { once: true });
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

  function getOrCreateUserId() {
    const KEY = '__riq_uid';
    let uid = localStorage.getItem(KEY);
    if (!uid) { uid = generateId(); localStorage.setItem(KEY, uid); }
    return uid;
  }

  function createScriptURL(url) {
    if (typeof trustedTypes !== 'undefined' && trustedTypes) {
      try {
        const policy = (typeof trustedTypes.getPolicy === 'function' ? trustedTypes.getPolicy('replayiq') : null)
          || trustedTypes.createPolicy('replayiq', {
            createScriptURL: input => input,
          });

        if (policy && typeof policy.createScriptURL === 'function') {
          return policy.createScriptURL(url);
        }
      } catch (err) {
        // fallback to raw URL if Trusted Types policy cannot be created
      }
    }
    return url;
  }

  // ─── PII Masking ────────────────────────────────────────────────────────────
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

  // rrweb's own numeric event types (DomContentLoaded=0, Load=1, FullSnapshot=2,
  // IncrementalSnapshot=3, Meta=4, Custom=5). Backend storage expects `type`
  // to always be one of these ints; SDK-synthesized events (network/console/
  // js_error/behavior) aren't native rrweb events, so they're tagged as
  // Custom and carry their own discriminator in `subtype` instead.
  const EVENT_TYPE_CUSTOM = 5;

  // ─── Network Capture ────────────────────────────────────────────────────────
  function interceptNetwork(onEvent) {
    const origFetch = window.fetch;
    const origXHR = window.XMLHttpRequest.prototype.open;

    window.fetch = async function (...args) {
      const start = Date.now();
      const url = typeof args[0] === 'string' ? args[0] : args[0]?.url;
      try {
        const res = await origFetch.apply(this, args);
        onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'network', method: args[1]?.method || 'GET', url, status: res.status, duration: Date.now() - start, timestamp: Date.now() });
        return res;
      } catch (err) {
        onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'network', method: args[1]?.method || 'GET', url, status: 0, error: err.message, duration: Date.now() - start, timestamp: Date.now() });
        throw err;
      }
    };

    window.XMLHttpRequest.prototype.open = function (method, url, ...rest) {
      this._riq_method = method;
      this._riq_url = url;
      this._riq_start = Date.now();
      this.addEventListener('loadend', () => {
        onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'network', method: this._riq_method, url: this._riq_url, status: this.status, duration: Date.now() - this._riq_start, timestamp: Date.now() });
      });
      return origXHR.apply(this, [method, url, ...rest]);
    };
  }

  // ─── Console Error Capture ──────────────────────────────────────────────────
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

  // Stacks can be long (minified bundles); keep enough to locate the frame.
  function stackOf(err) {
    return err && typeof err.stack === 'string' ? err.stack.slice(0, 4000) : undefined;
  }

  // ─── Rage / Dead Click Detection ────────────────────────────────────────────
  function detectBehaviors(onEvent) {
    const clicks = [];
    document.addEventListener('click', e => {
      const now = Date.now();
      clicks.push({ x: e.clientX, y: e.clientY, t: now, target: e.target });

      // Semantic signal for AI analysis: rrweb's own native click/input
      // mutation events only carry an internal mirror-tree node id, never a
      // CSS selector, so the AI tokenizer has nothing to ground "a click
      // happened" in without this. Captured straight from the real DOM
      // event, same as the rage-click selector below.
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'click', selector: getSelector(e.target), timestamp: now });

      // Rage click: 3+ clicks within 700ms on same target
      const recent = clicks.filter(c => now - c.t < 700 && c.target === e.target);
      if (recent.length >= 3) {
        onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'rage_click', x: e.clientX, y: e.clientY, selector: getSelector(e.target), timestamp: now });
      }

      // Keep only last 10 clicks
      if (clicks.length > 10) clicks.shift();
    }, true);

    // Same gap for inputs as for clicks - capture which field was edited.
    document.addEventListener('input', e => {
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'input', selector: getSelector(e.target), timestamp: Date.now() });
    }, true);
  }

  function getSelector(el) {
    if (!el || el === document.body) return 'body';
    const id = el.id ? `#${el.id}` : '';
    const cls = el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.') : '';
    return `${el.tagName.toLowerCase()}${id}${cls}`;
  }

  // ─── Core SDK ───────────────────────────────────────────────────────────────
  class ReplayIQSDK {
    constructor(config) {
      this.config = {
        endpoint: config.endpoint || 'http://localhost:8080',
        projectId: config.projectId,
        sampleRate: config.sampleRate ?? 1.0,
        pauseWhenHiddenMs: config.pauseWhenHiddenMs ?? PAUSE_WHEN_HIDDEN_MS,
        pauseWhenIdleMs: config.pauseWhenIdleMs ?? PAUSE_WHEN_IDLE_MS,
        maskSelectors: config.maskSelectors || [],
        debug: config.debug || false,
        metadata: config.metadata || {},
      };

      this.sessionId = getOrCreateSessionId();
      this.userId = getOrCreateUserId();
      this.events = [];
      this.customEvents = [];
      this.stopFn = null;
      this.flushTimer = null;
      this.sessionStarted = Date.now();
      this.sampled = false;
      this.rrweb = null;
      this.paused = false;
      // Callers (e.g. a browser extension running this in a page with a
      // restrictive CSP) can supply their own transport to route requests
      // through a context that isn't bound by the page's connect-src.
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
      this.userId = userId;
      this.config.metadata = { ...this.config.metadata, ...traits };
      this.log('Identified user:', userId);
    }

    track(eventName, properties = {}) {
      this.customEvents.push({ name: eventName, properties, timestamp: Date.now() });
    }

    _initSession() {
      // POST session metadata first
      const payload = {
        session_id: this.sessionId,
        user_id: this.userId,
        project_id: this.config.projectId,
        url: location.href,
        user_agent: navigator.userAgent,
        screen_width: screen.width,
        screen_height: screen.height,
        sdk_version: SDK_VERSION,
        metadata: this.config.metadata,
        started_at: new Date(this.sessionStarted).toISOString(),
      };

      this.transport(`${this.config.endpoint}/api/v1/sessions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Project-ID': this.config.projectId },
        body: JSON.stringify(payload),
        keepalive: true,
      }).catch(e => this.log('Session init error:', e));
    }

    _flush() {
      if (!this.events.length && !this.customEvents.length) return;

      const batch = {
        session_id: this.sessionId,
        project_id: this.config.projectId,
        events: [...this.events],
        custom_events: [...this.customEvents],
        flushed_at: new Date().toISOString(),
      };

      this.events = [];
      this.customEvents = [];

      const body = JSON.stringify(batch);
      // Chromium hard-caps keepalive request bodies at 64KiB; a batch
      // containing a full-page rrweb snapshot easily exceeds that and fails
      // outright with a generic "Failed to fetch" before any network attempt
      // is even made. Only use keepalive (needed to survive page unload)
      // when the payload is safely under that ceiling.
      const keepalive = body.length < 60000;

      this.transport(`${this.config.endpoint}/api/v1/events`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Project-ID': this.config.projectId },
        body,
        keepalive,
      }).catch(e => this.log('Flush error:', e));
    }

    _startFlushLoop() {
      this.flushTimer = setInterval(() => this._flush(), FLUSH_INTERVAL_MS);

      // Hidden tabs are often never unloaded properly (mobile browsers kill
      // them without beforeunload): send what we have when the tab hides.
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') this._flush();
      });

      // Flush on page unload
      window.addEventListener('beforeunload', () => {
        clearInterval(this.flushTimer);
        this._flush();
        // Mark session ended
        this.transport(`${this.config.endpoint}/api/v1/sessions/${this.sessionId}/end`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ended_at: new Date().toISOString(), duration_ms: Date.now() - this.sessionStarted }),
          keepalive: true,
        }).catch(() => {});
      });
    }

    // Starts the session: network/console/behaviour capture right away,
    // and the DOM recorder (rrweb) once the page is idle. Returns false when
    // this session isn't sampled; nothing is recorded or downloaded then.
    start(loadRrweb) {
      this.sampled = isSessionSampled(this.config.sampleRate);
      if (!this.sampled) {
        this.log('Session not sampled, skipping.');
        return false;
      }

      this._initSession();
      this._startFlushLoop();

      // Network & behavior monitoring
      const push = e => { this.events.push({ ...e, session_id: this.sessionId }); };
      interceptNetwork(push);
      interceptConsole(push);
      detectBehaviors(push);
      this._watchActivity();

      whenIdle(() => {
        loadRrweb()
          .then(rrweb => { this.rrweb = rrweb; this._record(); })
          .catch(e => this.log('Recorder failed to load:', e));
      });

      this.log(`Session started: ${this.sessionId}`);
      return true;
    }

    _record() {
      if (!this.rrweb || this.stopFn || this.paused) return;
      this.stopFn = this.rrweb.record({
        emit: (event) => {
          this.events.push(event);
          if (this.events.length >= BATCH_SIZE) this._flush();
        },
        blockClass: buildBlockClass(this.config.maskSelectors),
        maskInputOptions: { password: true, email: false },
        maskInputSelector: PII_SELECTORS.join(','),
        collectFonts: true,
        recordCanvas: false,
        // Keyframes (Meta + FullSnapshot) that replay can start from. Event
        // count alone leaves quiet pages with one keyframe for many minutes,
        // so jumping late in a long session replays it all from the start;
        // the time bound caps a seek's catch-up at 30 s of events.
        checkoutEveryNth: 200,
        checkoutEveryNms: 30000,
      });
    }

    // Stops observing the DOM (a hidden or abandoned tab can keep mutating
    // it: tickers, timers, polling). Resuming starts with a full snapshot,
    // so the replay picks up the page exactly as the user finds it again.
    _pause(reason) {
      if (this.paused) return;
      this.paused = true;
      if (this.stopFn) { this.stopFn(); this.stopFn = null; }
      this._flush();
      this.log('Recording paused:', reason);
    }

    _resume() {
      if (!this.paused) return;
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
      // Throttled: mousemove and scroll fire constantly.
      let last = 0;
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

    stop() {
      this.paused = true; // no resuming after an explicit stop
      if (this.stopFn) { this.stopFn(); this.stopFn = null; }
      clearInterval(this.flushTimer);
      this._flush();
    }
  }

  // ─── Public API ─────────────────────────────────────────────────────────────
  const ReplayIQ = {
    _instance: null,

    /**
     * Initialize from script tag or module
     * Usage: ReplayIQ.init({ endpoint: 'https://your-host', projectId: 'proj_xxx' })
     */
    // Resolves at once with the instance (`instance.sampled` says whether
    // this session is recorded). rrweb is downloaded only for sampled
    // sessions, after the page has loaded (override the URL with
    // config.rrwebUrl to use a locally vendored build instead of the CDN).
    init(config) {
      if (typeof window === 'undefined') return Promise.reject(new Error('ReplayIQ requires a browser environment'));
      if (this._instance) return Promise.resolve(this._instance);
      const instance = (this._instance = new ReplayIQSDK(config));
      instance.start(() => (window.rrweb
        ? Promise.resolve(window.rrweb)
        : loadScript(config.rrwebUrl || RRWEB_CDN).then(() => window.rrweb)));
      return Promise.resolve(instance);
    },

    identify(userId, traits) {
      this._instance?.identify(userId, traits);
    },

    track(eventName, properties) {
      this._instance?.track(eventName, properties);
    },

    stop() {
      this._instance?.stop();
    },

    getSessionId() {
      return this._instance?.sessionId;
    },

    /**
     * Console injection for demos
     * Paste this in any browser console:
     *   (function(){var s=document.createElement('script');s.src='http://localhost:8080/sdk/replayiq.js';s.onload=function(){ReplayIQ.init({endpoint:'http://localhost:8080',projectId:'demo'})};document.head.appendChild(s)})()
     */
    _consoleSnippet(endpoint = 'http://localhost:8080', projectId = 'demo') {
      return `(function(){function createScriptURL(url){if(window.trustedTypes){try{const policy=trustedTypes.getPolicy('replayiq')||trustedTypes.createPolicy('replayiq',{createScriptURL:input=>input});if(policy&&typeof policy.createScriptURL==='function')return policy.createScriptURL(url);}catch(e){}}return url;}var s=document.createElement('script');s.setAttribute('src',createScriptURL('${endpoint}/sdk/replayiq.js'));s.onload=function(){ReplayIQ.init({endpoint:'${endpoint}',projectId:'${projectId}'});};document.head.appendChild(s);})()`;
    },
  };

  return ReplayIQ;
});
