---
name: react-native-sdk
description: Map of the ReplayIQ React Native SDK (@replayiq/react-native in sdk/react-native) - a thin TypeScript layer over the native iOS and Android SDKs, the bridge modules, what JS adds, the example app wiring, tests, and where React Native recording bugs really live. Use before reading or changing anything in sdk/react-native or debugging a React Native recording.
---

# ReplayIQ React Native SDK

A **thin bridge**. Screen recording (Native DOM), touches, network (RN's
fetch/XHR go through NSURLSession and OkHttp) and native crashes are all done
by the native SDKs:

- iOS: `sdk/ios` (pod `ReplayIQ`). See the `ios-sdk` skill.
- Android: `sdk/android` (`:replayiq`). See the `android-sdk` skill.

JS adds only what native can't see: JS errors, console warnings and errors,
and React Navigation screen names.

**Most "React Native replay is wrong" bugs are in the native walkers.** RN
views are read there:
- iOS `DomWalker.swift` reads `RCTParagraphComponentView` text and 9-slice
  border images as borders.
- Android `internal/ReactNative.kt` reads Fabric and the old renderer by reflection.

Look there before touching the JS.

- What is captured: `sdk/react-native/RECORDING.md`
- Setup: `sdk/react-native/README.md`

## Files

| File | Role |
|---|---|
| `src/index.ts` | Public API: `init(key, endpoint, options)`, `identify`, `track`, `screen`, `log`, `recordError`, `optOut`/`optIn`, `stop`, `reset`, `flush`, `getSessionId()` (Promise), `trackNavigation(navigationRef)` (returns unsubscribe), `<ReplayIQMask>` (a View with `nativeID="replayiq-mask"`, which the native SDKs mask). Installs the global JS error handler and console hooks |
| `src/stack.ts` | `firstFrame()`: parses Hermes and JSC/V8 stack lines → filename/lineno/colno for `js_error` |
| `ios/ReplayIQRN.swift` + `ReplayIQRN.m` | `NativeModules.ReplayIQRN` → `ReplayIQ.*` (iOS) |
| `android/src/main/java/com/replayiq/reactnative/ReplayIQRNModule.kt`, `ReplayIQRNPackage.kt` | Same for Android. Hooks RN's OkHttp client |
| `replayiq-react-native.podspec`, `android/build.gradle` | Native packaging, which depends on the native SDKs |
| `test/stack.test.mjs` | Stack parser tests |

## Test

```bash
cd sdk/react-native && npm test     # node --test test/*.test.mjs
```

For native changes, run the native SDK's tests. See the iOS and Android skills.

## Example app (sdk/react-native/example)

- It depends on the bridge via `"@replayiq/react-native": "file:.."`.
- The iOS Podfile uses `pod 'ReplayIQ', :path => '../../../ios'`, so native
  iOS changes are picked up after `pod install`.
- Android uses the local `sdk/android` library.

```bash
cd sdk/react-native/example
npm install
npm start                      # Metro
npm run ios                    # or: cd ios && pod install first
npm run android
```

Inspect the session with the `debug-replay` skill (repo root). Test session
ids are kept in `testing/react-native/`.

## Pitfalls

- After changing `src/` in the bridge, reinstall in the example
  (`file:..` copies) or restart Metro with a clean cache.
- After changing the iOS SDK, run `pod install` again in `example/ios`.
- The JS error handler chains to the previous one, so RN's red box still shows.
