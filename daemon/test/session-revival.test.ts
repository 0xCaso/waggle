import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { Reply } from "../src/protocol";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { pidAlive } from "../src/sessions";
import { Store } from "../src/store";
import { rmrf, rpcConnect, tmpHome } from "./helpers";

// HAIL-192 (waggle-releases issue 2): a session that comes back from ended is live again, its
// failed replies are delivered, and waggle_check returns the reply of its own case.

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
  for (const home of homes.splice(0)) rmrf(home);
});

function setup(): { home: string; store: Store } {
  const home = tmpHome();
  homes.push(home);
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  servers.push(startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.2.3" }));
  return { home, store };
}

const ask = {
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
  topic: "layout",
};

function hello(parentPid: number) {
  return {
    session_id: "sess-claude",
    cwd: "/tmp/no-git",
    branch: null,
    git_root: null,
    parent_pid: parentPid,
    client_name: "claude-code",
    can_nudge: true,
  };
}

async function deadPid(): Promise<number> {
  const child = Bun.spawn(["sleep", "30"]);
  const pid = child.pid;
  child.kill();
  await child.exited;
  return pid;
}

describe("a session that comes back (HAIL-192)", () => {
  test("a hello from a living client replaces a stale recorded pid and revives the session", async () => {
    const { home, store } = setup();
    const stale = await deadPid();
    const first = await rpcConnect(join(home, "knock.sock"));
    // The first shim recorded a pid; that client has since exited and a new one took the session id.
    store.createSession(store.createTask({ name: "t", project: "p", linear_key: null }).id, {
      id: "sess-claude",
      cwd: "/tmp/no-git",
      branch: null,
      pid: stale,
    });
    first.close();
    expect(store.endDeadSessions(pidAlive)).toEqual(["sess-claude"]);
    expect(store.findSession("sess-claude")?.state).toBe("ended");

    const shim = await rpcConnect(join(home, "knock.sock"));
    const res = await shim.request("session.hello", hello(process.pid));
    expect(res.error).toBeUndefined();
    expect(store.findSession("sess-claude")?.state).toBe("live");
    expect(store.sessionPid("sess-claude")).toBe(process.pid);
    // The reaper now leaves it alone.
    expect(store.endDeadSessions(pidAlive)).toEqual([]);
    shim.close();
  });

  test("a heartbeat from an orphaned shim (dead parent) does not revive an ended session", async () => {
    const { home, store } = setup();
    const gone = await deadPid();
    const shim = await rpcConnect(join(home, "knock.sock"));
    await shim.request("session.hello", hello(process.pid));
    store.setSessionState("sess-claude", "ended");
    await shim.request("session.hello", hello(gone));
    expect(store.findSession("sess-claude")?.state).toBe("ended");
    shim.close();
  });

  test("waggle_check returns the reply that failed while the session was ended, and marks it delivered", async () => {
    const { home, store } = setup();
    const shim = await rpcConnect(join(home, "knock.sock"));
    const app = await rpcConnect(join(home, "knock.sock"));
    await shim.request("session.hello", hello(process.pid));
    const created = await shim.request("case.create", ask);
    const caseId = (created.result as { id: string }).id;

    // The daemon restarted: the reaper ended the session. The human answers: the reply fails.
    store.setSessionState("sess-claude", "ended");
    const submitted = await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "k1",
      choice: "a",
      comments: [],
      captures: [],
    });
    expect((submitted.result as Reply).state).toBe("failed");
    expect((submitted.result as Reply).reason).toBe("session_unreachable");

    // The next case.wait is a sign of life: the session is live and the reply arrives.
    const waited = await shim.request("case.wait", { case_id: caseId, wait_ms: 200 });
    expect(waited.error).toBeUndefined();
    const payload = waited.result as { reply_id: string; content: { type: string; text?: string }[] };
    expect(payload.reply_id).toBe((submitted.result as Reply).id);
    expect(payload.content[0].type).toBe("text");
    expect(store.findSession("sess-claude")?.state).toBe("live");

    await shim.request("reply.ack", { reply_id: payload.reply_id });
    expect(store.getCase(caseId)!.replies[0].state).toBe("delivered");
    expect(store.getCase(caseId)!.replies[0].reason ?? null).toBeNull();
    shim.close();
    app.close();
  });

  test("waggle_check returns its own failed reply even when the session stays ended", async () => {
    const { home, store } = setup();
    const shim = await rpcConnect(join(home, "knock.sock"));
    const app = await rpcConnect(join(home, "knock.sock"));
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    store.setSessionState("sess-claude", "ended");
    await app.request("reply.submit", { case_id: caseId, idempotency_key: "k2", choice: "b", comments: [], captures: [] });
    // Force the session to stay ended: its recorded client pid is gone.
    store.setSessionPid("sess-claude", await deadPid());
    const waited = await shim.request("case.wait", { case_id: caseId, wait_ms: 200 });
    expect((waited.result as { reply_id?: string }).reply_id).toBeDefined();
    expect(store.findSession("sess-claude")?.state).toBe("ended");
    await shim.request("reply.ack", { reply_id: (waited.result as { reply_id: string }).reply_id });
    expect(store.getCase(caseId)!.replies[0].state).toBe("delivered");
    shim.close();
    app.close();
  });

  test("a held waggle_check gets a reply that fails while it waits", async () => {
    const { home, store } = setup();
    const shim = await rpcConnect(join(home, "knock.sock"));
    const app = await rpcConnect(join(home, "knock.sock"));
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    const held = shim.request("case.wait", { case_id: caseId, wait_ms: 5000 });
    await new Promise((r) => setTimeout(r, 50));
    store.setSessionPid("sess-claude", await deadPid());
    store.setSessionState("sess-claude", "ended");
    await app.request("reply.submit", { case_id: caseId, idempotency_key: "k3", choice: "a", comments: [], captures: [] });
    const res = await held;
    expect((res.result as { reply_id?: string }).reply_id).toBeDefined();
    shim.close();
    app.close();
  });

  test("reply.retry on a session that is really gone changes nothing and emits no event", async () => {
    const { home, store } = setup();
    const shim = await rpcConnect(join(home, "knock.sock"));
    const app = await rpcConnect(join(home, "knock.sock"));
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    store.setSessionPid("sess-claude", await deadPid());
    store.setSessionState("sess-claude", "ended");
    const submitted = (await app.request("reply.submit", { case_id: caseId, idempotency_key: "k4", comments: [], captures: [] }))
      .result as Reply;
    const before = store.db.query(`SELECT COUNT(*) AS n FROM events WHERE type = 'reply.state_changed'`).get() as { n: number };
    for (let i = 0; i < 5; i += 1) {
      const retried = (await app.request("reply.retry", { reply_id: submitted.id })).result as Reply;
      expect(retried.state).toBe("failed");
      expect(retried.reason).toBe("session_unreachable");
    }
    const after = store.db.query(`SELECT COUNT(*) AS n FROM events WHERE type = 'reply.state_changed'`).get() as { n: number };
    expect(after.n).toBe(before.n);
    shim.close();
    app.close();
  });

  test("reply.retry brings back a session whose client is alive and queues the reply", async () => {
    const { home, store } = setup();
    const shim = await rpcConnect(join(home, "knock.sock"));
    const app = await rpcConnect(join(home, "knock.sock"));
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    store.setSessionState("sess-claude", "ended");
    const submitted = (await app.request("reply.submit", { case_id: caseId, idempotency_key: "k5", comments: [], captures: [] }))
      .result as Reply;
    expect(submitted.state).toBe("failed");
    const retried = (await app.request("reply.retry", { reply_id: submitted.id })).result as Reply;
    expect(retried.state).toBe("queued");
    shim.close();
    app.close();
  });
});
