import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import pkg from "../package.json" with { type: "json" };
import { Store } from "../src/store";
import type { KnockAskInput } from "../src/protocol";
import { rpcConnect, startDaemon, stopDaemonByHome, tmpHome } from "./helpers";
import type { Subprocess } from "bun";

// Starts the real daemon binary on a temp KNOCK_HOME and talks JSON-RPC over
// the unix socket (KNOCK-02 verification).

const question: KnockAskInput = {
  kind: "question",
  title: "Checkout layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "Compact",
  recommendation_why: "It fits on one line",
};

const review: KnockAskInput = {
  kind: "review",
  title: "Checkout layout",
  need: "Approve the layout",
  why: "It needs a human eye",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact" },
    { id: "b", label: "Detailed" },
  ],
};

let procs: Subprocess[] = [];
let homes: string[] = [];

afterEach(async () => {
  for (const proc of procs.splice(0)) {
    try {
      proc.kill();
      await proc.exited;
    } catch {
      // Already gone.
    }
  }
  for (const home of homes.splice(0)) {
    await stopDaemonByHome(home);
    try {
      rmSync(home, { recursive: true, force: true });
    } catch {
      // Already removed.
    }
  }
});

describe("waggle daemon", () => {
  test("creates KNOCK_HOME, knock.db and a 0600 socket, and serves status", async () => {
    const home = tmpHome();
    homes.push(home);
    const proc = await startDaemon(home);
    procs.push(proc);

    expect(existsSync(join(home, "knock.db"))).toBe(true);
    const socketPath = join(home, "knock.sock");
    expect(statSync(socketPath).mode & 0o777).toBe(0o600);

    const client = await rpcConnect(socketPath);
    const res = await client.request("service.status", {});
    const status = res.result as {
      version: string;
      data_root: string;
      sessions_live: number;
      cases_open: number;
    };
    expect(status).toMatchObject({ version: pkg.version, data_root: home });
    expect(status.sessions_live).toBe(0);
    expect(status.cases_open).toBe(0);
    client.close();
  });

  test("a second daemon on the same KNOCK_HOME exits 3 with a clear message", async () => {
    const home = tmpHome();
    homes.push(home);
    const first = await startDaemon(home);
    procs.push(first);

    const entry = join(import.meta.dir, "..", "src", "index.ts");
    const second = Bun.spawn([process.execPath, entry, "daemon"], {
      env: { ...process.env, KNOCK_HOME: home },
      stdout: "pipe",
      stderr: "pipe",
    });
    const code = await second.exited;
    const stderr = await new Response(second.stderr).text();
    expect(code).toBe(3);
    expect(stderr).toContain("another daemon is already running");
  });

  test("cases survive a SIGKILL and restart", async () => {
    const home = tmpHome();
    homes.push(home);

    // Seed two cases before the daemon starts (case creation RPC is KNOCK-04).
    const seedDb = new Database(join(home, "knock.db"));
    const seedStore = new Store(seedDb, home);
    const task = seedStore.createTask({ name: "checkout", project: "knock" });
    const c1 = seedStore.createCase(task.id, { ...question });
    const c2 = seedStore.createCase(task.id, { ...review });
    seedDb.close();

    const socketPath = join(home, "knock.sock");

    const first = await startDaemon(home);
    const client = await rpcConnect(socketPath);
    const before = await client.request("cases.list", {});
    const beforeRows = (before.result as { id: string; status: string }[]).map((c) => ({
      id: c.id,
      status: c.status,
    }));
    expect(beforeRows).toContainEqual({ id: c1.id, status: "needs_you" });
    expect(beforeRows).toContainEqual({ id: c2.id, status: "needs_you" });
    client.close();

    first.kill("SIGKILL");
    await first.exited;

    const second = await startDaemon(home);
    procs.push(second);
    const client2 = await rpcConnect(socketPath);
    const after = await client2.request("cases.list", {});
    const afterRows = (after.result as { id: string; status: string }[]).map((c) => ({
      id: c.id,
      status: c.status,
    }));
    expect(afterRows).toEqual(beforeRows);
    client2.close();
  });
});
