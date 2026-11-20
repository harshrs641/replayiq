# @replayiq/web

> How it records, what it sends and how a recording replays: [RECORDING.md](RECORDING.md).

Session replay, errors, console and network capture for websites, sent to
[ReplayIQ](https://github.com/harshrs641/replayiq). Implements the
[Recording API v1](../../docs/sdk/recording-api-v1.md).

## Install

```bash
npm install @replayiq/web
```

```js
import ReplayIQ from '@replayiq/web';

ReplayIQ.init('<ingest key>', { endpoint: 'https://ingest.your-replayiq-host' });
```

That one call records all three streams: the **rendering** (replay),
**console logs** and **network logs**.

rrweb (the DOM recorder) is imported lazily, after the page has loaded, so
your bundler puts it in its own chunk.

## Script tag / CDN

```html
<script src="https://cdn.jsdelivr.net/npm/@replayiq/web@1/dist/replayiq.min.js"></script>
<script>
  ReplayIQ.init({ endpoint: 'https://ingest.your-replayiq-host', key: '<ingest key>' });
</script>
```

The script loads `rrweb.min.js` from the same folder, so only one script
host needs to be allowed by your Content Security Policy. Self-hosted
ReplayIQ serves both files at `/sdk/replayiq.js` and `/sdk/rrweb.min.js`.

## Options

| Option | Default | |
|---|---|---|
| `key` | – | Project ingest key (required) |
| `endpoint` | `http://localhost:8080` | Ingest host |
| `sampleRate` | `1` | Share of sessions recorded, decided once per session |
| `maskSelectors` | `[]` | Extra class names to block from recording |
| `pauseWhenHiddenMs` | `60000` | Pause in a hidden tab after this long (0 = never) |
| `pauseWhenIdleMs` | `600000` | Pause after this long without input (0 = never) |
| `debug` | `false` | Log the SDK's own debug output (never recorded) |
| `dataMode` | `'masked'` | `'masked'`: only masked data leaves the browser, one copy stored. `'raw'`: unmasked values are sent; the server stores raw and masked copies and the dashboard gets a Masked / Unmasked switch |
| `capture` | all `true` | `{ replay, console, network, networkBodies }`: turn a stream off |
| `network.maxBodyBytes` | `65536` | Request/response bodies are cut here (`truncated: true`) |
| `network.ignoreUrls` | `[]` | URL prefixes (strings) or RegExps never recorded |
| `network.redactHeaders` | `[]` | Extra header names whose values are redacted |
| `network.maskBodyKeys` | `[]` | Extra JSON/form/query keys whose values are redacted |

Always redacted, in both modes (cannot be turned off): `authorization`,
`cookie`, `set-cookie`, `x-api-key` and similar headers; card numbers
(Luhn); values of keys like `password`, `token`, `access_token`, `cvv`,
`card_number`, `secret` in JSON, form bodies, query strings and console
arguments; password and card inputs.

## API

- `identify(userId, traits)` · `track(name, properties)`
- `optOut()` / `optIn()` / `isOptedOut()` for consent
- `stop()` · `getSessionId()`
- `log(message, level = 'log', data)`: a console line from code (`debug`,
  `info`, `log`, `warn`, `error`); `data` is kept as structured arguments
- `logError(error, data)`: an `error` line with the error's stack
- `fetch(input, init)`: a fetch that is always recorded, for when
  `capture.network` is off or you want only some requests recorded
- `recordNetwork({ method, url, status, duration, request, response, timing, error })`:
  record a request made by other means (WebSocket RPC, a native bridge…);
  the same redaction applies

```js
ReplayIQ.log('checkout loaded', 'info', { cart: 3 });
ReplayIQ.logError(err, { step: 'pay' });
const res = await ReplayIQ.fetch('/api/pay', { method: 'POST', body });
```

In masked mode, passwords, emails, card/CVV/SSN/phone inputs and anything
with `data-riq-mask` or class `riq-mask` are masked in the browser. In raw
mode only password and card inputs are; the other elements are recorded
with a `data-riq-masked` attribute so the server can build the masked copy.

## Release

```bash
npm run build   # dist/ + ../replayiq.js for the self-hosted server
npm publish --access public
```
