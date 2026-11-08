import { spawnSync } from "node:child_process";
import { basename } from "node:path";
import { isOlder } from "../version";

// The nudge (HAIL-76, docs/protocol-mvp.md "Reply not picked up"): the shim posts
// one line into its own Claude Code session's inbox socket, so a session that
// ended its turn starts a new one. The token in CLAUDE_CODE_MESSAGING_TOKEN stays
// in this process. It goes only into the socket and never into a log, an error
// message or an RPC to the daemon.

export const MIN_NUDGE_CLAUDE_VERSION = "2.1.224";
const POST_TIMEOUT_MS = 5000;

// HAIL-129: at most one nudge per case in this window. The daemon and the shim
// both enforce it (the shim survives a daemon restart). KNOCK_NUDGE_INTERVAL_MS
// is test-only.
export const NUDGE_INTERVAL_MS = 60_000;

export function nudgeIntervalMs(env: NodeJS.ProcessEnv = process.env): number {
  const parsed = Number(env.KNOCK_NUDGE_INTERVAL_MS);
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : NUDGE_INTERVAL_MS;
}

// HAIL-181: the daemon nudges by itself when the human answers a case that no wait is holding.
// It waits this long first, so a waggle_check that is open (or about to start) takes the reply.
// KNOCK_AUTO_NUDGE_MS overrides it; "off" turns the automatic nudge off (tests).
export const AUTO_NUDGE_DELAY_MS = 3000;

export function autoNudgeDelayMs(env: NodeJS.ProcessEnv = process.env): number | null {
  const raw = env.KNOCK_AUTO_NUDGE_MS?.trim();
  if (raw === "off") return null;
  const parsed = Number(raw);
  return raw && Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : AUTO_NUDGE_DELAY_MS;
}

export interface MessagingEnv {
  socket: string;
  token: string;
}

export function readMessagingEnv(env: NodeJS.ProcessEnv): MessagingEnv | null {
  const socket = env.CLAUDE_CODE_MESSAGING_SOCKET?.trim();
  const token = env.CLAUDE_CODE_MESSAGING_TOKEN?.trim();
  return socket && token ? { socket, token } : null;
}

export interface VersionProbe {
  // The executable path of a process, or null when unknown.
  exePath(pid: number): string | null;
  // Runs an executable with arguments and returns its stdout, or null on failure.
  run(exe: string, args: string[]): string | null;
}

export const systemProbe: VersionProbe = {
  exePath(pid) {
    const out = spawnSync("ps", ["-o", "comm=", "-p", String(pid)], { encoding: "utf8", timeout: 2000 });
    const path = out.status === 0 ? out.stdout.trim() : "";
    return path.length > 0 ? path : null;
  },
  run(exe, args) {
    const out = spawnSync(exe, args, { encoding: "utf8", timeout: 3000 });
    return out.status === 0 ? out.stdout : null;
  },
};

// Test-only: KNOCK_SHIM_TEST_PARENT_EXE stands in for the parent's executable path,
// the way the KNOCK_SHIM_*_MS variables stand in for timing. The path is still
// parsed by detectClaudeVersion.
export function probeFor(env: NodeJS.ProcessEnv): VersionProbe {
  const fake = env.KNOCK_SHIM_TEST_PARENT_EXE?.trim();
  return fake ? { ...systemProbe, exePath: () => fake } : systemProbe;
}

// "2.1.285" from "2.1.285", "v2.1.285" or "2.1.285 (Claude Code)"; null otherwise.
export function parseVersion(text: string): string | null {
  const match = /^\s*v?(\d+\.\d+\.\d+)\b/.exec(text);
  return match ? match[1] : null;
}

// The Claude Code version of the shim's parent process, or null when unknown.
// The native install puts the version in the binary's name
// (.../claude/versions/2.1.285). A binary named `claude` is asked with
// `--version`. Any other parent (node, bun, a wrapper) is unknown: its own
// version says nothing about Claude Code.
export function detectClaudeVersion(
  parentPid: number,
  env: NodeJS.ProcessEnv,
  probe: VersionProbe = systemProbe,
): string | null {
  const candidates: string[] = [];
  const entry = env.CLAUDE_CODE_ENTRYPOINT?.trim();
  if (entry && entry.includes("/")) candidates.push(entry);
  const parent = probe.exePath(parentPid);
  if (parent) candidates.push(parent);
  for (const path of candidates) {
    const fromName = parseVersion(basename(path));
    if (fromName) return fromName;
  }
  for (const path of candidates) {
    if (basename(path).toLowerCase() !== "claude") continue;
    const out = probe.run(path, ["--version"]);
    const version = out ? parseVersion(out) : null;
    if (version) return version;
  }
  return null;
}

export interface NudgeSupport {
  canNudge: boolean;
  // Present only when canNudge is true. Never leaves the shim process.
  messaging: MessagingEnv | null;
}

export function resolveNudgeSupport(
  parentPid: number,
  env: NodeJS.ProcessEnv,
  probe: VersionProbe = systemProbe,
): NudgeSupport {
  const messaging = readMessagingEnv(env);
  if (!messaging) return { canNudge: false, messaging: null };
  const version = detectClaudeVersion(parentPid, env, probe);
  if (!version || isOlder(version, MIN_NUDGE_CLAUDE_VERSION)) {
    return { canNudge: false, messaging: null };
  }
  return { canNudge: true, messaging };
}

// The one line posted into the session. It carries the ask title and the case id
// and never the reply: the reply reaches the agent only through waggle_check.
export function nudgeText(title: string, caseId: string): string {
  const clean = title.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/"/g, "'").trim();
  const short = clean.length > 120 ? `${clean.slice(0, 119).trimEnd()}…` : clean;
  return `Waggle: the human answered "${short}". Call waggle_check with case_id ${caseId} now.`;
}

// WAG-394: the wake for a team comment. It says the words are a comment, not an answer.
export function commentNudgeText(title: string, caseId: string): string {
  const clean = title.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/"/g, "'").trim();
  const short = clean.length > 120 ? `${clean.slice(0, 119).trimEnd()}…` : clean;
  return `Waggle: your team commented on "${short}". This is a comment, not an answer. Call waggle_check with case_id ${caseId} to read it.`;
}

// Connects to the session's inbox socket, writes the auth line and one user line,
// and closes. Rejects with a message that never holds the token.
export function postNudge(messaging: MessagingEnv, text: string): Promise<void> {
  const payload =
    JSON.stringify({ type: "auth", token: messaging.token }) +
    "\n" +
    JSON.stringify({ type: "user", message: { role: "user", content: text } }) +
    "\n";
  return new Promise<void>((resolve, reject) => {
    let done = false;
    const finish = (err?: Error) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (err) reject(err);
      else resolve();
    };
    const timer = setTimeout(() => finish(new Error("inbox socket timed out")), POST_TIMEOUT_MS);
    Bun.connect({
      unix: messaging.socket,
      socket: {
        open(socket) {
          socket.write(payload);
          socket.end();
        },
        data() {},
        close() {
          finish();
        },
        error() {
          finish(new Error("inbox socket failed"));
        },
        connectError() {
          finish(new Error("inbox socket unreachable"));
        },
      },
    }).catch(() => finish(new Error("inbox socket unreachable")));
  });
}
