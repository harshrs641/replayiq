export interface ReplayIQConfig {
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
  init(config: ReplayIQConfig): Promise<ReplayIQInstance>;
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
