import { execFileSync } from "node:child_process";
import { chmodSync, lstatSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Subprocess } from "bun";
import { stageBundle, stageDiagram, stageMarkdown, stageScreenshot, stageScreenshots } from "../src/artifacts";
import type { Artifact } from "../src/protocol";

// Removes a tree even when a staged bundle made it read-only (chmod a-w).
// rmSync alone fails with EACCES on a read-only directory, so restore every
// write bit first, deepest first.
export function rmrf(path: string): void {
  try {
    const st = lstatSync(path);
    if (st.isDirectory()) {
      for (const name of readdirSync(path)) {
        rmrf(join(path, name));
      }
    }
    chmodSync(path, st.mode | 0o222);
  } catch {
    // Missing entry: nothing to remove.
  }
  try {
    rmSync(path, { recursive: true, force: true });
  } catch {
    // Already gone.
  }
}

// A minimal newline-delimited JSON-RPC client over a unix socket, used by the
// in-process server tests and the spawned-daemon integration test.

// A temp data folder that counts as set up (the app's `onboarded` marker, HAIL-193): the shim
// answers "not set up" without it. `setUp: false` makes the folder of a Mac with no Waggle app.
export function tmpHome(opts: { setUp?: boolean } = {}): string {
  const home = mkdtempSync(join(tmpdir(), "knock-"));
  if (opts.setUp !== false) writeFileSync(join(home, "onboarded"), "");
  return home;
}

// Stages an artifact the way the `waggle mcp` shim does: resolve against cwd,
// validate and copy into <home>/incoming/<uuid>/, then return the incoming
// artifact the daemon accepts (HAIL-26).
export function stageIncoming(home: string, cwd: string, artifact: Artifact): Artifact {
  const incomingDir = join(home, "incoming");
  if (artifact.type === "screenshot") {
    const staged = stageScreenshot({ path: artifact.path, cwd, incomingDir });
    return { type: "screenshot", path: staged.path };
  }
  if (artifact.type === "markdown") {
    const staged = stageMarkdown({ path: artifact.path, cwd, incomingDir });
    return { type: "markdown", path: staged.path };
  }
  if (artifact.type === "diagram") {
    const staged = stageDiagram({ path: artifact.path, cwd, incomingDir });
    return { type: "diagram", path: staged.path };
  }
  if (artifact.type === "screenshots") {
    const staged = stageScreenshots({ items: artifact.items, cwd, incomingDir });
    return { type: "screenshots", items: staged.items };
  }
  const staged = stageBundle({
    dir: artifact.dir,
    entry: artifact.entry,
    cwd,
    incomingDir,
    viewport: artifact.viewport,
    preview: artifact.preview,
  });
  return {
    type: "html_bundle",
    dir: staged.path,
    entry: staged.entry,
    ...(staged.viewport !== undefined ? { viewport: staged.viewport } : {}),
    ...(staged.preview !== undefined ? { preview: staged.preview } : {}),
  };
}

interface ClientConn {
  buffer: string;
  lines: string[];
  waiters: ((line: string) => void)[];
}

export interface RpcLine {
  jsonrpc: string;
  id?: unknown;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
  method?: string;
  params?: unknown;
}

export class RpcClient {
  private nextId = 1;
  constructor(
    private socket: Bun.Socket<ClientConn>,
    private conn: ClientConn,
  ) {}

  // 15 s: a loaded CI runner can take more than 5 s to answer a large reply.
  nextLine(timeoutMs = 15000): Promise<RpcLine> {
    return new Promise((resolve, reject) => {
      if (this.conn.lines.length > 0) {
        resolve(JSON.parse(this.conn.lines.shift()!));
        return;
      }
      const waiter = (line: string) => {
        clearTimeout(timer);
        resolve(JSON.parse(line));
      };
      const timer = setTimeout(() => {
        // Drop the waiter, so a late line goes to the next reader, not to this one.
        const i = this.conn.waiters.indexOf(waiter);
        if (i >= 0) this.conn.waiters.splice(i, 1);
        reject(new Error("timed out waiting for a line"));
      }, timeoutMs);
      this.conn.waiters.push(waiter);
    });
  }

  // Sends a request and returns the response whose id matches it, skipping any
  // notifications that arrive first (returns those from `notifications`).
  async request(
    method: string,
    params: unknown = {},
    notifications: RpcLine[] = [],
  ): Promise<RpcLine> {
    const id = this.nextId++;
    this.socket.write(
      JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n",
    );
    for (;;) {
      const line = await this.nextLine();
      if (line.id === id) return line;
      notifications.push(line);
    }
  }

  close(): void {
    this.socket.end();
  }
}

export async function rpcConnect(path: string): Promise<RpcClient> {
  const conn: ClientConn = { buffer: "", lines: [], waiters: [] };
  const socket = await Bun.connect<ClientConn>({
    unix: path,
    data: conn,
    socket: {
      data(_socket, data) {
        conn.buffer += data.toString("utf8");
        let idx: number;
        while ((idx = conn.buffer.indexOf("\n")) >= 0) {
          const line = conn.buffer.slice(0, idx);
          conn.buffer = conn.buffer.slice(idx + 1);
          const waiter = conn.waiters.shift();
          if (waiter) waiter(line);
          else conn.lines.push(line);
        }
      },
      close() {},
    },
  });
  return new RpcClient(socket, conn);
}

export async function startDaemon(home: string): Promise<Subprocess> {
  const entry = join(import.meta.dir, "..", "src", "index.ts");
  const proc = Bun.spawn([process.execPath, entry, "daemon"], {
    env: { ...process.env, KNOCK_HOME: home },
    stdout: "pipe",
    stderr: "pipe",
  });
  const socketPath = join(home, "knock.sock");
  await waitForSocket(socketPath);
  return proc;
}

export async function stopDaemon(proc: Subprocess): Promise<void> {
  proc.kill();
  await proc.exited;
}

// Every test home lives under <tmpdir>/knock- (tmpHome below). The leak guard
// flags any live `waggle daemon` whose KNOCK_HOME is under this root.
export const TEST_TEMP_ROOT = join(tmpdir(), "knock-");

// Reads the daemon's pid from its single-instance lock file, or null when none.
// The daemon writes its pid to <home>/knock.lock and removes the lock on a clean
// stop (daemon.ts), so a live lock means a daemon still owns the home.
export function readDaemonPid(home: string): number | null {
  try {
    const parsed = Number(readFileSync(join(home, "knock.lock"), "utf8").trim());
    return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
  } catch {
    return null;
  }
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code !== "ESRCH";
  }
}

async function waitForDead(pid: number, timeoutMs: number): Promise<void> {
  const start = Date.now();
  while (pidAlive(pid)) {
    if (Date.now() - start > timeoutMs) return;
    await new Promise((r) => setTimeout(r, 25));
  }
}

// Stops a daemon the test did not spawn itself: a shim or the app started it on
// demand, detached, so there is no Subprocess handle to kill. Reads the pid from
// the lock file, SIGTERMs it, waits for exit, then SIGKILLs if it lingers. The
// loop repeats a few times because a shim can restart the daemon during cleanup.
// No-op when no daemon runs for this home.
export async function stopDaemonByHome(home: string): Promise<void> {
  for (let attempt = 0; attempt < 3; attempt++) {
    const pid = readDaemonPid(home);
    if (pid === null || !pidAlive(pid)) return;
    try {
      process.kill(pid, "SIGTERM");
    } catch {
      return;
    }
    await waitForDead(pid, 3000);
    if (!pidAlive(pid)) continue; // exited; loop again in case a shim restarted it
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      return;
    }
    await waitForDead(pid, 3000);
  }
}

export interface LeakedDaemon {
  pid: number;
  home: string;
}

// Lists live `waggle daemon` processes whose KNOCK_HOME is a test temp home. Used
// by the leak guard test (test/leak-guard.test.ts).
export function leakedTestDaemons(): LeakedDaemon[] {
  let listing = "";
  try {
    listing = execFileSync("ps", ["-axo", "pid=,args="], { encoding: "utf8" });
  } catch {
    return [];
  }
  const leaked: LeakedDaemon[] = [];
  for (const line of listing.split("\n")) {
    const match = line.match(/^\s*(\d+)\s+(.*)$/);
    if (!match) continue;
    const pid = Number(match[1]);
    const args = match[2];
    if (!args.includes("index.ts daemon") && !args.includes("dist/waggle daemon")) continue;
    const home = envOf(pid).KNOCK_HOME;
    if (home && home.startsWith(TEST_TEMP_ROOT)) leaked.push({ pid, home });
  }
  return leaked;
}

// Reads one process's environment (macOS `ps eww`), returned as KEY -> value.
function envOf(pid: number): Record<string, string> {
  try {
    const out = execFileSync("ps", ["eww", "-p", String(pid), "-o", "command="], {
      encoding: "utf8",
    });
    const env: Record<string, string> = {};
    const re = /(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(out)) !== null) env[m[1]] = m[2];
    return env;
  } catch {
    return {};
  }
}

// Waits until the socket answers a connect, not merely until the file exists.
// After a SIGKILL the old socket file is still there while the new daemon
// unlinks and re-binds it, so existence is not readiness.
async function waitForSocket(socketPath: string, timeoutMs = 5000): Promise<void> {
  const start = Date.now();
  for (;;) {
    try {
      const client = await rpcConnect(socketPath);
      client.close();
      return;
    } catch {
      if (Date.now() - start > timeoutMs) {
        throw new Error("daemon socket never became connectable");
      }
      await new Promise((r) => setTimeout(r, 25));
    }
  }
}
