// Parses the first frame of a JavaScript stack trace, for js_error's
// filename / lineno / colno. Handles Hermes and JSC/V8 formats:
//   "    at handlePress (address at index.android.bundle:1:52331)"
//   "    at handlePress (http://localhost:8081/index.bundle?platform=ios:120:14)"
//   "handlePress@http://localhost:8081/index.bundle:120:14"
export interface Frame {
  filename: string;
  line: number;
  column: number;
}

const FRAME = /(?:\(|@|at\s+)(?:address at\s+)?((?:[a-z]+:\/\/)?[^\s()@]+?):(\d+):(\d+)\)?\s*$/i;

export function firstFrame(stack: string | undefined | null): Frame | null {
  if (!stack) return null;
  for (const raw of stack.split('\n')) {
    const m = FRAME.exec(raw.trim());
    // Drop bundle URL parameters: "index.bundle?platform=ios&dev=true" and
    // iOS dev's "index.bundle//&platform=ios&dev=true".
    if (m) return { filename: m[1].replace(/(\?|\/\/&).*$/, ''), line: Number(m[2]), column: Number(m[3]) };
  }
  return null;
}
