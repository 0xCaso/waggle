import { spawn, spawnSync } from "node:child_process";

// The result of running an external command. `status` is null when the command
// could not be started, timed out, or was killed by a signal; `error` carries
// the spawn failure message (for example ENOENT when the binary is not on
// PATH).
export interface RunResult {
  status: number | null;
  stdout: string;
  stderr: string;
  error?: string;
}

// A bound on every exec call below: `claude mcp list`/`codex mcp list` probe
// each configured MCP server's live connectivity, which can stall far past
// the ~8s this normally takes (KNOCK-20 fold pass 2 traced a live `knock
// doctor` hang to exactly this — `claude mcp list` sitting on an open TCP
// connection with no timeout, so the M1 "Checking..." step never resolved).
// A timed-out call reports `status: null`, which every caller here already
// treats the same as "not ok" — a slow runtime reads as unregistered rather
// than hanging the whole doctor probe forever.
const DEFAULT_TIMEOUT_MS = 15_000;

// Runs a command with the current environment. Tests stub `claude` by putting
// a fake earlier on PATH in the spawned process, so no real user settings are
// touched (KNOCK-06 acceptance). launchctl no longer goes through this helper:
// the legacy-LaunchAgent cleanup in service.ts uses an injected runner.
export function run(command: string, args: string[], timeoutMs = DEFAULT_TIMEOUT_MS): RunResult {
  const result = spawnSync(command, args, { encoding: "utf8", timeout: timeoutMs });
  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    error: result.error ? result.error.message : undefined,
  };
}

// The async twin of `run`, for callers that need more than one exec call to
// actually overlap on the wire rather than queue up behind each other (KNOCK-20:
// `waggle doctor` runs its Claude Code and Codex checks concurrently this way —
// see doctor.ts). `spawnSync` blocks the whole process for its duration, so
// two of them back to back can never overlap; `spawn` does not.
export function runAsync(
  command: string,
  args: string[],
  timeoutMs = DEFAULT_TIMEOUT_MS,
): Promise<RunResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let settled = false;
    let timedOut = false;

    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill();
      // Resolve now: a grandchild (an MCP server the CLI started for its
      // health check) can keep the pipes open, and then "close" never fires
      // and the caller waits forever ("Checking…" that never ends).
      child.stdout.destroy();
      child.stderr.destroy();
      finish({ status: null, stdout, stderr, error: `timed out after ${timeoutMs}ms` });
    }, timeoutMs);

    const finish = (result: RunResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };

    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (error) => {
      finish({ status: null, stdout, stderr, error: error.message });
    });
    child.on("close", (code) => {
      finish({
        status: code,
        stdout,
        stderr,
        error: timedOut ? `timed out after ${timeoutMs}ms` : undefined,
      });
    });
  });
}
