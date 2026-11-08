import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync } from "node:fs";
import { join } from "node:path";
import type { Subprocess } from "bun";
import { idleExitMinutes } from "../src/config";
import type { KnockAskInput } from "../src/protocol";
import { Store } from "../src/store";
import { rpcConnect, rmrf, stopDaemonByHome, tmpHome } from "./helpers";

// Idle exit (KNOCK-18): the daemon exits on its own after KNOCK_IDLE_EXIT_MIN
// minutes with no connections and no queued reply. Queued replies and cases
// persist across the exit.

const ENTRY = join(import.meta.dir, "..", "src", "index.ts");

const question: KnockAskInput = {
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
};

const homes: string[] = [];
const procs: Subprocess[] = [];

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
    rmrf(home);
  }
});

function startDaemon(home: string, idleMin: string): Subprocess {
  const proc = Bun.spawn([process.execPath, ENTRY, "daemon"], {
    env: { ...process.env, KNOCK_HOME: home, KNOCK_IDLE_EXIT_MIN: idleMin },
    stdout: "pipe",
    stderr: "pipe",
  });
  procs.push(proc);
  return proc;
}

async function waitForSocket(socketPath: string, timeoutMs = 8000): Promise<void> {
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

async function waitForExit(proc: Subprocess, timeoutMs = 10000): Promise<number | null> {
  const start = Date.now();
  for (;;) {
    if (proc.exitCode !== null) return proc.exitCode;
    if (Date.now() - start > timeoutMs) return null;
    await new Promise((r) => setTimeout(r, 25));
  }
}

function seedCase(home: string): string {
  const db = new Database(join(home, "knock.db"));
  const store = new Store(db, home);
  const task = store.createTask({ name: "checkout", project: "knock" });
  const created = store.createCase(task.id, { ...question });
  db.close();
  return created.id;
}

function seedCaseWithQueuedReply(home: string): string {
  const db = new Database(join(home, "knock.db"));
  const store = new Store(db, home);
  const task = store.createTask({ name: "checkout", project: "knock" });
  const created = store.createCase(task.id, { ...question });
  store.createReply(created.id, {
    idempotency_key: "idle-key",
    message: "queued",
    comments: [],
    captures: [],
  });
  db.close();
  return created.id;
}

describe("idleExitMinutes", () => {
  test("defaults to 30, honours 0 and fractional values, rejects junk", () => {
    expect(idleExitMinutes({})).toBe(30);
    expect(idleExitMinutes({ KNOCK_IDLE_EXIT_MIN: "0" })).toBe(0);
    expect(idleExitMinutes({ KNOCK_IDLE_EXIT_MIN: "0.05" })).toBe(0.05);
    expect(idleExitMinutes({ KNOCK_IDLE_EXIT_MIN: "" })).toBe(30);
    expect(idleExitMinutes({ KNOCK_IDLE_EXIT_MIN: "abc" })).toBe(30);
    expect(idleExitMinutes({ KNOCK_IDLE_EXIT_MIN: "-1" })).toBe(30);
  });
});

describe("waggle daemon idle exit", () => {
  test("exits after the window with no connections and no queued reply, keeping the case", async () => {
    const home = tmpHome();
    homes.push(home);
    const caseId = seedCase(home);

    const proc = startDaemon(home, "0.05");
    const socketPath = join(home, "knock.sock");
    await waitForSocket(socketPath);

    const code = await waitForExit(proc);
    expect(code).toBe(0);
    expect(existsSync(socketPath)).toBe(false);

    // The case persisted across the exit.
    const db = new Database(join(home, "knock.db"));
    const store = new Store(db, home);
    expect(store.getCase(caseId)?.case.id).toBe(caseId);
    db.close();
  });

  test("does not exit while a reply is queued", async () => {
    const home = tmpHome();
    homes.push(home);
    seedCaseWithQueuedReply(home);

    const proc = startDaemon(home, "0.05");
    await waitForSocket(join(home, "knock.sock"));

    // Wait past several idle windows: the queued reply must hold the daemon up.
    await new Promise((r) => setTimeout(r, 800));
    expect(proc.exitCode).toBeNull();
  });

  test("0 means the daemon never idles out", async () => {
    const home = tmpHome();
    homes.push(home);

    const proc = startDaemon(home, "0");
    await waitForSocket(join(home, "knock.sock"));

    await new Promise((r) => setTimeout(r, 800));
    expect(proc.exitCode).toBeNull();
  });
});
