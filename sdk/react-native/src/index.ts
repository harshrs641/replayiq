// ReplayIQ for React Native: a thin layer over the native iOS and Android
// SDKs (which record the screen, touches, network and native crashes), plus
// what only JavaScript can see: JS errors, console warnings/errors, and
// React Navigation screens.
import * as React from 'react';
import { NativeModules, Platform, View, type ViewProps } from 'react-native';
import { firstFrame } from './stack';

export { firstFrame } from './stack';

const VERSION = '1.0.0';
/** nativeID that the native SDKs mask (see ReplayIQMask). */
export const MASK_NATIVE_ID = 'replayiq-mask';

type Native = {
  start(key: string, endpoint: string, options: Record<string, unknown>): void;
  identify(userId: string, traits: Record<string, string>): void;
  track(name: string, properties: Record<string, unknown>): void;
  screen(name: string): void;
  log(message: string, level: string): void;
  recordError(message: string, stack: string, filename: string, line: number, column: number): void;
  optOut(): void;
  optIn(): void;
  stop(): void;
  reset(): void;
  flush(): void;
  getSessionId(): Promise<string | null>;
};

const native: Native | undefined = NativeModules.ReplayIQRN;

export interface ReplayIQOptions {
  /** Share of sessions to record, 0–1 (default 1). Decided once per session. */
  sampleRate?: number;
  /** "auto" (default: Native DOM, screenshots for screens that need them), "nativeDom" or "screenshot". */
  recordingMode?: 'auto' | 'nativeDom' | 'screenshot';
  /** Mask every text input (default true). Password fields are always masked. */
  maskAllTextInputs?: boolean;
  /** Mask all text, not just inputs (default false). */
  maskAllText?: boolean;
  /** Record console.warn / console.error (default true). */
  captureConsole?: boolean;
  /** Record uncaught JS errors (default true). */
  captureErrors?: boolean;
  /** Extra session metadata. */
  metadata?: Record<string, string>;
  /** Log SDK activity (default: on in __DEV__). */
  debug?: boolean;
}

let started = false;

function warnMissing() {
  console.log(
    `[ReplayIQ] native module not found: rebuild the app after installing @replayiq/react-native` +
      (Platform.OS === 'ios' ? ' (run pod install).' : '.'),
  );
}

function safe(fn: () => void) {
  try {
    fn();
  } catch (e) {
    // Never break the app because of the SDK.
  }
}

/** Starts recording. Call once, as early as possible (e.g. in index.js). */
export function init(key: string, endpoint: string, options: ReplayIQOptions = {}): void {
  if (started) return;
  if (!native) {
    warnMissing();
    return;
  }
  started = true;
  const { captureConsole = true, captureErrors = true, ...nativeOptions } = options;
  safe(() =>
    native.start(key, endpoint, {
      ...nativeOptions,
      debug: options.debug ?? __DEV__,
      sdk: `replayiq-react-native/${VERSION}`,
      maskNativeID: MASK_NATIVE_ID,
    }),
  );
  if (captureErrors) installErrorHandler();
  if (captureConsole) installConsole();
}

/** Sets the user for this and later sessions. */
export function identify(userId: string, traits: Record<string, string> = {}): void {
  safe(() => native?.identify(String(userId), traits));
}

/** Records one of the app's own named events. */
export function track(name: string, properties: Record<string, unknown> = {}): void {
  safe(() => native?.track(name, properties));
}

/** Records a screen change. Not needed with trackNavigation(). */
export function screen(name: string): void {
  safe(() => native?.screen(name));
}

/** Sends a line to the Console tab. */
export function log(message: string, level: 'log' | 'warn' | 'error' = 'log'): void {
  safe(() => native?.log(message, level));
}

/** Records a handled error (shown in the Console tab and used by the AI analysis). */
export function recordError(error: unknown): void {
  const e = error instanceof Error ? error : new Error(String(error));
  const stack = e.stack || '';
  const frame = firstFrame(stack);
  safe(() => native?.recordError(`${e.name}: ${e.message}`, stack, frame?.filename ?? '', frame?.line ?? 0, frame?.column ?? 0));
}

/** Stops recording now and on later launches, until optIn(). */
export function optOut(): void {
  safe(() => native?.optOut());
}

export function optIn(): void {
  safe(() => native?.optIn());
}

/** Stops recording and ends the session. */
export function stop(): void {
  safe(() => native?.stop());
}

/** Ends the session and starts a new one (e.g. on logout). */
export function reset(): void {
  safe(() => native?.reset());
}

/** Sends buffered events now. */
export function flush(): void {
  safe(() => native?.flush());
}

export function getSessionId(): Promise<string | null> {
  return native ? native.getSessionId() : Promise.resolve(null);
}

// ── JS errors ────────────────────────────────────────────────────────────────

function installErrorHandler() {
  const g = globalThis as any;
  const errorUtils = g.ErrorUtils;
  if (!errorUtils?.setGlobalHandler) return;
  const previous = errorUtils.getGlobalHandler?.();
  errorUtils.setGlobalHandler((error: unknown, isFatal?: boolean) => {
    recordError(error);
    // A fatal JS error usually ends the app: send what we have first.
    if (isFatal) flush();
    previous?.(error, isFatal);
  });
}

// ── Console ──────────────────────────────────────────────────────────────────

function installConsole() {
  for (const level of ['warn', 'error'] as const) {
    const original = console[level];
    console[level] = (...args: unknown[]) => {
      safe(() => {
        const err = args.find(a => a instanceof Error) as Error | undefined;
        const message = args.map(a => (a instanceof Error ? `${a.name}: ${a.message}` : typeof a === 'string' ? a : stringify(a))).join(' ');
        if (err) recordErrorAsLog(message, err, level);
        else native?.log(message.slice(0, 4000), level);
      });
      original.apply(console, args);
    };
  }
}

function recordErrorAsLog(message: string, err: Error, level: 'warn' | 'error') {
  native?.log(`${message}\n${err.stack || ''}`.slice(0, 8000), level);
}

function stringify(v: unknown): string {
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

// ── Navigation ───────────────────────────────────────────────────────────────

type NavigationRef = {
  addListener(event: 'state', cb: () => void): () => void;
  getCurrentRoute(): { name: string } | undefined;
  isReady?(): boolean;
};

/**
 * Records React Navigation screen changes. Pass the container's ref:
 *   const navigationRef = createNavigationContainerRef();
 *   <NavigationContainer ref={navigationRef} onReady={() => trackNavigation(navigationRef)}>
 * Returns a function that stops tracking.
 */
export function trackNavigation(ref: NavigationRef): () => void {
  let last: string | undefined;
  const report = () => {
    const name = ref.getCurrentRoute()?.name;
    if (name && name !== last) {
      last = name;
      screen(name);
    }
  };
  report();
  return ref.addListener('state', report);
}

// ── Masking ──────────────────────────────────────────────────────────────────

/**
 * Masks its children in recordings: they're painted over / left out on the
 * device and never leave it. Text inputs are masked without it.
 */
export function ReplayIQMask(props: ViewProps) {
  // collapsable={false}: the view must exist natively to be found.
  return React.createElement(View, { ...props, nativeID: MASK_NATIVE_ID, collapsable: false });
}

const ReplayIQ = {
  init, identify, track, screen, log, recordError, optOut, optIn, stop, reset, flush, getSessionId, trackNavigation,
};
export default ReplayIQ;
