export type LogLevel = 'debug' | 'info' | 'log' | 'warn' | 'error';

export interface NetworkEntry {
  method?: string;
  url: string;
  status?: number;
  duration?: number;
  error?: string;
  request?: { headers?: Record<string, string>; body?: string; size?: number };
  response?: { headers?: Record<string, string>; body?: string; size?: number; content_type?: string };
  timing?: { dns?: number; connect?: number; tls?: number; ttfb?: number; download?: number };
  timestamp?: number;
}

export interface ReplayIQConfig {
  /** "masked" (default): only masked data leaves the browser. "raw": recorded unmasked (except passwords, card data and secrets); the server also keeps a masked copy. */
  dataMode?: 'masked' | 'raw';
  /** What to record automatically (all on by default). */
  capture?: { replay?: boolean; console?: boolean; network?: boolean; networkBodies?: boolean };
  /** Network log options. */
  network?: { maxBodyBytes?: number; ignoreUrls?: (string | RegExp)[]; redactHeaders?: string[]; maskBodyKeys?: string[] };
  /** Your project's ingest key (write-only; safe to ship in pages). */
  key?: string;
  /** Legacy: project id. Used as the key when `key` is not set. */
  projectId?: string;
  /** Ingest host, e.g. "https://ingest.replayiq.example". */
  endpoint?: string;
  /** Share of sessions to record, 0–1 (default 1). Decided once per session. */
  sampleRate?: number;
  /** Extra class names whose elements are blocked from recording. */
  maskSelectors?: string[];
  /** Pause recording in a tab hidden this long (ms, default 60000; 0 = never). */
  pauseWhenHiddenMs?: number;
  /** Pause after this long with no input (ms, default 600000; 0 = never). */
  pauseWhenIdleMs?: number;
  /** Script-tag build only: where to load rrweb from (default: next to the SDK). */
  rrwebUrl?: string;
  /** Extra session metadata (string values). */
  metadata?: Record<string, string>;
  /** Log SDK activity to the console. */
  debug?: boolean;
  /** Custom transport (e.g. a browser extension). Resolve with the Response if you have it. */
  transport?: (url: string, options: RequestInit) => Promise<Response | void>;
}

export interface ReplayIQInstance {
  /** Whether this session is being recorded (sampling, opt-out). */
  readonly sampled: boolean;
  readonly sessionId: string;
  getSessionId(): string;
  identify(userId: string, traits?: Record<string, string>): void;
  track(name: string, properties?: Record<string, unknown>): void;
  stop(): void;
}

declare const ReplayIQ: {
  readonly version: string;
  init(key: string, options?: ReplayIQConfig): Promise<ReplayIQInstance>;
  init(config: ReplayIQConfig): Promise<ReplayIQInstance>;
  /** A console line from code. */
  log(message: string, level?: LogLevel, data?: unknown): void;
  /** An error from code, with its stack. */
  logError(error: unknown, data?: unknown): void;
  /** Records a request made by any HTTP client. */
  recordNetwork(entry: NetworkEntry): void;
  /** A fetch that is always recorded. */
  fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
  identify(userId: string, traits?: Record<string, string>): void;
  track(name: string, properties?: Record<string, unknown>): void;
  stop(): void;
  getSessionId(): string | undefined;
  /** Stop recording now and on future visits, until optIn(). */
  optOut(): void;
  /** Allow recording again (from the next page load). */
  optIn(): void;
  isOptedOut(): boolean;
};

export default ReplayIQ;
