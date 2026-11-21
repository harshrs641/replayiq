# How the React Native SDK records, and how a recording replays

`@replayiq/react-native` is a thin layer over the native SDKs. The screen,
touches, network and native crashes are recorded by the [iOS SDK](../ios/RECORDING.md)
and the [Android SDK](../android/RECORDING.md), because React Native views are
real native views. JavaScript adds what only it can see. For setup see
[README](README.md).

## 1. What is captured, and where

| What | Captured in | How | Event |
|---|---|---|---|
| The screen | native SDK | Native DOM from the iOS layer tree / Android View tree, which hold React Native's views (Fabric and the old renderer). RN specifics: paragraph text read from the component's text (iOS) or precomputed layout (Android); border images and backgrounds read as real borders, colours and radii | `ui_snapshot`, `ui_mutation` (or `screen` for screens that are mostly islands) |
| Masking | native SDK + JS | Text inputs are masked by default. `<ReplayIQMask>` renders a `View` with `nativeID="replayiq-mask"`; the bridge registers a mask predicate so the native SDK masks any view with that id, on device | `mask` nodes |
| Touches, taps, gestures | native SDK | Named from accessibility: give `Pressable`s an `accessibilityLabel` and `accessibilityRole="button"` to get `button:"Pay now"` | `touch`, `click`, `rage_click`, `gesture` |
| `fetch` / `XMLHttpRequest` | native SDK | iOS: RN uses `NSURLSession`, recorded by the SDK's `URLProtocol`. Android: the bridge installs the SDK's OkHttp interceptor into RN's client factory | `network` |
| Native crashes | native SDK | Sent on the next launch | `js_error` |
| Uncaught JS errors | JS | `ErrorUtils.setGlobalHandler`, chained to the previous handler; the first stack frame gives file, line and column; fatal errors flush first | `js_error` (via `recordError`) |
| `console.warn` / `console.error` | JS | Wrapped; an `Error` argument adds its stack | `console` |
| Screen names | JS | `trackNavigation(navigationRef)` listens to React Navigation's state; or `ReplayIQ.screen(name)` | `navigate` |
| App state and performance | native SDK | Lifecycle, app start, jank, hangs, keyboard, connectivity… | the v1.1 signals |
| Identity, custom events, consent | JS → native | `identify`, `track`, `optOut`/`optIn`, `reset` call the native SDK | session user, `custom_events` |

Sessions are labelled `platform: "react-native"` and
`sdk: "replayiq-react-native/<version>"`.

## 2. What is sent

The native SDK sends everything: the same batches, queueing, gzip, retries and
`device_masked: true` as a native app (see the [iOS](../ios/RECORDING.md#2-what-is-sent)
and [Android](../android/RECORDING.md#2-what-is-sent) docs). A JS error looks like:

```json
{"type": 5, "subtype": "js_error", "timestamp": …,
 "message": "TypeError: Coupon service returned no discount",
 "filename": "index.android.bundle", "lineno": 1, "colno": 52331,
 "stack": "TypeError: Coupon service returned no discount\n    at anonymous (address at index.android.bundle:1:52331)…"}
```

In release builds the file and line point into the bundle; upload source maps
separately to map them back to source (not done by ReplayIQ yet).

## 3. What the server does, and how it renders

Exactly as for native apps: the transformer converts the Native DOM to an
rrweb page, and the dashboard's rrweb player rebuilds it in the browser. A
React Native screen replays with its real text, borders, rounded corners,
backgrounds, masks (striped blocks) and inputs (dots), and smooth scrolling.
JS errors and `console` lines appear in the Console tab and as timeline
markers, next to the native network requests and taps.

## 4. Not captured

What the native SDKs don't capture (system keyboard, dialogs on Android,
request bodies, field values), plus: JavaScript-only state (Redux, React
props), and in debug builds Metro's own requests also show in the Network tab.
