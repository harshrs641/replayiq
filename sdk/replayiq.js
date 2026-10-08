/*!
 * ReplayIQ SDK v1.0.0
 * Self-hosted session intelligence for enterprise
 * https://github.com/your-org/replayiq
 */
(function (global, factory) {
  console.log('[SDK] UMD wrapper executing. global:', typeof global, 'is window?', global === window);
  if (typeof module !== 'undefined' && module.exports) {
    console.log('[SDK] Using CommonJS export');
    module.exports = factory();
  } else {
    console.log('[SDK] Setting global.ReplayIQ');
    const ReplayIQ = factory();
    console.log('[SDK] Factory returned:', typeof ReplayIQ);
    global.ReplayIQ = ReplayIQ;
    console.log('[SDK] window.ReplayIQ is now:', typeof window.ReplayIQ);
  }
})(typeof window !== 'undefined' ? window : typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  // ─── Constants ──────────────────────────────────────────────────────────────
  const SDK_VERSION = '1.0.0';
  const RRWEB_CDN = 'https://cdn.jsdelivr.net/npm/rrweb@1.1.3/dist/rrweb.min.js';
  const BATCH_SIZE = 50;
  const FLUSH_INTERVAL_MS = 5000;

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
        onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'console', level, message: args.map(String).join(' '), timestamp: Date.now() });
        orig(...args);
      };
    });

    window.addEventListener('error', e => {
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'js_error', message: e.message, filename: e.filename, lineno: e.lineno, colno: e.colno, timestamp: Date.now() });
    });

    window.addEventListener('unhandledrejection', e => {
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: 'js_error', message: String(e.reason), timestamp: Date.now() });
    });
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

    start(rrweb) {
      // Sampling
      if (Math.random() > this.config.sampleRate) {
        this.log('Session not sampled, skipping.');
        return;
      }

      this._initSession();
      this._startFlushLoop();

      // rrweb recording
      this.stopFn = rrweb.record({
        emit: (event) => {
          this.events.push(event);
          if (this.events.length >= BATCH_SIZE) this._flush();
        },
        blockClass: buildBlockClass(this.config.maskSelectors),
        maskInputOptions: { password: true, email: false },
        maskInputSelector: PII_SELECTORS.join(','),
        collectFonts: true,
        recordCanvas: false,
        checkoutEveryNth: 200,
      });

      // Network & behavior monitoring
      interceptNetwork(e => { this.events.push({ ...e, session_id: this.sessionId }); });
      interceptConsole(e => { this.events.push({ ...e, session_id: this.sessionId }); });
      detectBehaviors(e => { this.events.push({ ...e, session_id: this.sessionId }); });

      this.log(`Session started: ${this.sessionId}`);
      return this.sessionId;
    }

    stop() {
      if (this.stopFn) this.stopFn();
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
    init(config) {
      return new Promise((resolve, reject) => {
        if (typeof window === 'undefined') return reject(new Error('ReplayIQ requires a browser environment'));

        if (window.rrweb) {
          this._instance = new ReplayIQSDK(config);
          this._instance.start(window.rrweb);
          resolve(this._instance);
          return;
        }

        // Lazy-load rrweb (override with config.rrwebUrl to point at a
        // locally vendored build instead of the CDN)
        const script = document.createElement('script');
        script.setAttribute('src', createScriptURL(config.rrwebUrl || RRWEB_CDN));
        script.onload = () => {
          this._instance = new ReplayIQSDK(config);
          this._instance.start(window.rrweb);
          resolve(this._instance);
        };
        script.onerror = () => reject(new Error('Failed to load rrweb'));
        document.head.appendChild(script);
      });
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
