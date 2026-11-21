// Always-masked data (Recording API v1.2 §4), applied in the browser in
// both data modes: secret header values, card numbers (Luhn) and values of
// sensitive keys in JSON / form bodies and query strings. The server
// applies the same rules again.

export const REDACTED = '[redacted]';

const SECRET_HEADERS = new Set([
  'authorization', 'proxy-authorization', 'cookie', 'set-cookie',
  'x-api-key', 'x-auth-token', 'x-csrf-token', 'x-xsrf-token',
]);

const SENSITIVE_KEYS = new Set([
  'password', 'passwd', 'pwd', 'secret', 'clientsecret', 'token', 'accesstoken', 'refreshtoken',
  'idtoken', 'authtoken', 'apikey', 'privatekey', 'otp', 'pin', 'cvv', 'cvc', 'cvv2',
  'cardnumber', 'pan', 'securitycode', 'ssn',
]);

const norm = k => String(k).toLowerCase().replace(/[_\-\s]/g, '');

export function makeRedactor({ redactHeaders = [], maskBodyKeys = [] } = {}) {
  const headers = new Set([...SECRET_HEADERS, ...redactHeaders.map(h => h.toLowerCase())]);
  const keys = new Set([...SENSITIVE_KEYS, ...maskBodyKeys.map(norm)]);
  const sensitive = k => keys.has(norm(k));

  function cards(s) {
    if (typeof s !== 'string' || s.length < 13) return s;
    return s.replace(/\b\d(?:[ -]?\d){12,18}\b/g, m => {
      const d = m.replace(/\D/g, '');
      return d.length >= 13 && d.length <= 19 && luhn(d) ? REDACTED : m;
    });
  }

  function json(v, depth = 0) {
    if (depth > 20) return v;
    if (Array.isArray(v)) return v.map(x => json(x, depth + 1));
    if (v && typeof v === 'object') {
      const out = {};
      for (const [k, val] of Object.entries(v)) out[k] = sensitive(k) && val != null ? REDACTED : json(val, depth + 1);
      return out;
    }
    return typeof v === 'string' ? cards(v) : v;
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
    body(text, contentType = '') {
      if (typeof text !== 'string' || !text) return text;
      const t = text.trim();
      if (t.startsWith('{') || t.startsWith('[')) {
        try { return JSON.stringify(json(JSON.parse(t))); } catch (e) { /* not JSON */ }
      }
      if (contentType.includes('x-www-form-urlencoded') || (/^[^\s{<]+=/.test(t) && !t.includes(' '))) {
        try { return params(t); } catch (e) { /* not a form */ }
      }
      return cards(text);
    },
  };
}

function luhn(d) {
  let sum = 0;
  let double = false;
  for (let i = d.length - 1; i >= 0; i--) {
    let n = d.charCodeAt(i) - 48;
    if (double) { n *= 2; if (n > 9) n -= 9; }
    sum += n;
    double = !double;
  }
  return sum % 10 === 0;
}

/** Console arguments as JSON values: depth ≤ 4, ≤ 8 KB in all. */
export function serializeArgs(args) {
  const seen = new WeakSet();
  function conv(v, depth) {
    if (v === null || typeof v === 'number' || typeof v === 'boolean') return v;
    if (typeof v === 'string') return v.length > 2000 ? v.slice(0, 2000) + '…' : v;
    if (typeof v === 'undefined') return '[undefined]';
    if (typeof v === 'function') return `[function ${v.name || 'anonymous'}]`;
    if (typeof v === 'symbol' || typeof v === 'bigint') return String(v);
    if (v instanceof Error) return { name: v.name, message: v.message, stack: (v.stack || '').slice(0, 2000) };
    if (typeof Element !== 'undefined' && v instanceof Element) return `<${v.tagName.toLowerCase()}${v.id ? '#' + v.id : ''}>`;
    if (seen.has(v)) return '[circular]';
    if (depth >= 4) return Array.isArray(v) ? `[array ${v.length}]` : '[object]';
    seen.add(v);
    if (Array.isArray(v)) return v.slice(0, 50).map(x => conv(x, depth + 1));
    const out = {};
    for (const k of Object.keys(v).slice(0, 50)) {
      try { out[k] = conv(v[k], depth + 1); } catch (e) { out[k] = '[unreadable]'; }
    }
    return out;
  }
  const out = args.map(a => conv(a, 0));
  const s = JSON.stringify(out);
  return s.length > 8192 ? [s.slice(0, 8192) + '…'] : out;
}
