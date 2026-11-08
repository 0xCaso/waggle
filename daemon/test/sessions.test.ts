import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { rmrf, rpcConnect, tmpHome } from "./helpers";

// Session lifecycle over a real socket: hello binds a session to a task, a
// closed connection marks it disconnected, and a dead parent marks it ended.

const homes: string[] = [];
const servers: RpcServer[] = [];

afterEach(() => {
  for (const server of servers.splice(0)) {
    try {
      server.stop();
    } catch {
      // Already stopped.
    }
  }
  for (const home of homes.splice(0)) {
    rmrf(home);
  }
});

function setup(): { home: string; store: Store } {
  const home = tmpHome();
  homes.push(home);
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  const server = startRpcServer({
    socketPath: join(home, "knock.sock"),
    store,
    bus,
    version: "0.1.0",
  });
  servers.push(server);
  return { home, store };
}

async function waitFor(fn: () => boolean, timeoutMs = 3000): Promise<void> {
  const start = Date.now();
  while (!fn()) {
    if (Date.now() - start > timeoutMs) {
      throw new Error("condition not met in time");
    }
    await new Promise((r) => setTimeout(r, 20));
  }
}

describe("session lifecycle", () => {
  test("session.hello names the task from the branch Linear key", async () => {
    const { home, store } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));

    const res = await client.request("session.hello", {
      session_id: "sess-a",
      cwd: "/tmp/work",
      branch: "ome-412-x",
      parent_pid: process.pid,
    });
    expect(res.error).toBeUndefined();
    const { task_id } = res.result as { task_id: string };
    expect(store.findSession("sess-a")?.state).toBe("live");

    const task = store.db
      .query(`SELECT name, project FROM tasks WHERE id = ?`)
      .get(task_id) as { name: string; project: string };
    expect(task.name).toBe("OME-412");
    expect(task.project).toBe("work");
    client.close();
  });

  test("session.hello stores the runtime, defaulting a missing value to claude (KNOCK-20)", async () => {
    const { home, store } = setup();

    const withRuntime = await rpcConnect(join(home, "knock.sock"));
    await withRuntime.request("session.hello", {
      session_id: "sess-codex",
      cwd: "/tmp/work",
      branch: null,
      parent_pid: process.pid,
      runtime: "codex",
    });
    expect(store.findSession("sess-codex")?.runtime).toBe("codex");
    withRuntime.close();

    // An older shim binary sends no `runtime` field at all.
    const withoutRuntime = await rpcConnect(join(home, "knock.sock"));
    await withoutRuntime.request("session.hello", {
      session_id: "sess-legacy",
      cwd: "/tmp/work",
      branch: null,
      parent_pid: process.pid,
    });
    expect(store.findSession("sess-legacy")?.runtime).toBe("claude");
    withoutRuntime.close();
  });

  test("a closed connection is disconnected, and ended once the parent is gone", async () => {
    const { home, store } = setup();

    const alive = await rpcConnect(join(home, "knock.sock"));
    await alive.request("session.hello", {
      session_id: "sess-alive",
      cwd: "/tmp/work",
      branch: null,
      parent_pid: process.pid,
    });
    expect(store.findSession("sess-alive")?.state).toBe("live");
    alive.close();
    await waitFor(() => store.findSession("sess-alive")?.state === "disconnected");

    const dead = await rpcConnect(join(home, "knock.sock"));
    await dead.request("session.hello", {
      session_id: "sess-dead",
      cwd: "/tmp/work",
      branch: null,
      parent_pid: 999999999,
    });
    dead.close();
    await waitFor(() => store.findSession("sess-dead")?.state === "ended");
  });

  // HAIL-178: an orphaned shim keeps its connection open and keeps saying hello.
  test("a session whose client pid died is ended even while its shim heartbeats", async () => {
    const { home, store } = setup();
    const client = Bun.spawn(["sleep", "30"]);
    const shim = await rpcConnect(join(home, "knock.sock"));
    const hello = { session_id: "sess-orphan", cwd: "/tmp/work", branch: null, parent_pid: client.pid };
    await shim.request("session.hello", hello);
    expect(store.findSession("sess-orphan")?.state).toBe("live");

    client.kill();
    await client.exited;
    const res = await shim.request("session.hello", hello);
    expect(res.error).toBeUndefined();
    expect(store.findSession("sess-orphan")?.state).toBe("ended");
    // Another heartbeat does not bring it back.
    await shim.request("session.hello", hello);
    expect(store.findSession("sess-orphan")?.state).toBe("ended");
    shim.close();
  });

  test("endDeadSessions ends live and disconnected sessions with a dead pid, and no other", () => {
    const { store } = setup();
    const task = store.createTask({ name: "t", project: "p", linear_key: null });
    const seed = (id: string, pid: number) =>
      store.createSession(task.id, { id, cwd: "/tmp/work", branch: null, pid });
    seed("s-dead", 4242);
    seed("s-alive", 4343);
    seed("s-disc", 4242);
    seed("s-orphan-at-start", 1);
    store.setSessionState("s-disc", "disconnected");
    const ended = store.endDeadSessions((pid) => pid === 4343 || pid === 1);
    expect(ended.sort()).toEqual(["s-dead", "s-disc"]);
    expect(store.findSession("s-dead")?.state).toBe("ended");
    expect(store.findSession("s-alive")?.state).toBe("live");
    expect(store.findSession("s-orphan-at-start")?.state).toBe("live");
  });

  test("a reconnect marks the session live again", async () => {
    const { home, store } = setup();

    const first = await rpcConnect(join(home, "knock.sock"));
    await first.request("session.hello", {
      session_id: "sess-re",
      cwd: "/tmp/work",
      branch: null,
      parent_pid: process.pid,
    });
    first.close();
    await waitFor(() => store.findSession("sess-re")?.state === "disconnected");

    const second = await rpcConnect(join(home, "knock.sock"));
    await second.request("session.hello", {
      session_id: "sess-re",
      cwd: "/tmp/work",
      branch: null,
      parent_pid: process.pid,
    });
    expect(store.findSession("sess-re")?.state).toBe("live");
    second.close();
  });
});

describe("sessions.list", () => {
  test("returns no rows when no session has ever connected", async () => {
    const { home } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));

    const res = await client.request("sessions.list", {});
    expect(res.error).toBeUndefined();
    expect(res.result).toEqual([]);
    client.close();
  });

  test("reports runtime, task name, project, branch and state for a live session", async () => {
    const { home } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));

    await client.request("session.hello", {
      session_id: "sess-list",
      cwd: "/tmp/knock",
      branch: "main",
      parent_pid: process.pid,
      runtime: "codex",
    });

    const res = await client.request("sessions.list", {});
    expect(res.error).toBeUndefined();
    const sessions = res.result as Array<Record<string, unknown>>;
    expect(sessions).toHaveLength(1);
    expect(sessions[0]).toMatchObject({
      id: "sess-list",
      runtime: "codex",
      task_name: "main",
      project: "knock",
      branch: "main",
      cwd: "/tmp/knock",
      state: "live",
    });
    expect(typeof sessions[0].task_id).toBe("string");
    expect(typeof sessions[0].connected_at).toBe("string");
    expect(typeof sessions[0].last_seen_at).toBe("string");
    client.close();
  });

  test("reports the shim's parent pid so the app can find the terminal (HAIL-76)", async () => {
    const { home } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    await client.request("session.hello", { session_id: "sess-pid", cwd: "/tmp/knock", parent_pid: process.pid });
    const res = await client.request("sessions.list", {});
    expect((res.result as Array<{ pid: number }>)[0].pid).toBe(process.pid);
    client.close();
  });

  test("session.hello takes an optional boolean can_nudge and nothing else (HAIL-76)", async () => {
    const { home } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    const base = { cwd: "/tmp/knock", parent_pid: process.pid };
    for (const [id, extra] of [["n-false", { can_nudge: false }], ["n-true", { can_nudge: true }], ["n-omit", {}]] as const) {
      const res = await client.request("session.hello", { session_id: id, ...base, ...extra });
      expect(res.error).toBeUndefined();
    }
    const bad = await client.request("session.hello", { session_id: "n-bad", ...base, can_nudge: "yes" });
    expect(bad.error).toBeDefined();
    client.close();
  });

  test("lists live sessions before disconnected ones", async () => {
    const { home, store } = setup();

    const first = await rpcConnect(join(home, "knock.sock"));
    await first.request("session.hello", {
      session_id: "sess-disc",
      cwd: "/tmp/work",
      branch: null,
      parent_pid: process.pid,
    });
    first.close();
    await waitFor(() => store.findSession("sess-disc")?.state === "disconnected");

    const second = await rpcConnect(join(home, "knock.sock"));
    await second.request("session.hello", {
      session_id: "sess-live",
      cwd: "/tmp/work",
      branch: null,
      parent_pid: process.pid,
    });

    const res = await second.request("sessions.list", {});
    const sessions = res.result as Array<{ id: string; state: string }>;
    expect(sessions.map((s) => s.id)).toEqual(["sess-live", "sess-disc"]);
    second.close();
  });

  test("bumps last_seen_at on a session RPC call, not just on connect", async () => {
    const { home, store } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    await client.request("session.hello", {
      session_id: "sess-touch",
      cwd: "/tmp/work",
      branch: null,
      parent_pid: process.pid,
    });

    const before = (
      (await client.request("sessions.list", {})).result as Array<{ id: string; last_seen_at: string }>
    ).find((s) => s.id === "sess-touch")!.last_seen_at;

    // Force last_seen_at earlier so a later touch is observably different,
    // since two calls a few ms apart can otherwise land on the same
    // millisecond-resolution ISO string.
    store.db.query(`UPDATE sessions SET last_seen_at = '2020-01-01T00:00:00.000Z' WHERE id = ?`).run(
      "sess-touch",
    );
    expect(before).not.toBe("2020-01-01T00:00:00.000Z");

    await client.request("case.create", {
      kind: "question",
      title: "T",
      need: "N",
      why: "W",
      recommendation: "R",
      recommendation_why: "RW",
    });

    const after = (
      (await client.request("sessions.list", {})).result as Array<{ id: string; last_seen_at: string }>
    ).find((s) => s.id === "sess-touch")!.last_seen_at;
    expect(after).not.toBe("2020-01-01T00:00:00.000Z");
    client.close();
  });
});

describe("shim parent watch (HAIL-178)", () => {
  test("parentGone: dead pid or re-parented means gone; pid 1 or a live parent does not", async () => {
    const { parentGone } = await import("../src/mcp/shim");
    expect(parentGone(500, 500, () => true)).toBe(false);
    expect(parentGone(500, 500, () => false)).toBe(true);
    expect(parentGone(500, 1, () => true)).toBe(true);
    expect(parentGone(1, 1, () => false)).toBe(false);
  });
});
