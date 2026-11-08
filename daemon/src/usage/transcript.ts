import { closeSync, openSync, readSync, fstatSync } from "node:fs";

// Reads the usage numbers of the latest assistant message in a Claude Code transcript (HAIL-195).
// Only four integers leave this function. No message text, no tool input and no path is kept: the
// line is parsed, the `usage` object is read, and everything else is dropped. A transcript that
// cannot be read, or has no assistant message with usage, gives null (the field stays empty).

export interface ContextUsage {
  input: number;
  cache_read: number;
  cache_creation: number;
  output: number;
}

// A transcript line can hold a long message, so the tail read is generous but bounded.
const TAIL_BYTES = 2 * 1024 * 1024;

const int = (value: unknown): number =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.min(Math.floor(value), 2_000_000_000) : 0;

export function latestUsage(path: string): ContextUsage | null {
  let fd: number | null = null;
  try {
    fd = openSync(path, "r");
    const size = fstatSync(fd).size;
    const length = Math.min(size, TAIL_BYTES);
    const buffer = Buffer.alloc(length);
    readSync(fd, buffer, 0, length, size - length);
    const lines = buffer.toString("utf8").split("\n");
    // The first line of a tail read may be cut in the middle: it fails to parse and is skipped.
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i].trim();
      if (!line.startsWith("{") || !line.includes('"usage"')) continue;
      let parsed: unknown;
      try {
        parsed = JSON.parse(line);
      } catch {
        continue;
      }
      const entry = parsed as { type?: unknown; message?: { usage?: Record<string, unknown> } };
      const usage = entry.type === "assistant" ? entry.message?.usage : undefined;
      if (!usage || typeof usage !== "object") continue;
      return {
        input: int(usage.input_tokens),
        cache_read: int(usage.cache_read_input_tokens),
        cache_creation: int(usage.cache_creation_input_tokens),
        output: int(usage.output_tokens),
      };
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== null) {
      try {
        closeSync(fd);
      } catch {
        // Nothing left to do.
      }
    }
  }
}
