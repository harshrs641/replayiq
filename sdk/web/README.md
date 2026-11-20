# @replayiq/web

Session replay, errors, console and network capture for websites, sent to
[ReplayIQ](https://github.com/harshrs641/replayiq). Implements the
[Recording API v1](../../docs/sdk/recording-api-v1.md).

## Install

```bash
npm install @replayiq/web
```

```js
import ReplayIQ from '@replayiq/web';

ReplayIQ.init({ endpoint: 'https://ingest.your-replayiq-host', key: '<ingest key>' });
```

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
| `debug` | `false` | Log to the console |

## API

- `identify(userId, traits)` · `track(name, properties)`
- `optOut()` / `optIn()` / `isOptedOut()` for consent
- `stop()` · `getSessionId()`

Passwords, emails, card/CVV/SSN/phone inputs and anything with
`data-riq-mask` or class `riq-mask` are masked in the browser.

## Release

```bash
npm run build   # dist/ + ../replayiq.js for the self-hosted server
npm publish --access public
```
