import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Subprocess } from "bun";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { DEFAULT_TIMING } from "../src/mcp/shim";
import { rmrf, rpcConnect, startDaemon, stopDaemon, stopDaemonByHome, tmpHome } from "./helpers";

// HAIL-63: the shim keeps its session live without a tool call. It reconnects
// and says session.hello again (same session id) after the daemon restarts, and
// it never starts a daemon from its background loop.

const ENTRY = join(import.meta.dir, "..", "src", "index.ts");
const FAST = {
  KNOCK_SHIM_RECONNECT_FAST_MS: "150",
  KNOCK_SHIM_RECONNECT_SLOW_MS: "300",
  KNOCK_SHIM_KEEPALIVE_MS: "400",
};

const homes: string[] = [];
const procs: Subprocess[] = [];
const transports: StdioClientTransport[] = [];

afterEach(async () => {
  for (const t of transports.splice(0)) {
    try {
      await t.close();
    } catch {
      // Already closed.
    }
  }
  for (const p of procs.splice(0)) {
    try {
      p.kill();
      await p.exited;
    } catch {
      // Already gone.
    }
  }
  for (const home of homes.splice(0)) {
    await stopDaemonByHome(home);
    rmrf(home);
  }
});

async function startShim(home: string, sessionId: string, env: Record<string, string> = {}) {
  const cwd = join(home, "work");
  mkdirSync(cwd, { recursive: true });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [ENTRY, "mcp"],
    env: { KNOCK_HOME: home, CLAUDE_CODE_SESSION_ID: sessionId, ...FAST, ...env },
    cwd,
    stderr: "pipe",
  });
  const client = new Client({ name: "knock-test", version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);
  transports.push(transport);
  return client;
}

interface SessionRow {
  id: string;
  state: string;
  last_seen_at: string;
}

async function session(home: string, id: string): Promise<SessionRow | undefined> {
  const rpc = await rpcConnect(join(home, "knock.sock"));
  try {
    const res = await rpc.request("sessions.list", {});
    return (res.result as SessionRow[]).find((s) => s.id === id);
  } finally {
    rpc.close();
  }
}

async function until<T>(fn: () => Promise<T | undefined | false>, ms: number): Promise<T> {
  const start = Date.now();
  for (;;) {
    const v = await fn().catch(() => undefined);
    if (v) return v;
    if (Date.now() - start > ms) throw new Error("condition not met in time");
    await new Promise((r) => setTimeout(r, 50));
  }
}

const isLive = (home: string, id: string) => async () => {
  const s = await session(home, id);
  return s?.state === "live" ? s : undefined;
};

// A stand-in for `waggle daemon` that only records that it was started.
function spawnStub(home: string): { bin: string; log: string } {
  const log = join(home, "spawns.log");
  const bin = join(home, "stub-knock");
  writeFileSync(bin, `#!/bin/sh\necho spawn >> "${log}"\n`);
  chmodSync(bin, 0o755);
  return { bin, log };
}

const spawnCount = (log: string) =>
  existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean).length : 0;

describe("shim background reconnect", () => {
  test("daemon killed and restarted under a connected shim: session is live again without a tool call", async () => {
    const home = tmpHome();
    homes.push(home);
    const { bin } = spawnStub(home);
    let daemon = await startDaemon(home);
    procs.push(daemon);
    await startShim(home, "sess-restart", { KNOCK_STABLE_BIN: bin });
    await until(isLive(home, "sess-restart"), 5000);

    await stopDaemon(daemon);
    daemon = await startDaemon(home);
    procs.push(daemon);

    const row = await until(isLive(home, "sess-restart"), 5000);
    expect(row.state).toBe("live");
  }, 30000);

  test("startup with no daemon: becomes live once a daemon appears, and the loop starts no daemon", async () => {
    const home = tmpHome();
    homes.push(home);
    const { bin, log } = spawnStub(home);
    // On-demand start at startup runs the stub once (a real daemon never appears).
    await startShim(home, "sess-late", { KNOCK_STABLE_BIN: bin });
    await until(async () => spawnCount(log) >= 1, 5000);
    // Let many loop ticks pass (150 ms / 300 ms): none may spawn.
    await new Promise((r) => setTimeout(r, 4500));
    expect(spawnCount(log)).toBe(1);

    const daemon = await startDaemon(home);
    procs.push(daemon);
    await until(isLive(home, "sess-late"), 5000);
    expect(spawnCount(log)).toBe(1);
  }, 30000);

  test("keepalive refreshes last_seen_at while idle", async () => {
    const home = tmpHome();
    homes.push(home);
    const daemon = await startDaemon(home);
    procs.push(daemon);
    await startShim(home, "sess-keepalive");
    const first = await until(isLive(home, "sess-keepalive"), 5000);
    const later = await until(async () => {
      const s = await session(home, "sess-keepalive");
      return s && s.last_seen_at !== first.last_seen_at ? s : undefined;
    }, 5000);
    expect(later.state).toBe("live");
  }, 30000);

  test("a connected shim keeps the daemon from idling out", async () => {
    const home = tmpHome();
    homes.push(home);
    const daemon = Bun.spawn([process.execPath, ENTRY, "daemon"], {
      env: { ...process.env, KNOCK_HOME: home, KNOCK_IDLE_EXIT_MIN: "0.01" },
      stdout: "pipe",
      stderr: "pipe",
    });
    procs.push(daemon);
    await until(async () => existsSync(join(home, "knock.sock")), 5000);
    await startShim(home, "sess-idle");
    await until(isLive(home, "sess-idle"), 5000);
    // 0.01 min = 600 ms; wait well past it.
    await new Promise((r) => setTimeout(r, 2500));
    expect(daemon.exitCode).toBeNull();
    expect((await session(home, "sess-idle"))?.state).toBe("live");
  }, 30000);

  test("background timers do not keep the process alive", async () => {
    // A process that only holds the shim's unref'd kind of timer exits on its own.
    const proc = Bun.spawn(
      [
        process.execPath,
        "-e",
        "setTimeout(()=>{},60000).unref(); setInterval(()=>{},60000).unref();",
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const code = await Promise.race([
      proc.exited,
      new Promise<string>((r) => setTimeout(() => r("hung"), 5000)),
    ]);
    expect(code).toBe(0);
    // And the shim exits promptly when its stdin closes while the loop runs.
    const home = tmpHome();
    homes.push(home);
    const shim = Bun.spawn([process.execPath, ENTRY, "mcp"], {
      env: { ...process.env, KNOCK_HOME: home, KNOCK_STABLE_BIN: spawnStub(home).bin, ...FAST },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    procs.push(shim);
    await new Promise((r) => setTimeout(r, 800));
    shim.stdin.end();
    const shimCode = await Promise.race([
      shim.exited,
      new Promise<string>((r) => setTimeout(() => r("hung"), 5000)),
    ]);
    expect(shimCode).toBe(0);
  }, 30000);

  test("default timing follows the contract", () => {
    expect(DEFAULT_TIMING).toEqual({
      reconnectFastMs: 2000,
      reconnectFastWindowMs: 30000,
      reconnectSlowMs: 15000,
      keepaliveMs: 60000,
      footprintMs: 10000,
    });
  });
});

// HAIL-197: a first case.create that times out is retried with the same client_request_id.
describe("shim case.create retry", () => {
  test("a timed-out first create is retried and exactly one case exists", async () => {
    const home = tmpHome();
    homes.push(home);
    const daemon = await startDaemon(home);
    procs.push(daemon);
    const client = await startShim(home, "sess-retry", {
      KNOCK_SHIM_FIRST_CREATE_TIMEOUT_MS: "1",
      KNOCK_ASK_WAIT_MS: "300",
    });
    await until(isLive(home, "sess-retry"), 5000);
    const result = await client.callTool({
      name: "waggle_ask",
      arguments: {
        kind: "question",
        title: "Pick a layout",
        need: "Pick a layout",
        why: "I cannot decide",
        recommendation: "a",
        recommendation_why: "It is the default",
        options: [
          { id: "a", label: "Compact" },
          { id: "b", label: "Detailed" },
        ],
      },
    });
    expect(result.isError).toBeFalsy();
    const rpc = await rpcConnect(join(home, "knock.sock"));
    try {
      const cases = (await rpc.request("cases.list", {})).result as unknown[];
      expect(cases.length).toBe(1);
    } finally {
      rpc.close();
    }
  }, 30000);
});

// HAIL-222: the shim runs inside the agent's process, so it reads the project folder's git state and
// sends it in session.hello. The daemon runs no git: this is the only way `changes` gets there.
describe("shim git footprint", () => {
  test("a repo with one untracked file reaches sessions.list as context.changes, and a new change follows", async () => {
    const home = tmpHome();
    homes.push(home);
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });
    execFileSync("git", ["-C", cwd, "init", "-q"]);
    writeFileSync(join(cwd, "new.txt"), "n\n");
    const claudeRoot = join(home, "claude-projects");
    const slugDir = join(claudeRoot, realpathSync(cwd).replace(/[^A-Za-z0-9]/g, "-"));
    mkdirSync(slugDir, { recursive: true });
    writeFileSync(join(slugDir, "sess-fp.jsonl"), JSON.stringify({ type: "ai-title", aiTitle: "Footprint" }) + "\n");
    const saved = process.env.KNOCK_CLAUDE_PROJECTS;
    process.env.KNOCK_CLAUDE_PROJECTS = claudeRoot;
    try {
      procs.push(await startDaemon(home));
    } finally {
      if (saved === undefined) delete process.env.KNOCK_CLAUDE_PROJECTS;
      else process.env.KNOCK_CLAUDE_PROJECTS = saved;
    }
    await startShim(home, "sess-fp", { KNOCK_SHIM_FOOTPRINT_MS: "200" });
    const changesOf = async () => {
      const rpc = await rpcConnect(join(home, "knock.sock"));
      try {
        const res = await rpc.request("sessions.list", {});
        return (res.result as { id: string; context: { changes: { files: number } | null } | null }[]).find(
          (s) => s.id === "sess-fp",
        )?.context?.changes;
      } finally {
        rpc.close();
      }
    };
    expect((await until(async () => (await changesOf()) ?? undefined, 5000)).files).toBe(1);
    writeFileSync(join(cwd, "second.txt"), "s\n");
    const second = await until(async () => {
      const c = await changesOf();
      return c && c.files === 2 ? c : undefined;
    }, 5000);
    expect(second.files).toBe(2);
  });
});
