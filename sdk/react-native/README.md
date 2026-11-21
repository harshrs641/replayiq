# @replayiq/react-native

> How it records, what it sends and how a recording replays: [RECORDING.md](RECORDING.md).

Session replay, touches, network, crashes and JS errors for React Native
apps, sent to [ReplayIQ](https://github.com/harshrs641/replayiq).

It is a thin layer over the native SDKs ([iOS](../ios), [Android](../android)),
which do the recording: React Native views are native views, so the screen is
recorded as a **Native DOM** (structure, not screenshots) like any native app,
with screenshots as the fallback for screens that need them. JavaScript adds
what only it can see: JS errors, `console.warn` / `console.error`, and screen
names from your navigator.

Implements the [Recording API v1 / v1.1](../../docs/sdk/).

## Install

```bash
npm install @replayiq/react-native
cd ios && pod install
```

Until the native SDKs are published:

- **iOS**: add the native SDK to your `Podfile`:
  `pod 'ReplayIQ', :path => '<path to replayiq>/sdk/ios'`
- **Android**: publish the native SDK to your local Maven repository once:
  `cd <path to replayiq>/sdk/android && ./gradlew :replayiq:publishToMavenLocal`,
  and add `mavenLocal()` to `allprojects { repositories { … } }` in your
  app's `android/build.gradle`.

React Native 0.74+ (old or New Architecture). The module is a classic native
module, which the New Architecture loads through its interop layer.

## Usage

```js
// index.js, before AppRegistry
import ReplayIQ from '@replayiq/react-native';

ReplayIQ.init('<ingest key>', 'https://ingest.your-replayiq-host', {
  sampleRate: 1,            // share of sessions recorded, decided per session
  recordingMode: 'auto',    // 'auto' | 'nativeDom' | 'screenshot'
});
```

```js
ReplayIQ.identify('user_123', { plan: 'pro' });
ReplayIQ.track('checkout_started', { total: 65 });
ReplayIQ.log('payment declined', 'error');     // Console tab
ReplayIQ.recordError(error);                    // handled errors
ReplayIQ.optOut(); ReplayIQ.optIn();            // consent
ReplayIQ.reset();                               // logout: new session
```

### Screens (React Navigation)

```jsx
import { NavigationContainer, createNavigationContainerRef } from '@react-navigation/native';
import { trackNavigation } from '@replayiq/react-native';

const navigationRef = createNavigationContainerRef();

<NavigationContainer ref={navigationRef} onReady={() => trackNavigation(navigationRef)}>
```

Without React Navigation, call `ReplayIQ.screen('Checkout')` when the screen
changes.

### Masking

Text inputs are masked by default (password fields always). To mask anything
else, wrap it:

```jsx
import { ReplayIQMask } from '@replayiq/react-native';

<ReplayIQMask><Text>{user.cardNumber}</Text></ReplayIQMask>
```

Masked content is painted over or left out **on the device**; it never
leaves it. `<ReplayIQMask>` is a `View` with `nativeID="replayiq-mask"`, which
the native SDKs mask on both renderers.

### Tap selectors

Taps are named from accessibility: give `Pressable`s an `accessibilityLabel`
(and `accessibilityRole="button"`) and they show as `button:"Pay now"` in the
dashboard and the AI analysis.

## What's recorded where

| | Recorded by |
|---|---|
| Screen (Native DOM / screenshots), touches, gestures, jank, hangs, lifecycle | native SDK |
| `fetch` / `XMLHttpRequest` | native SDK (iOS: NSURLSession; Android: OkHttp interceptor installed by the module) |
| Native crashes | native SDK (sent on next launch) |
| Uncaught JS errors (with stack and source line) | this package (`ErrorUtils` handler, chained to the previous one) |
| `console.warn` / `console.error` | this package |
| Screen names | `trackNavigation` / `screen()` |

Options: `captureErrors: false` / `captureConsole: false` turn the JS hooks
off; `maskAllTextInputs`, `maskAllText`, `metadata`, `debug`.

## Example

`example/` is a React Native 0.88 app (checkout, order list, a masked card, a
failing request, a throwing button) set up against a local ReplayIQ
(`./dev.sh`): iOS simulator → `http://localhost:8080`, Android emulator →
`http://10.0.2.2:8080`, key `verify`.

```bash
cd example && npm install
npx react-native start
npx react-native run-ios      # after: cd ios && pod install
npx react-native run-android  # after publishing the Android SDK to mavenLocal
```

## Tests

```bash
npm test   # JS stack-frame parsing (node --test)
```
