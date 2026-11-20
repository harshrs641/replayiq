/*! @replayiq/web 1.1.0 | Apache-2.0 */
var __riq = (() => {
  var __create = Object.create;
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __getProtoOf = Object.getPrototypeOf;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __require = /* @__PURE__ */ ((x) => typeof require !== "undefined" ? require : typeof Proxy !== "undefined" ? new Proxy(x, {
    get: (a, b) => (typeof require !== "undefined" ? require : a)[b]
  }) : x)(function(x) {
    if (typeof require !== "undefined") return require.apply(this, arguments);
    throw Error('Dynamic require of "' + x + '" is not supported');
  });
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
    // If the importer is in node compatibility mode or this is not an ESM
    // file that has been converted to a CommonJS file using a Babel-
    // compatible transform (i.e. "__esModule" has not been set), then set
    // "default" to the CommonJS "module.exports" for node compatibility.
    isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
    mod
  ));
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // src/index.js
  var index_exports = {};
  __export(index_exports, {
    default: () => index_default
  });
  var SDK_VERSION = true ? "1.1.0" : "dev";
  var SDK_NAME = `replayiq-web/${SDK_VERSION}`;
  var BATCH_SIZE = 50;
  var FLUSH_INTERVAL_MS = 5e3;
  var PAUSE_WHEN_HIDDEN_MS = 60 * 1e3;
  var PAUSE_WHEN_IDLE_MS = 10 * 60 * 1e3;
  var ACTIVITY_EVENTS = ["mousemove", "mousedown", "keydown", "scroll", "touchstart", "wheel"];
  var MAX_QUEUED_EVENTS = 1e3;
  var MAX_BACKOFF_MS = 60 * 1e3;
  var KEEPALIVE_MAX_BYTES = 6e4;
  var EVENT_TYPE_CUSTOM = 5;
  function store(kind) {
    try {
      return kind === "local" ? window.localStorage : window.sessionStorage;
    } catch (e) {
      return null;
    }
  }
  function getItem(kind, key) {
    var _a, _b;
    try {
      return (_b = (_a = store(kind)) == null ? void 0 : _a.getItem(key)) != null ? _b : null;
    } catch (e) {
      return null;
    }
  }
  function setItem(kind, key, value) {
    var _a;
    try {
      (_a = store(kind)) == null ? void 0 : _a.setItem(key, value);
    } catch (e) {
    }
  }
  function removeItem(kind, key) {
    var _a;
    try {
      (_a = store(kind)) == null ? void 0 : _a.removeItem(key);
    } catch (e) {
    }
  }
  function generateId() {
    if (typeof crypto !== "undefined" && crypto.randomUUID) return crypto.randomUUID();
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      return (c === "x" ? r : r & 3 | 8).toString(16);
    });
  }
  function getOrCreate(kind, key) {
    let v = getItem(kind, key);
    if (!v) {
      v = generateId();
      setItem(kind, key, v);
    }
    return v;
  }
  function isSessionSampled(rate) {
    const saved = getItem("session", "__riq_sampled");
    if (saved === "1" || saved === "0") return saved === "1";
    const sampled = Math.random() < rate;
    setItem("session", "__riq_sampled", sampled ? "1" : "0");
    return sampled;
  }
  function nextBatchId(sessionId) {
    const n = Number(getItem("session", "__riq_seq") || 0) + 1;
    setItem("session", "__riq_seq", String(n));
    return `${sessionId}-${String(n).padStart(6, "0")}-${Math.random().toString(36).slice(2, 6)}`;
  }
  function createScriptURL(url) {
    if (typeof trustedTypes !== "undefined" && trustedTypes) {
      try {
        const policy = (typeof trustedTypes.getPolicy === "function" ? trustedTypes.getPolicy("replayiq") : null) || trustedTypes.createPolicy("replayiq", { createScriptURL: (input) => input });
        if (policy && typeof policy.createScriptURL === "function") return policy.createScriptURL(url);
      } catch (err) {
      }
    }
    return url;
  }
  function loadScript(url) {
    return new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.setAttribute("src", createScriptURL(url));
      script.onload = resolve;
      script.onerror = () => reject(new Error("Failed to load " + url));
      document.head.appendChild(script);
    });
  }
  var scriptBase = (() => {
    try {
      const src = document.currentScript && document.currentScript.src;
      return src ? src.slice(0, src.lastIndexOf("/") + 1) : "";
    } catch (e) {
      return "";
    }
  })();
  function loadRecorder(config) {
    if (typeof window !== "undefined" && window.rrweb && window.rrweb.record) return Promise.resolve(window.rrweb);
    if (true) {
      const url = config.rrwebUrl || (scriptBase ? scriptBase + "rrweb.min.js" : "");
      if (!url) return Promise.reject(new Error("rrwebUrl is required when the SDK is not loaded from a script tag"));
      return loadScript(url).then(() => window.rrweb);
    }
    return import("rrweb");
  }
  function whenIdle(fn) {
    const idle = () => window.requestIdleCallback ? window.requestIdleCallback(fn, { timeout: 2e3 }) : setTimeout(fn, 1);
    if (document.readyState === "complete") idle();
    else window.addEventListener("load", idle, { once: true });
  }
  async function gzip(text) {
    if (typeof CompressionStream === "undefined") return null;
    try {
      const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
      return new Uint8Array(await new Response(stream).arrayBuffer());
    } catch (e) {
      return null;
    }
  }
  var PII_SELECTORS = [
    'input[type="password"]',
    'input[type="email"]',
    'input[name*="card"]',
    'input[name*="cvv"]',
    'input[name*="ssn"]',
    'input[name*="phone"]',
    "[data-riq-mask]"
  ];
  function buildBlockClass(custom = []) {
    const classes = ["riq-mask", ...custom];
    return classes.length === 1 ? classes[0] : new RegExp(classes.map((c) => c.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|"));
  }
  function interceptNetwork(onEvent, isOwnRequest) {
    const origFetch = window.fetch;
    const origXHR = window.XMLHttpRequest.prototype.open;
    window.fetch = async function(...args) {
      var _a, _b, _c;
      const start = Date.now();
      const url = typeof args[0] === "string" ? args[0] : (_a = args[0]) == null ? void 0 : _a.url;
      const method = ((_b = args[1]) == null ? void 0 : _b.method) || ((_c = args[0]) == null ? void 0 : _c.method) || "GET";
      if (isOwnRequest(url)) return origFetch.apply(this, args);
      try {
        const res = await origFetch.apply(this, args);
        onEvent({ type: EVENT_TYPE_CUSTOM, subtype: "network", method, url, status: res.status, duration: Date.now() - start, timestamp: Date.now() });
        return res;
      } catch (err) {
        onEvent({ type: EVENT_TYPE_CUSTOM, subtype: "network", method, url, status: 0, error: err.message, duration: Date.now() - start, timestamp: Date.now() });
        throw err;
      }
    };
    window.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
      this._riq_method = method;
      this._riq_url = url;
      this._riq_start = Date.now();
      if (!isOwnRequest(String(url))) {
        this.addEventListener("loadend", () => {
          onEvent({ type: EVENT_TYPE_CUSTOM, subtype: "network", method: this._riq_method, url: this._riq_url, status: this.status, duration: Date.now() - this._riq_start, timestamp: Date.now() });
        });
      }
      return origXHR.apply(this, [method, url, ...rest]);
    };
  }
  function stackOf(err) {
    return err && typeof err.stack === "string" ? err.stack.slice(0, 4e3) : void 0;
  }
  function interceptConsole(onEvent) {
    ["error", "warn"].forEach((level) => {
      const orig = console[level].bind(console);
      console[level] = function(...args) {
        const err = args.find((a) => a instanceof Error);
        onEvent({ type: EVENT_TYPE_CUSTOM, subtype: "console", level, message: args.map(String).join(" "), stack: stackOf(err), timestamp: Date.now() });
        orig(...args);
      };
    });
    window.addEventListener("error", (e) => {
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: "js_error", message: e.message, filename: e.filename, lineno: e.lineno, colno: e.colno, stack: stackOf(e.error), timestamp: Date.now() });
    });
    window.addEventListener("unhandledrejection", (e) => {
      const r = e.reason;
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: "js_error", message: "Unhandled rejection: " + (r && r.message ? r.message : String(r)), stack: stackOf(r), timestamp: Date.now() });
    });
  }
  function getSelector(el) {
    if (!el || !el.tagName || el === document.body) return "body";
    const id = el.id ? `#${el.id}` : "";
    const cls = el.className && typeof el.className === "string" ? "." + el.className.trim().split(/\s+/).slice(0, 2).join(".") : "";
    return `${el.tagName.toLowerCase()}${id}${cls === "." ? "" : cls}`;
  }
  function detectBehaviors(onEvent) {
    const clicks = [];
    document.addEventListener("click", (e) => {
      const now = Date.now();
      clicks.push({ t: now, target: e.target });
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: "click", selector: getSelector(e.target), timestamp: now });
      const recent = clicks.filter((c) => now - c.t < 700 && c.target === e.target);
      if (recent.length >= 3) {
        onEvent({ type: EVENT_TYPE_CUSTOM, subtype: "rage_click", x: e.clientX, y: e.clientY, selector: getSelector(e.target), timestamp: now });
      }
      if (clicks.length > 10) clicks.shift();
    }, true);
    document.addEventListener("input", (e) => {
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: "input", selector: getSelector(e.target), timestamp: Date.now() });
    }, true);
  }
  function watchNavigation(onEvent) {
    let last = location.href;
    const check = () => {
      if (location.href === last) return;
      last = location.href;
      onEvent({ type: EVENT_TYPE_CUSTOM, subtype: "navigate", url: last, message: document.title, timestamp: Date.now() });
    };
    for (const m of ["pushState", "replaceState"]) {
      const orig = history[m];
      history[m] = function(...args) {
        const r = orig.apply(this, args);
        check();
        return r;
      };
    }
    window.addEventListener("popstate", check);
    window.addEventListener("hashchange", check);
  }
  var ReplayIQSDK = class {
    constructor(config) {
      var _a, _b, _c;
      const key = config.key || config.projectId;
      this.config = {
        endpoint: (config.endpoint || "http://localhost:8080").replace(/\/+$/, ""),
        key,
        projectId: config.projectId || "",
        sampleRate: (_a = config.sampleRate) != null ? _a : 1,
        maskSelectors: config.maskSelectors || [],
        pauseWhenHiddenMs: (_b = config.pauseWhenHiddenMs) != null ? _b : PAUSE_WHEN_HIDDEN_MS,
        pauseWhenIdleMs: (_c = config.pauseWhenIdleMs) != null ? _c : PAUSE_WHEN_IDLE_MS,
        rrwebUrl: config.rrwebUrl,
        debug: !!config.debug,
        metadata: config.metadata || {}
      };
      this.sessionId = getOrCreate("session", "__riq_sid");
      this.userId = getItem("local", "__riq_user") || getOrCreate("local", "__riq_uid");
      this.events = [];
      this.customEvents = [];
      this.queue = [];
      this.sending = false;
      this.backoffMs = 0;
      this.stopped = false;
      this.stopFn = null;
      this.flushTimer = null;
      this.sessionStarted = Date.now();
      this.sampled = false;
      this.rrweb = null;
      this.paused = false;
      this.transport = typeof config.transport === "function" ? config.transport : (url, options) => fetch(url, options);
    }
    log(...args) {
      if (this.config.debug) console.log("[ReplayIQ]", ...args);
    }
    getSessionId() {
      return this.sessionId;
    }
    identify(userId, traits = {}) {
      this.userId = String(userId);
      setItem("local", "__riq_user", this.userId);
      this.config.metadata = { ...this.config.metadata, ...traits };
      this.log("Identified user:", userId);
    }
    track(name, properties = {}) {
      if (this.stopped || !this.sampled) return;
      this.customEvents.push({ name: String(name), properties, timestamp: Date.now() });
    }
    _headers(extra = {}) {
      const h = { "Content-Type": "application/json", Authorization: `Bearer ${this.config.key}`, ...extra };
      if (this.config.projectId) h["X-Project-ID"] = this.config.projectId;
      return h;
    }
    _post(path, body, { keepalive = false } = {}) {
      return this.transport(`${this.config.endpoint}${path}`, {
        method: "POST",
        headers: this._headers(),
        body: JSON.stringify(body),
        keepalive
      });
    }
    _isOwnRequest(url) {
      return typeof url === "string" && url.startsWith(this.config.endpoint + "/api/");
    }
    _push(e) {
      if (this.stopped) return;
      this.events.push({ ...e, session_id: this.sessionId });
      if (this.events.length >= BATCH_SIZE) this._flush();
    }
    _initSession() {
      this._post("/api/v1/sessions", {
        session_id: this.sessionId,
        user_id: this.userId,
        project_id: this.config.projectId || void 0,
        url: location.href,
        user_agent: navigator.userAgent,
        screen_width: screen.width,
        screen_height: screen.height,
        sdk_version: SDK_NAME,
        metadata: { platform: "web", ...this.config.metadata },
        started_at: new Date(this.sessionStarted).toISOString()
      }, { keepalive: true }).catch((e) => this.log("Session init error:", e));
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
        for (const b of this.queue) this._sendBatch(b, true).catch(() => {
        });
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
          if (result === "retry") {
            this.backoffMs = Math.min(Math.max(this.backoffMs * 2, 1e3), MAX_BACKOFF_MS);
            setTimeout(() => {
              this.backoffMs = 0;
              this._drain();
            }, this.backoffMs);
            break;
          }
          this.queue.shift();
          if (result === "split" && batch.events.length > 1) {
            const half = Math.ceil(batch.events.length / 2);
            this.queue.unshift(
              { id: nextBatchId(this.sessionId), events: batch.events.slice(0, half) },
              { id: nextBatchId(this.sessionId), events: batch.events.slice(half) }
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
        project_id: this.config.projectId || void 0,
        batch_id: batch.id,
        platform: "web",
        sdk: SDK_NAME,
        events: batch.events,
        custom_events: batch.custom || [],
        flushed_at: (/* @__PURE__ */ new Date()).toISOString()
      });
      let body = json;
      let headers = this._headers();
      if (!unloading && json.length > 1024) {
        const zipped = await gzip(json);
        if (zipped) {
          body = zipped;
          headers = this._headers({ "Content-Encoding": "gzip" });
        }
      }
      const size = typeof body === "string" ? body.length : body.byteLength;
      let res;
      try {
        res = await this.transport(`${this.config.endpoint}/api/v1/events`, {
          method: "POST",
          headers,
          body,
          keepalive: unloading && size < KEEPALIVE_MAX_BYTES
        });
      } catch (e) {
        this.log("Flush error:", e);
        return "retry";
      }
      const status = res && typeof res.status === "number" ? res.status : 202;
      if (status < 300) return "ok";
      if (status === 401 || status === 403) {
        this.log("Ingest key rejected; recording stopped.");
        this._halt();
        return "drop";
      }
      if (status === 413) return "split";
      if (status === 429 || status >= 500) return "retry";
      this.log(`Batch rejected (HTTP ${status}); dropped.`);
      return "drop";
    }
    _startFlushLoop() {
      this.flushTimer = setInterval(() => this._flush(), FLUSH_INTERVAL_MS);
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "hidden") this._flush();
      });
      window.addEventListener("pagehide", () => {
        if (this.stopped) return;
        this._flush(true);
        this._post(`/api/v1/sessions/${this.sessionId}/end`, {
          ended_at: (/* @__PURE__ */ new Date()).toISOString(),
          duration_ms: Date.now() - this.sessionStarted
        }, { keepalive: true }).catch(() => {
        });
      });
    }
    // Starts the session: network/console/behaviour capture right away, and
    // the DOM recorder (rrweb) once the page is idle. Returns false when this
    // session isn't sampled, or the user opted out: nothing is recorded or
    // downloaded then.
    start() {
      if (getItem("local", "__riq_optout") === "1") {
        this.log("User opted out; not recording.");
        return false;
      }
      this.sampled = isSessionSampled(this.config.sampleRate);
      if (!this.sampled) {
        this.log("Session not sampled, skipping.");
        return false;
      }
      this._initSession();
      this._startFlushLoop();
      const push = (e) => this._push(e);
      interceptNetwork(push, (url) => this._isOwnRequest(url));
      interceptConsole(push);
      detectBehaviors(push);
      watchNavigation(push);
      this._watchActivity();
      whenIdle(() => {
        loadRecorder(this.config).then((rrweb) => {
          this.rrweb = rrweb;
          this._record();
        }).catch((e) => this.log("Recorder failed to load:", e));
      });
      this.log(`Session started: ${this.sessionId}`);
      return true;
    }
    _record() {
      if (!this.rrweb || this.stopFn || this.paused || this.stopped) return;
      this.stopFn = this.rrweb.record({
        emit: (event) => {
          this.events.push(event);
          if (this.events.length >= BATCH_SIZE) this._flush();
        },
        blockClass: buildBlockClass(this.config.maskSelectors),
        maskInputOptions: { password: true, email: false },
        maskInputSelector: PII_SELECTORS.join(","),
        collectFonts: true,
        recordCanvas: false,
        // Keyframes (Meta + FullSnapshot) that replay can start from: at
        // least every 30 s of activity, so a seek replays at most that.
        checkoutEveryNth: 200,
        checkoutEveryNms: 3e4
      });
    }
    // Stops observing the DOM (a hidden or abandoned tab can keep mutating
    // it: tickers, timers, polling). Resuming starts with a full snapshot.
    _pause(reason) {
      if (this.paused) return;
      this.paused = true;
      if (this.stopFn) {
        this.stopFn();
        this.stopFn = null;
      }
      this._flush();
      this.log("Recording paused:", reason);
    }
    _resume() {
      if (!this.paused || this.stopped) return;
      this.paused = false;
      this._record();
      this.log("Recording resumed");
    }
    _watchActivity() {
      const { pauseWhenHiddenMs, pauseWhenIdleMs } = this.config;
      let hiddenTimer = null;
      let idleTimer = null;
      const armIdle = () => {
        clearTimeout(idleTimer);
        if (pauseWhenIdleMs > 0) idleTimer = setTimeout(() => this._pause("idle"), pauseWhenIdleMs);
      };
      let last = 0;
      const onActivity = () => {
        const now = Date.now();
        if (now - last < 1e3) return;
        last = now;
        armIdle();
        if (!document.hidden) this._resume();
      };
      ACTIVITY_EVENTS.forEach((t) => window.addEventListener(t, onActivity, { capture: true, passive: true }));
      document.addEventListener("visibilitychange", () => {
        clearTimeout(hiddenTimer);
        if (document.hidden) {
          if (pauseWhenHiddenMs > 0) hiddenTimer = setTimeout(() => this._pause("hidden"), pauseWhenHiddenMs);
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
      if (this.stopFn) {
        this.stopFn();
        this.stopFn = null;
      }
      clearInterval(this.flushTimer);
    }
    stop() {
      this._flush();
      this._halt();
    }
  };
  var ReplayIQ = {
    _instance: null,
    version: SDK_VERSION,
    /**
     * Starts recording. Resolves at once with the instance (`sampled` says
     * whether this session is recorded).
     *   ReplayIQ.init({ endpoint: 'https://ingest.example.com', key: '<ingest key>' })
     */
    init(config) {
      if (typeof window === "undefined") return Promise.reject(new Error("ReplayIQ requires a browser environment"));
      if (!config || !(config.key || config.projectId)) return Promise.reject(new Error("ReplayIQ.init: `key` is required"));
      if (this._instance) return Promise.resolve(this._instance);
      const instance = this._instance = new ReplayIQSDK(config);
      instance.start();
      return Promise.resolve(instance);
    },
    identify(userId, traits) {
      var _a;
      (_a = this._instance) == null ? void 0 : _a.identify(userId, traits);
    },
    track(name, properties) {
      var _a;
      (_a = this._instance) == null ? void 0 : _a.track(name, properties);
    },
    stop() {
      var _a;
      (_a = this._instance) == null ? void 0 : _a.stop();
    },
    getSessionId() {
      var _a;
      return (_a = this._instance) == null ? void 0 : _a.sessionId;
    },
    /** Stops recording now and on future visits, until optIn(). */
    optOut() {
      var _a;
      setItem("local", "__riq_optout", "1");
      (_a = this._instance) == null ? void 0 : _a._halt();
    },
    /** Allows recording again; takes effect on the next init (page load). */
    optIn() {
      removeItem("local", "__riq_optout");
    },
    isOptedOut() {
      return getItem("local", "__riq_optout") === "1";
    }
  };
  var index_default = ReplayIQ;
  return __toCommonJS(index_exports);
})();
/*!
 * ReplayIQ web SDK
 * Implements the ReplayIQ Recording API v1 (docs/sdk/recording-api-v1.md).
 */
window.ReplayIQ = __riq.default;
