// Console and network capture (Recording API v1.2 §2–3).
import { serializeArgs } from './redact.js';

const EVENT_TYPE_CUSTOM = 5;
const TEXT_TYPES = /json|text\/|x-www-form-urlencoded|xml|graphql|javascript/i;

function stackOf(err) {
  return err && typeof err.stack === 'string' ? err.stack.slice(0, 4000) : undefined;
}

function truncate(text, max) {
  if (typeof text !== 'string') return { body: undefined, truncated: false };
  return text.length > max ? { body: text.slice(0, max), truncated: true } : { body: text, truncated: false };
}

/** Text of a fetch/XHR request body, when it is text-like. */
function requestBodyText(body) {
  if (body == null) return undefined;
  if (typeof body === 'string') return body;
  if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) return body.toString();
  return undefined; // FormData, Blob, ArrayBuffer, streams: size only, never read
}

function headersObject(h) {
  const out = {};
  if (!h) return out;
  if (typeof h.forEach === 'function' && !(Array.isArray(h))) { h.forEach((v, k) => { out[k.toLowerCase()] = v; }); return out; }
  if (Array.isArray(h)) { for (const [k, v] of h) out[String(k).toLowerCase()] = v; return out; }
  for (const k of Object.keys(h)) out[k.toLowerCase()] = h[k];
  return out;
}

/** Timing, protocol and cache info from the Resource Timing entry for url. */
function resourceTiming(url, startedAt) {
  try {
    const abs = new URL(url, location.href).href;
    const entries = performance.getEntriesByName(abs, 'resource');
    const e = entries.filter(x => performance.timeOrigin + x.startTime >= startedAt - 50).pop() || entries.pop();
    if (!e) return {};
    const ms = (a, b) => (a > 0 && b > 0 && b >= a ? Math.round(b - a) : undefined);
    const timing = {
      dns: ms(e.domainLookupStart, e.domainLookupEnd),
      connect: ms(e.connectStart, e.connectEnd),
      tls: e.secureConnectionStart > 0 ? ms(e.secureConnectionStart, e.connectEnd) : undefined,
      ttfb: ms(e.requestStart, e.responseStart),
      download: ms(e.responseStart, e.responseEnd),
    };
    return {
      timing,
      protocol: e.nextHopProtocol || undefined,
      cached: e.transferSize === 0 && e.decodedBodySize > 0,
      size: e.encodedBodySize || undefined,
    };
  } catch (err) {
    return {};
  }
}

/**
 * Network capture. Returns { recordingFetch, record } and, when `auto`,
 * patches window.fetch and XMLHttpRequest. `opts`: { bodies, maxBodyBytes,
 * ignore(url), redact, emit(event) }.
 */
export function createNetworkCapture(opts, auto) {
  const { redact, emit, ignore, maxBodyBytes = 65536 } = opts;
  const origFetch = window.fetch.bind(window);

  function record(e) {
    if (!e || !e.url || ignore(e.url)) return;
    const ev = {
      type: EVENT_TYPE_CUSTOM, subtype: 'network', timestamp: e.timestamp || Date.now(),
      method: String(e.method || 'GET').toUpperCase(), url: redact.url(e.url),
      status: e.status || 0, duration: e.duration, error: e.error ? String(e.error).slice(0, 1000) : undefined,
      protocol: e.protocol, cached: e.cached, initiator: e.initiator, timing: e.timing,
    };
    for (const side of ['request', 'response']) {
      const s = e[side];
      if (!s) continue;
      const ct = (s.content_type || (s.headers && headersObject(s.headers)['content-type']) || '').toString();
      const out = { headers: redact.headers(headersObject(s.headers)), size: s.size };
      if (s.content_type) out.content_type = s.content_type;
      if (opts.bodies && typeof s.body === 'string' && (!ct || TEXT_TYPES.test(ct))) {
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
    const url = typeof input === 'string' ? input : (input && (input.url || String(input)));
    const method = (init && init.method) || (input && input.method) || 'GET';
    if (!url || ignore(url)) return origFetch(input, init);
    const reqHeaders = headersObject((init && init.headers) || (input && input.headers));
    const reqBody = requestBodyText(init && init.body);
    let res;
    try {
      res = await origFetch(input, init);
    } catch (err) {
      record({ method, url, status: 0, error: err && err.message, duration: Date.now() - startedAt, timestamp: startedAt,
        initiator: 'fetch', request: { headers: reqHeaders, body: reqBody } });
      throw err;
    }
    const duration = Date.now() - startedAt;
    const resHeaders = headersObject(res.headers);
    const ct = resHeaders['content-type'] || '';
    const finish = text => {
      const rt = resourceTiming(url, startedAt);
      record({ method, url, status: res.status, duration, timestamp: startedAt, initiator: 'fetch',
        protocol: rt.protocol, cached: rt.cached, timing: rt.timing,
        request: { headers: reqHeaders, body: reqBody },
        response: { headers: resHeaders, body: text, content_type: ct || undefined, size: rt.size } });
    };
    if (opts.bodies && TEXT_TYPES.test(ct)) {
      // Read a clone in the background: the app's response is untouched.
      res.clone().text().then(finish, () => finish(undefined));
    } else {
      setTimeout(() => finish(undefined), 0);
    }
    return res;
  }

  if (auto) {
    window.fetch = recordingFetch;
    const XHR = window.XMLHttpRequest.prototype;
    const open = XHR.open;
    const setHeader = XHR.setRequestHeader;
    const send = XHR.send;
    XHR.open = function (method, url, ...rest) {
      this._riq = { method, url: String(url), headers: {} };
      return open.call(this, method, url, ...rest);
    };
    XHR.setRequestHeader = function (k, v) {
      if (this._riq) this._riq.headers[String(k).toLowerCase()] = v;
      return setHeader.call(this, k, v);
    };
    XHR.send = function (body) {
      const info = this._riq;
      if (info && !ignore(info.url)) {
        info.start = Date.now();
        info.body = requestBodyText(body);
        this.addEventListener('loadend', () => {
          const headers = {};
          (this.getAllResponseHeaders() || '').trim().split(/[\r\n]+/).forEach(line => {
            const i = line.indexOf(':');
            if (i > 0) headers[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
          });
          let text;
          try {
            if (this.responseType === '' || this.responseType === 'text') text = this.responseText;
            else if (this.responseType === 'json') text = JSON.stringify(this.response);
          } catch (e) { /* unreadable */ }
          const rt = resourceTiming(info.url, info.start);
          record({ method: info.method, url: info.url, status: this.status, duration: Date.now() - info.start,
            timestamp: info.start, initiator: 'xhr', protocol: rt.protocol, cached: rt.cached, timing: rt.timing,
            error: this.status === 0 ? 'network error' : undefined,
            request: { headers: info.headers, body: info.body },
            response: { headers, body: text, content_type: headers['content-type'], size: rt.size } });
        });
      }
      return send.call(this, body);
    };
  }

  return { recordingFetch, record };
}

const LEVELS = ['debug', 'info', 'log', 'warn', 'error', 'trace'];

/** A console event from a message, level and optional data/args. */
export function consoleEvent(level, args, redact) {
  const lvl = level === 'trace' ? 'debug' : (LEVELS.includes(level) ? level : 'log');
  const err = args.find(a => a instanceof Error);
  // Objects go through key redaction before they become text.
  const message = args.map(a => (a instanceof Error ? `${a.name}: ${a.message}`
    : typeof a === 'string' ? a
      : a !== null && typeof a === 'object' ? safeString(redact.json(serializeArgs([a])[0])) : safeString(a))).join(' ');
  const structured = args.filter(a => a !== null && typeof a === 'object' && !(a instanceof Error));
  return {
    type: EVENT_TYPE_CUSTOM, subtype: 'console', timestamp: Date.now(), level: lvl,
    message: redact.cards(message.slice(0, 4000)),
    args: structured.length ? redact.json(serializeArgs(structured)) : undefined,
    stack: err ? stackOf(err) : (level === 'trace' ? stackOf(new Error()) : undefined),
  };
}

function safeString(v) {
  try { return JSON.stringify(v); } catch (e) { return String(v); }
}

/** Patches every console level; uncaught errors become js_error. */
export function interceptConsole(emit, redact) {
  for (const level of LEVELS) {
    const orig = console[level];
    if (typeof orig !== 'function') continue;
    console[level] = function (...args) {
      try { emit(consoleEvent(level, args, redact)); } catch (e) { /* never break logging */ }
      return orig.apply(console, args);
    };
  }
  window.addEventListener('error', e => {
    emit({ type: EVENT_TYPE_CUSTOM, subtype: 'js_error', message: redact.cards(e.message || ''), filename: e.filename,
      lineno: e.lineno, colno: e.colno, stack: stackOf(e.error), timestamp: Date.now() });
  });
  window.addEventListener('unhandledrejection', e => {
    const r = e.reason;
    emit({ type: EVENT_TYPE_CUSTOM, subtype: 'js_error', message: redact.cards('Unhandled rejection: ' + (r && r.message ? r.message : String(r))),
      stack: stackOf(r), timestamp: Date.now() });
  });
}
