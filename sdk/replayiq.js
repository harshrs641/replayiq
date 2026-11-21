/*! @replayiq/web 1.2.0 | Apache-2.0 */
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

  // src/redact.js
  var REDACTED = "[redacted]";
  var SECRET_HEADERS = /* @__PURE__ */ new Set([
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-api-key",
    "x-auth-token",
    "x-csrf-token",
    "x-xsrf-token"
  ]);
  var SENSITIVE_KEYS = /* @__PURE__ */ new Set([
    "password",
    "passwd",
    "pwd",
    "secret",
    "clientsecret",
    "token",
    "accesstoken",
    "refreshtoken",
    "idtoken",
    "authtoken",
    "apikey",
    "privatekey",
    "otp",
    "pin",
    "cvv",
    "cvc",
    "cvv2",
    "cardnumber",
    "pan",
    "securitycode",
    "ssn"
  ]);
  var norm = (k) => String(k).toLowerCase().replace(/[_\-\s]/g, "");
  function makeRedactor({ redactHeaders = [], maskBodyKeys = [] } = {}) {
    const headers = /* @__PURE__ */ new Set([...SECRET_HEADERS, ...redactHeaders.map((h) => h.toLowerCase())]);
    const keys = /* @__PURE__ */ new Set([...SENSITIVE_KEYS, ...maskBodyKeys.map(norm)]);
    const sensitive = (k) => keys.has(norm(k));
    function cards(s) {
      if (typeof s !== "string" || s.length < 13) return s;
      return s.replace(/\b\d(?:[ -]?\d){12,18}\b/g, (m) => {
        const d = m.replace(/\D/g, "");
        return d.length >= 13 && d.length <= 19 && luhn(d) ? REDACTED : m;
      });
    }
    function json(v, depth = 0) {
      if (depth > 20) return v;
      if (Array.isArray(v)) return v.map((x) => json(x, depth + 1));
      if (v && typeof v === "object") {
        const out = {};
        for (const [k, val] of Object.entries(v)) out[k] = sensitive(k) && val != null ? REDACTED : json(val, depth + 1);
        return out;
      }
      return typeof v === "string" ? cards(v) : v;
    }
    function params(qs) {
      const p = new URLSearchParams(qs);
      for (const [k, v] of [...p.entries()]) p.set(k, sensitive(k) ? REDACTED : cards(v));
      return p.toString();
    }
    return {
      cards,
      json,
      url(u) {
        if (!u) return u;
        try {
          const url = new URL(u, location.href);
          if (url.search) url.search = params(url.search.slice(1));
          return cards(url.toString());
        } catch (e) {
          return cards(u);
        }
      },
      headers(h) {
        const out = {};
        for (const [k, v] of Object.entries(h || {})) {
          const name = k.toLowerCase();
          out[name] = headers.has(name) ? REDACTED : cards(String(v));
        }
        return out;
      },
      body(text, contentType = "") {
        if (typeof text !== "string" || !text) return text;
        const t = text.trim();
        if (t.startsWith("{") || t.startsWith("[")) {
          try {
            return JSON.stringify(json(JSON.parse(t)));
          } catch (e) {
          }
        }
        if (contentType.includes("x-www-form-urlencoded") || /^[^\s{<]+=/.test(t) && !t.includes(" ")) {
          try {
            return params(t);
          } catch (e) {
          }
        }
        return cards(text);
      }
    };
  }
  function luhn(d) {
    let sum = 0;
    let double = false;
    for (let i = d.length - 1; i >= 0; i--) {
      let n = d.charCodeAt(i) - 48;
      if (double) {
        n *= 2;
        if (n > 9) n -= 9;
      }
      sum += n;
      double = !double;
    }
    return sum % 10 === 0;
  }
  function serializeArgs(args) {
    const seen = /* @__PURE__ */ new WeakSet();
    function conv(v, depth) {
      if (v === null || typeof v === "number" || typeof v === "boolean") return v;
      if (typeof v === "string") return v.length > 2e3 ? v.slice(0, 2e3) + "\u2026" : v;
      if (typeof v === "undefined") return "[undefined]";
      if (typeof v === "function") return `[function ${v.name || "anonymous"}]`;
      if (typeof v === "symbol" || typeof v === "bigint") return String(v);
      if (v instanceof Error) return { name: v.name, message: v.message, stack: (v.stack || "").slice(0, 2e3) };
      if (typeof Element !== "undefined" && v instanceof Element) return `<${v.tagName.toLowerCase()}${v.id ? "#" + v.id : ""}>`;
      if (seen.has(v)) return "[circular]";
      if (depth >= 4) return Array.isArray(v) ? `[array ${v.length}]` : "[object]";
      seen.add(v);
      if (Array.isArray(v)) return v.slice(0, 50).map((x) => conv(x, depth + 1));
      const out2 = {};
      for (const k of Object.keys(v).slice(0, 50)) {
        try {
          out2[k] = conv(v[k], depth + 1);
        } catch (e) {
          out2[k] = "[unreadable]";
        }
      }
      return out2;
    }
    const out = args.map((a) => conv(a, 0));
    const s = JSON.stringify(out);
    return s.length > 8192 ? [s.slice(0, 8192) + "\u2026"] : out;
  }

  // src/capture.js
  var EVENT_TYPE_CUSTOM = 5;
  var TEXT_TYPES = /json|text\/|x-www-form-urlencoded|xml|graphql|javascript/i;
  function stackOf(err) {
    return err && typeof err.stack === "string" ? err.stack.slice(0, 4e3) : void 0;
  }
  function truncate(text, max) {
    if (typeof text !== "string") return { body: void 0, truncated: false };
    return text.length > max ? { body: text.slice(0, max), truncated: true } : { body: text, truncated: false };
  }
  function requestBodyText(body) {
    if (body == null) return void 0;
    if (typeof body === "string") return body;
    if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) return body.toString();
    return void 0;
  }
  function headersObject(h) {
    const out = {};
    if (!h) return out;
    if (typeof h.forEach === "function" && !Array.isArray(h)) {
      h.forEach((v, k) => {
        out[k.toLowerCase()] = v;
      });
      return out;
    }
    if (Array.isArray(h)) {
      for (const [k, v] of h) out[String(k).toLowerCase()] = v;
      return out;
    }
    for (const k of Object.keys(h)) out[k.toLowerCase()] = h[k];
    return out;
  }
  function resourceTiming(url, startedAt) {
    try {
      const abs = new URL(url, location.href).href;
      const entries = performance.getEntriesByName(abs, "resource");
      const e = entries.filter((x) => performance.timeOrigin + x.startTime >= startedAt - 50).pop() || entries.pop();
      if (!e) return {};
      const ms = (a, b) => a > 0 && b > 0 && b >= a ? Math.round(b - a) : void 0;
      const timing = {
        dns: ms(e.domainLookupStart, e.domainLookupEnd),
        connect: ms(e.connectStart, e.connectEnd),
        tls: e.secureConnectionStart > 0 ? ms(e.secureConnectionStart, e.connectEnd) : void 0,
        ttfb: ms(e.requestStart, e.responseStart),
        download: ms(e.responseStart, e.responseEnd)
      };
      return {
        timing,
        protocol: e.nextHopProtocol || void 0,
        cached: e.transferSize === 0 && e.decodedBodySize > 0,
        size: e.encodedBodySize || void 0
      };
    } catch (err) {
      return {};
    }
  }
  function createNetworkCapture(opts, auto) {
    const { redact, emit, ignore, maxBodyBytes = 65536 } = opts;
    const origFetch = window.fetch.bind(window);
    function record(e) {
      if (!e || !e.url || ignore(e.url)) return;
      const ev = {
        type: EVENT_TYPE_CUSTOM,
        subtype: "network",
        timestamp: e.timestamp || Date.now(),
        method: String(e.method || "GET").toUpperCase(),
        url: redact.url(e.url),
        status: e.status || 0,
        duration: e.duration,
        error: e.error ? String(e.error).slice(0, 1e3) : void 0,
        protocol: e.protocol,
        cached: e.cached,
        initiator: e.initiator,
        timing: e.timing
      };
      for (const side of ["request", "response"]) {
        const s = e[side];
        if (!s) continue;
        const ct = (s.content_type || s.headers && headersObject(s.headers)["content-type"] || "").toString();
        const out = { headers: redact.headers(headersObject(s.headers)), size: s.size };
        if (s.content_type) out.content_type = s.content_type;
        if (opts.bodies && typeof s.body === "string" && (!ct || TEXT_TYPES.test(ct))) {
          const t = truncate(s.body, maxBodyBytes);
          out.body = redact.body(t.body, ct);
          out.truncated = t.truncated || s.truncated || false;
          if (out.size == null) out.size = s.body.length;
        }
        ev[side] = out;
      }
      emit(ev);
    }
    async function recordingFetch(input, init) {
      const startedAt = Date.now();
      const url = typeof input === "string" ? input : input && (input.url || String(input));
      const method = init && init.method || input && input.method || "GET";
      if (!url || ignore(url)) return origFetch(input, init);
      const reqHeaders = headersObject(init && init.headers || input && input.headers);
      const reqBody = requestBodyText(init && init.body);
      let res;
      try {
        res = await origFetch(input, init);
      } catch (err) {
        record({
          method,
          url,
          status: 0,
          error: err && err.message,
          duration: Date.now() - startedAt,
          timestamp: startedAt,
          initiator: "fetch",
          request: { headers: reqHeaders, body: reqBody }
        });
        throw err;
      }
      const duration = Date.now() - startedAt;
      const resHeaders = headersObject(res.headers);
      const ct = resHeaders["content-type"] || "";
      const finish = (text) => {
        const rt = resourceTiming(url, startedAt);
        record({
          method,
          url,
          status: res.status,
          duration,
          timestamp: startedAt,
          initiator: "fetch",
          protocol: rt.protocol,
          cached: rt.cached,
          timing: rt.timing,
          request: { headers: reqHeaders, body: reqBody },
          response: { headers: resHeaders, body: text, content_type: ct || void 0, size: rt.size }
        });
      };
      if (opts.bodies && TEXT_TYPES.test(ct)) {
        res.clone().text().then(finish, () => finish(void 0));
      } else {
        setTimeout(() => finish(void 0), 0);
      }
      return res;
    }
    if (auto) {
      window.fetch = recordingFetch;
      const XHR = window.XMLHttpRequest.prototype;
      const open = XHR.open;
      const setHeader = XHR.setRequestHeader;
      const send = XHR.send;
      XHR.open = function(method, url, ...rest) {
        this._riq = { method, url: String(url), headers: {} };
        return open.call(this, method, url, ...rest);
      };
      XHR.setRequestHeader = function(k, v) {
        if (this._riq) this._riq.headers[String(k).toLowerCase()] = v;
        return setHeader.call(this, k, v);
      };
      XHR.send = function(body) {
        const info = this._riq;
        if (info && !ignore(info.url)) {
          info.start = Date.now();
          info.body = requestBodyText(body);
          this.addEventListener("loadend", () => {
            const headers = {};
            (this.getAllResponseHeaders() || "").trim().split(/[\r\n]+/).forEach((line) => {
              const i = line.indexOf(":");
              if (i > 0) headers[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
            });
            let text;
            try {
              if (this.responseType === "" || this.responseType === "text") text = this.responseText;
              else if (this.responseType === "json") text = JSON.stringify(this.response);
            } catch (e) {
            }
            const rt = resourceTiming(info.url, info.start);
            record({
              method: info.method,
              url: info.url,
              status: this.status,
              duration: Date.now() - info.start,
              timestamp: info.start,
              initiator: "xhr",
              protocol: rt.protocol,
              cached: rt.cached,
              timing: rt.timing,
              error: this.status === 0 ? "network error" : void 0,
              request: { headers: info.headers, body: info.body },
              response: { headers, body: text, content_type: headers["content-type"], size: rt.size }
            });
          });
        }
        return send.call(this, body);
      };
    }
    return { recordingFetch, record };
  }
  var LEVELS = ["debug", "info", "log", "warn", "error", "trace"];
  function consoleEvent(level, args, redact) {
    const lvl = level === "trace" ? "debug" : LEVELS.includes(level) ? level : "log";
    const err = args.find((a) => a instanceof Error);
    const message = args.map((a) => a instanceof Error ? `${a.name}: ${a.message}` : typeof a === "string" ? a : a !== null && typeof a === "object" ? safeString(redact.json(serializeArgs([a])[0])) : safeString(a)).join(" ");
    const structured = args.filter((a) => a !== null && typeof a === "object" && !(a instanceof Error));
    return {
      type: EVENT_TYPE_CUSTOM,
      subtype: "console",
      timestamp: Date.now(),
      level: lvl,
      message: redact.cards(message.slice(0, 4e3)),
      args: structured.length ? redact.json(serializeArgs(structured)) : void 0,
      stack: err ? stackOf(err) : level === "trace" ? stackOf(new Error()) : void 0
    };
  }
  function safeString(v) {
    try {
      return JSON.stringify(v);
    } catch (e) {
      return String(v);
    }
  }
  function interceptConsole(emit, redact) {
    for (const level of LEVELS) {
      const orig = console[level];
      if (typeof orig !== "function") continue;
      console[level] = function(...args) {
        try {
          emit(consoleEvent(level, args, redact));
        } catch (e) {
        }
        return orig.apply(console, args);
      };
    }
    window.addEventListener("error", (e) => {
      emit({
        type: EVENT_TYPE_CUSTOM,
        subtype: "js_error",
        message: redact.cards(e.message || ""),
        filename: e.filename,
        lineno: e.lineno,
        colno: e.colno,
        stack: stackOf(e.error),
        timestamp: Date.now()
      });
    });
    window.addEventListener("unhandledrejection", (e) => {
      const r = e.reason;
      emit({
        type: EVENT_TYPE_CUSTOM,
        subtype: "js_error",
        message: redact.cards("Unhandled rejection: " + (r && r.message ? r.message : String(r))),
        stack: stackOf(r),
        timestamp: Date.now()
      });
    });
  }

  // src/index.js
  var sdkLog = typeof console !== "undefined" ? console.log.bind(console) : () => {
  };
  var SDK_VERSION = true ? "1.2.0" : "dev";
  var SDK_NAME = `replayiq-web/${SDK_VERSION}`;
  var BATCH_SIZE = 50;
  var FLUSH_INTERVAL_MS = 5e3;
  var PAUSE_WHEN_HIDDEN_MS = 60 * 1e3;
  var PAUSE_WHEN_IDLE_MS = 10 * 60 * 1e3;
  var ACTIVITY_EVENTS = ["mousemove", "mousedown", "keydown", "scroll", "touchstart", "wheel"];
  var MAX_QUEUED_EVENTS = 1e3;
  var MAX_BACKOFF_MS = 60 * 1e3;
  var KEEPALIVE_MAX_BYTES = 6e4;
  var EVENT_TYPE_CUSTOM2 = 5;
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
  var ALWAYS_MASKED_INPUTS = 'input[type="password"],input[name*="card"],input[name*="cvv"],input[name*="cvc"],input[autocomplete^="cc-"]';
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
      onEvent({ type: EVENT_TYPE_CUSTOM2, subtype: "click", selector: getSelector(e.target), timestamp: now });
      const recent = clicks.filter((c) => now - c.t < 700 && c.target === e.target);
      if (recent.length >= 3) {
        onEvent({ type: EVENT_TYPE_CUSTOM2, subtype: "rage_click", x: e.clientX, y: e.clientY, selector: getSelector(e.target), timestamp: now });
      }
      if (clicks.length > 10) clicks.shift();
    }, true);
    document.addEventListener("input", (e) => {
      onEvent({ type: EVENT_TYPE_CUSTOM2, subtype: "input", selector: getSelector(e.target), timestamp: Date.now() });
    }, true);
  }
  function watchNavigation(onEvent) {
    let last = location.href;
    const check = () => {
      if (location.href === last) return;
      last = location.href;
      onEvent({ type: EVENT_TYPE_CUSTOM2, subtype: "navigate", url: last, message: document.title, timestamp: Date.now() });
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
        metadata: config.metadata || {},
        // Recording API v1.2: masked (default) or raw, and what to capture.
        dataMode: config.dataMode === "raw" ? "raw" : "masked",
        capture: { replay: true, console: true, network: true, networkBodies: true, ...config.capture || {} },
        network: { maxBodyBytes: 65536, ignoreUrls: [], redactHeaders: [], maskBodyKeys: [], ...config.network || {} }
      };
      this.redact = makeRedactor(this.config.network);
      if (getItem("session", "__riq_mode") !== this.config.dataMode) {
        setItem("session", "__riq_sid", generateId());
        setItem("session", "__riq_seq", "0");
        setItem("session", "__riq_mode", this.config.dataMode);
      }
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
      if (this.config.debug) sdkLog("[ReplayIQ]", ...args);
    }
    /** ReplayIQ.log: a console line from code (level: debug|info|log|warn|error). */
    logLine(message, level = "log", data) {
      const args = data === void 0 ? [message] : [message, data];
      this._push(consoleEvent(level, args, this.redact));
    }
    _ignoreUrl(url) {
      if (this._isOwnRequest(url)) return true;
      return this.config.network.ignoreUrls.some((p) => p instanceof RegExp ? p.test(url) : String(url).startsWith(p));
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
        metadata: { platform: "web", data_mode: this.config.dataMode, ...this.config.metadata },
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
        data_mode: this.config.dataMode,
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
      const { capture } = this.config;
      this.net = createNetworkCapture({
        bodies: capture.networkBodies,
        maxBodyBytes: this.config.network.maxBodyBytes,
        ignore: (url) => this._ignoreUrl(url),
        redact: this.redact,
        emit: push
      }, capture.network);
      if (capture.console) interceptConsole(push, this.redact);
      detectBehaviors(push);
      watchNavigation(push);
      this._watchActivity();
      if (!capture.replay) return true;
      if (this.config.dataMode === "raw") this._tagMaskedElements();
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
        ...this.config.dataMode === "raw" ? {
          // Raw: record what masked mode would hide (tagged data-riq-masked
          // for the server's masked copy); passwords and card fields stay
          // masked in the browser (always masked).
          blockClass: "riq-never-blocked",
          maskInputOptions: { password: true },
          maskInputSelector: ALWAYS_MASKED_INPUTS
        } : {
          blockClass: buildBlockClass(this.config.maskSelectors),
          maskInputOptions: { password: true, email: false },
          maskInputSelector: PII_SELECTORS.join(",")
        },
        collectFonts: true,
        recordCanvas: false,
        // Keyframes (Meta + FullSnapshot) that replay can start from: at
        // least every 30 s of activity, so a seek replays at most that.
        checkoutEveryNth: 200,
        checkoutEveryNms: 3e4
      });
    }
    // Raw mode: mark elements masked mode would block or mask, so the
    // server's masked copy can hide them; new elements are marked as added.
    _tagMaskedElements() {
      const classes = ["riq-mask", ...this.config.maskSelectors].map((c) => "." + CSS.escape(c));
      const selector = [...PII_SELECTORS, ...classes].join(",");
      const tag = (root) => {
        try {
          if (root.matches && root.matches(selector)) root.setAttribute("data-riq-masked", "");
          root.querySelectorAll && root.querySelectorAll(selector).forEach((el) => el.setAttribute("data-riq-masked", ""));
        } catch (e) {
        }
      };
      tag(document.documentElement);
      new MutationObserver((list) => {
        for (const m of list) m.addedNodes.forEach((n) => {
          if (n.nodeType === 1) tag(n);
        });
      }).observe(document.documentElement, { childList: true, subtree: true });
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
    init(keyOrConfig, options) {
      const config = typeof keyOrConfig === "string" ? { ...options || {}, key: keyOrConfig } : keyOrConfig;
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
    /** A console line from code: level debug | info | log | warn | error; data: any object. */
    log(message, level = "log", data) {
      var _a;
      (_a = this._instance) == null ? void 0 : _a.logLine(message, level, data);
    },
    /** An error from code, with its stack (console level "error"). */
    logError(error, data) {
      var _a;
      const e = error instanceof Error ? error : new Error(String(error));
      (_a = this._instance) == null ? void 0 : _a._push(consoleEvent("error", data === void 0 ? [e] : [e, data], this._instance.redact));
    },
    /** Records a request made by any client: { method, url, status, duration, request, response, timing, error }. */
    recordNetwork(entry) {
      var _a, _b;
      (_b = (_a = this._instance) == null ? void 0 : _a.net) == null ? void 0 : _b.record({ initiator: "manual", ...entry });
    },
    /** A fetch that is always recorded, even with capture.network off. */
    fetch(input, init) {
      var _a;
      return ((_a = this._instance) == null ? void 0 : _a.net) ? this._instance.net.recordingFetch(input, init) : fetch(input, init);
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
