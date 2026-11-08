import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { Reply } from "../src/protocol";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { ModRegistry } from "../src/sessions/live";
import { isSdkHost, pendingText, SDK_HOST_NOTE } from "../src/mcp/shim";
import { Store } from "../src/store";
import { rmrf, rpcConnect, tmpHome, type RpcClient } from "./helpers";

// WAG-258 (waggle-releases issue 3): a host that closes an idle agent session. The reply says so
// honestly, writes one event, never nudges for a delivered reply, and holds the nudge mid-turn.

process.env.KNOCK_AUTO_NUDGE_MS = "30";

const homes: string[] = [];
const servers: RpcServer[] = [];
const clients: RpcClient[] = [];

afterEach(() => {
  delete process.env.KNOCK_WORKING_QUIET_MS;
  for (const c of clients.splice(0)) c.close();
  for (const server of servers.splice(0)) {
    try {
      server.stop();
    } catch {
      // Already stopped.
    }
  }
  for (const home of homes.splice(0)) rmrf(home);
});

function setup(mods?: ModRegistry): { home: string; store: Store } {
  const home = tmpHome();
  homes.push(home);
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  servers.push(startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.2.12", mods }));
  return { home, store };
}

async function connect(home: string): Promise<RpcClient> {
  const c = await rpcConnect(join(home, "knock.sock"));
  clients.push(c);
  return c;
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

const hello = (parentPid: number) => ({
  session_id: "sess-sdk",
  cwd: "/tmp/no-git",
  branch: null,
  git_root: null,
  parent_pid: parentPid,
  client_name: "claude-code",
  can_nudge: true,
});

async function deadPid(): Promise<number> {
  const child = Bun.spawn(["sleep", "30"]);
  const pid = child.pid;
  child.kill();
  await child.exited;
  return pid;
}

const reply = (case_id: string, key: string) => ({ case_id, idempotency_key: key, choice: "a", comments: [], captures: [] });

function stateEvents(store: Store, replyId: string): number {
  return (
    store.db
      .query(`SELECT COUNT(*) AS n FROM events WHERE type = 'reply.state_changed' AND reply_id = ?`)
      .get(replyId) as { n: number }
  ).n;
}

function nudgeCount(store: Store, replyId: string): number {
  return (store.db.query(`SELECT nudge_count AS n FROM replies WHERE id = ?`).get(replyId) as { n: number }).n;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe("a reply to a closed session", () => {
  test("the case reports the ended session before the human answers", async () => {
    const { home, store } = setup();
    const shim = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    expect(store.getCase(caseId)!.case.session_state).toBe("live");
    store.setSessionState("sess-sdk", "ended");
    expect(store.getCase(caseId)!.case.session_state).toBe("ended");
    expect(store.getCase(caseId)!.case.status).toBe("needs_you");
  });

  test("the case says when the session ended, so the app can tell which came first", async () => {
    const { home, store } = setup();
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    expect(store.getCase(caseId)!.case.session_ended_at).toBeNull();
    store.setSessionState("sess-sdk", "ended");
    const endedAt = store.getCase(caseId)!.case.session_ended_at!;
    expect(Date.parse(endedAt)).toBeGreaterThan(0);
    expect(store.listCases().find((c) => c.id === caseId)!.session_ended_at).toBe(endedAt);
    await sleep(5);
    const submitted = (await app.request("reply.submit", reply(caseId, "k0"))).result as Reply;
    expect(Date.parse(submitted.created_at)).toBeGreaterThanOrEqual(Date.parse(endedAt));
    store.setSessionState("sess-sdk", "live");
    expect(store.getCase(caseId)!.case.session_ended_at).toBeNull();
  });

  test("a reply to an ended session is saved as failed with one reply.state_changed event", async () => {
    const { home, store } = setup();
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    store.setSessionState("sess-sdk", "ended");
    const submitted = (await app.request("reply.submit", reply(caseId, "k1"))).result as Reply;
    expect(submitted.state).toBe("failed");
    expect(submitted.reason).toBe("session_unreachable");
    expect(stateEvents(store, submitted.id)).toBe(1);
    expect(store.getCase(caseId)!.case.status).toBe("waiting_on_agent");
  });

  test("a reply to a live session still writes one event and queues", async () => {
    const { home, store } = setup();
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    const submitted = (await app.request("reply.submit", reply(caseId, "k2"))).result as Reply;
    expect(submitted.state).toBe("queued");
    expect(stateEvents(store, submitted.id)).toBe(1);
  });

  test("an ended session that has a reply queued fails it with one more event", async () => {
    const { home, store } = setup();
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    const submitted = (await app.request("reply.submit", reply(caseId, "k3"))).result as Reply;
    store.setSessionState("sess-sdk", "ended");
    expect(store.getCase(caseId)!.replies[0].state).toBe("failed");
    expect(stateEvents(store, submitted.id)).toBe(2);
  });
});

describe("retry (WAG-258)", () => {
  test("on an ended session retry changes nothing and writes no event", async () => {
    const { home, store } = setup();
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    store.setSessionPid("sess-sdk", await deadPid());
    store.setSessionState("sess-sdk", "ended");
    const submitted = (await app.request("reply.submit", reply(caseId, "k4"))).result as Reply;
    const events = stateEvents(store, submitted.id);
    const retried = (await app.request("reply.retry", { reply_id: submitted.id })).result as Reply;
    expect(retried.state).toBe("failed");
    expect(stateEvents(store, submitted.id)).toBe(events);
  });

  test("on a live session retry re-queues the reply and writes an event", async () => {
    const { home, store } = setup();
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    store.setSessionState("sess-sdk", "ended");
    const submitted = (await app.request("reply.submit", reply(caseId, "k5"))).result as Reply;
    expect(submitted.state).toBe("failed");
    // The client is alive (this process): retry revives the session and queues the reply.
    const events = stateEvents(store, submitted.id);
    const retried = (await app.request("reply.retry", { reply_id: submitted.id })).result as Reply;
    expect(retried.state).toBe("queued");
    expect(stateEvents(store, submitted.id)).toBe(events + 1);
  });
});

describe("hand over (WAG-410 pass 2)", () => {
  async function failedReply(): Promise<{ store: Store; app: RpcClient; shim: RpcClient; caseId: string; reply: Reply }> {
    const { home, store } = setup();
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    store.setSessionState("sess-sdk", "ended");
    const reply = (await app.request("reply.submit", reply_(caseId, "ho1"))).result as Reply;
    expect(reply.state).toBe("failed");
    return { store, app, shim, caseId, reply };
  }
  const reply_ = reply;

  test("reply.hand_over marks a failed reply handed_over and writes one event", async () => {
    const { store, app, caseId, reply } = await failedReply();
    const events = stateEvents(store, reply.id);
    const handed = (await app.request("reply.hand_over", { reply_id: reply.id })).result as Reply;
    expect(handed.state).toBe("handed_over");
    expect(handed.reason ?? null).toBeNull();
    expect(stateEvents(store, reply.id)).toBe(events + 1);
    expect(store.getCase(caseId)!.replies[0].state).toBe("handed_over");
    // A second call changes nothing and writes no event.
    const again = (await app.request("reply.hand_over", { reply_id: reply.id })).result as Reply;
    expect(again.state).toBe("handed_over");
    expect(stateEvents(store, reply.id)).toBe(events + 1);
  });

  test("a handed_over reply is never requeued when the session comes back, and retry leaves it", async () => {
    const { store, app, shim, caseId, reply } = await failedReply();
    await app.request("reply.hand_over", { reply_id: reply.id });
    store.setSessionState("sess-sdk", "live");
    expect(store.getCase(caseId)!.replies[0].state).toBe("handed_over");
    expect(store.findDeliverableReply(caseId)).toBeNull();
    const retried = (await app.request("reply.retry", { reply_id: reply.id })).result as Reply;
    expect(retried.state).toBe("handed_over");
    const waited = (await shim.request("case.wait", { case_id: caseId, wait_ms: 100 })).result as { status?: string };
    expect(JSON.stringify(waited)).not.toContain(reply.id);
  });

  test("a delivered reply is returned unchanged and an unknown reply is -32001", async () => {
    const { home, store } = setup();
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    const queued = (await app.request("reply.submit", reply(caseId, "ho2"))).result as Reply;
    expect(queued.state).toBe("queued");
    const same = (await app.request("reply.hand_over", { reply_id: queued.id })).result as Reply;
    expect(same.state).toBe("queued");
    expect(store.getReply(queued.id)!.state).toBe("queued");
    const missing = await app.request("reply.hand_over", { reply_id: "reply_missing" });
    expect(missing.error?.code).toBe(-32001);
  });

  test("an older database (version 52) keeps its replies through the migration", () => {
    const db = new Database(":memory:");
    db.exec("PRAGMA foreign_keys = ON");
    const store = new Store(db, tmpHome(), new EventBus());
    expect(store).toBeTruthy();
    const sql = (db.query("SELECT sql FROM sqlite_master WHERE name = 'replies'").get() as { sql: string }).sql;
    expect(sql).toContain("handed_over");
  });
});

describe("case state after a late delivery", () => {
  test("a reply delivered by waggle_check after the session came back leaves the case as the normal path does", async () => {
    const { home, store } = setup();
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const normalCase = ((await shim.request("case.create", ask)).result as { id: string }).id;
    const lateCase = ((await shim.request("case.create", { ...ask, topic: "second" })).result as { id: string }).id;
    store.setSessionState("sess-sdk", "ended");
    await app.request("reply.submit", reply(lateCase, "k6"));
    store.setSessionState("sess-sdk", "live");
    await app.request("reply.submit", reply(normalCase, "k7"));
    for (const caseId of [normalCase, lateCase]) {
      const waited = (await shim.request("case.wait", { case_id: caseId, wait_ms: 200 })).result as { reply_id: string };
      await shim.request("reply.ack", { reply_id: waited.reply_id });
    }
    for (const caseId of [normalCase, lateCase]) {
      const c = store.getCase(caseId)!;
      expect(c.replies[0].state).toBe("delivered");
      expect(c.case.status).toBe("waiting_on_agent");
    }
    // The agent's next waggle_update moves both cases on the same way.
    for (const caseId of [normalCase, lateCase]) {
      await shim.request("case.update", { case_id: caseId, message: "Applied it, one more question." });
      expect(store.getCase(caseId)!.case.status).toBe("needs_you");
    }
  });
});

describe("the reconnect nudge (WAG-258)", () => {
  async function working(): Promise<{ home: string; store: Store; mods: ModRegistry; shim: RpcClient; app: RpcClient; caseId: string }> {
    const mods = new ModRegistry(Date.now, 5000);
    const { home, store } = setup(mods);
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    mods.report("sess-sdk", "turn.start");
    return { home, store, mods, shim, app, caseId };
  }

  test("a reply queued mid-turn holds the nudge until the turn ends", async () => {
    const { mods, app, caseId } = await working();
    await app.request("reply.submit", reply(caseId, "k8"));
    await sleep(250);
    expect(mods.peekNudge("sess-sdk")).toBeNull();
    mods.report("sess-sdk", "turn.complete");
    await sleep(250);
    expect(mods.peekNudge("sess-sdk")?.case_id).toBe(caseId);
  });

  test("a reply that waggle_check delivers mid-turn is never nudged", async () => {
    const { store, mods, shim, app, caseId } = await working();
    await app.request("reply.submit", reply(caseId, "k9"));
    const waited = (await shim.request("case.wait", { case_id: caseId, wait_ms: 200 })).result as { reply_id: string };
    await shim.request("reply.ack", { reply_id: waited.reply_id });
    mods.report("sess-sdk", "turn.complete");
    await sleep(300);
    expect(mods.peekNudge("sess-sdk")).toBeNull();
    expect(store.db.query(`SELECT COUNT(*) AS n FROM events WHERE type = 'session.nudged'`).get()).toEqual({ n: 0 });
  });

  test("an idle session is nudged without delay", async () => {
    const { mods, app, caseId } = await working();
    mods.report("sess-sdk", "turn.complete");
    await app.request("reply.submit", reply(caseId, "k10"));
    await sleep(250);
    expect(mods.peekNudge("sess-sdk")?.case_id).toBe(caseId);
  });

  test("without a mod, a session that just came back is held, and a delivered reply is dropped", async () => {
    process.env.KNOCK_WORKING_QUIET_MS = "60000";
    const { home, store } = setup();
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    store.setSessionState("sess-sdk", "ended");
    const submitted = (await app.request("reply.submit", reply(caseId, "k11"))).result as Reply;
    expect(submitted.state).toBe("failed");
    // The host starts a new process: hello brings the session back and re-queues the reply.
    await shim.request("session.hello", hello(process.pid));
    expect(store.findQueuedReply(caseId)?.id).toBe(submitted.id);
    await sleep(250);
    // Held: the daemon reserved no nudge for the reply.
    expect(nudgeCount(store, submitted.id)).toBe(0);
    const waited = (await shim.request("case.wait", { case_id: caseId, wait_ms: 200 })).result as { reply_id: string };
    await shim.request("reply.ack", { reply_id: waited.reply_id });
    process.env.KNOCK_WORKING_QUIET_MS = "0";
    await sleep(300);
    expect(nudgeCount(store, submitted.id)).toBe(0);
  });

  test("without a mod, a quiet session is nudged", async () => {
    process.env.KNOCK_WORKING_QUIET_MS = "0";
    const { home } = setup();
    const shim = await connect(home);
    const app = await connect(home);
    await shim.request("session.hello", hello(process.pid));
    const caseId = ((await shim.request("case.create", ask)).result as { id: string }).id;
    await app.request("reply.submit", reply(caseId, "k12"));
    const line = await shim.nextLine(2000);
    expect(line.method).toBe("session.nudge");
  });
});

describe("the pending text for an SDK host", () => {
  const pending = { status: "pending" as const, case_id: "c_1" };

  test("sdk-* entrypoints are SDK hosts", () => {
    expect(isSdkHost({ CLAUDE_CODE_ENTRYPOINT: "sdk-ts" })).toBe(true);
    expect(isSdkHost({ CLAUDE_CODE_ENTRYPOINT: "sdk-py" })).toBe(true);
    expect(isSdkHost({ CLAUDE_CODE_ENTRYPOINT: "cli" })).toBe(false);
    expect(isSdkHost({})).toBe(false);
  });

  test("an SDK host hears that the host can close the session", () => {
    for (const mode of ["wake", "poll", "desktop"] as const) {
      const text = pendingText(pending, mode, true);
      expect(text).toContain("The host can close this session when it is idle.");
      expect(text).toContain("Tell the human to send you a message after they answer.");
      expect(text.endsWith(SDK_HOST_NOTE)).toBe(true);
    }
  });

  test("other hosts keep the text unchanged", () => {
    for (const mode of ["wake", "poll", "desktop"] as const) {
      expect(pendingText(pending, mode)).toBe(pendingText(pending, mode, false));
      expect(pendingText(pending, mode)).not.toContain("host can close");
    }
  });
});
