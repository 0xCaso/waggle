import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import pkg from "../package.json" with { type: "json" };
import { EventBus } from "../src/events";
import { Reply, ReplyApplyState } from "../src/protocol";
import { APPLY_WAIT_MS, Store } from "../src/store";
import { startRpcServer, type RpcServer } from "../src/server";
import { rmrf, rpcConnect, tmpHome, type RpcClient } from "./helpers";

// WAG-267: a delivered reply is "applied" once the same session shows visible work.

const question = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact layout with small rows", title: "Compact" },
    { id: "b", label: "Detailed layout" },
  ],
};

const homes: string[] = [];
const servers: RpcServer[] = [];
const clients: RpcClient[] = [];

afterEach(() => {
  for (const c of clients.splice(0)) c.close();
  for (const s of servers.splice(0)) s.stop();
  for (const h of homes.splice(0)) rmrf(h);
});

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function setup() {
  const home = tmpHome();
  homes.push(home);
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  const socketPath = join(home, "knock.sock");
  servers.push(startRpcServer({ socketPath, store, bus, version: pkg.version }));
  const connect = async () => {
    const c = await rpcConnect(socketPath);
    clients.push(c);
    return c;
  };
  const shim = await connect();
  await shim.request("session.hello", { session_id: "sess-1", cwd: "/tmp/proj", parent_pid: process.pid, runtime: "claude" });
  const created = await shim.request("case.create", question);
  const caseId = (created.result as { id: string }).id;
  const reply = store.submitReply(caseId, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
  return { store, bus, db, shim, caseId, replyId: reply.id, connect };
}

const applyState = (store: Store, caseId: string) => store.getCase(caseId)!.replies[0]!.apply_state;

describe("reply applied check", () => {
  test("a queued reply has no apply state; delivering makes it pending", async () => {
    const { store, caseId, replyId } = await setup();
    expect(applyState(store, caseId)).toBeUndefined();
    store.markReplyDelivered(replyId);
    expect(applyState(store, caseId)).toBe("pending");
    expect(store.listCases()[0]!.latest_reply_apply_state).toBe("pending");
  });

  test("waggle_check (case.wait) alone is delivery, not applied", async () => {
    const { store, shim, caseId, replyId } = await setup();
    const waited = await shim.request("case.wait", { case_id: caseId, wait_ms: 100 });
    expect((waited.result as { reply_id: string }).reply_id).toBe(replyId);
    await shim.request("reply.ack", { reply_id: replyId });
    expect(applyState(store, caseId)).toBe("pending");
  });

  test("a waggle_update on the case after delivery is applied", async () => {
    const { store, shim, caseId, replyId } = await setup();
    store.markReplyDelivered(replyId);
    const done = await shim.request("case.update", { case_id: caseId, message: "Went with Compact" });
    expect(done.error).toBeUndefined();
    const reply = store.getCase(caseId)!.replies[0]!;
    expect(reply.apply_state).toBe("applied");
    expect(reply.applied_at).toBeDefined();
    expect(store.listCases()[0]!.latest_reply_apply_state).toBe("applied");
  });

  test("a new waggle_ask from the session after delivery is applied", async () => {
    const { store, shim, caseId, replyId } = await setup();
    store.markReplyDelivered(replyId);
    await shim.request("case.create", { ...question, title: "Next question" });
    expect(applyState(store, caseId)).toBe("applied");
  });

  test("a turn that began after delivery and finished is applied", async () => {
    const { store, shim, caseId, replyId } = await setup();
    store.markReplyDelivered(replyId);
    await sleep(5);
    await shim.request("mod.report", { session_id: "sess-1", event: "turn.start" });
    expect(applyState(store, caseId)).toBe("pending");
    await shim.request("mod.report", { session_id: "sess-1", event: "turn.complete" });
    expect(applyState(store, caseId)).toBe("applied");
  });

  test("the turn that fetched the answer does not count", async () => {
    const { store, shim, caseId, replyId } = await setup();
    await shim.request("mod.report", { session_id: "sess-1", event: "turn.start" });
    await sleep(5);
    store.markReplyDelivered(replyId);
    await shim.request("mod.report", { session_id: "sess-1", event: "turn.complete" });
    expect(applyState(store, caseId)).toBe("pending");
  });

  test("a turn of another session does not count", async () => {
    const { store, shim, caseId, replyId } = await setup();
    store.markReplyDelivered(replyId);
    await sleep(5);
    await shim.request("mod.report", { session_id: "other", event: "turn.start" });
    await shim.request("mod.report", { session_id: "other", event: "turn.complete" });
    expect(applyState(store, caseId)).toBe("pending");
  });

  test("15 minutes with no visible work is not applied; late work moves it to applied", async () => {
    const { store, db, shim, caseId, replyId } = await setup();
    store.markReplyDelivered(replyId);
    expect(store.markRepliesNotApplied({ olderThanMs: APPLY_WAIT_MS })).toEqual([]);
    db.query(`UPDATE replies SET delivered_at = ? WHERE id = ?`).run(
      new Date(Date.now() - APPLY_WAIT_MS - 1000).toISOString(),
      replyId,
    );
    expect(store.markRepliesNotApplied({ olderThanMs: APPLY_WAIT_MS })).toEqual([replyId]);
    expect(applyState(store, caseId)).toBe("not_applied");
    expect(store.listCases()[0]!.latest_reply_apply_state).toBe("not_applied");
    // A second sweep changes nothing.
    expect(store.markRepliesNotApplied({ olderThanMs: APPLY_WAIT_MS })).toEqual([]);
    await shim.request("case.update", { case_id: caseId, message: "Done now" });
    expect(applyState(store, caseId)).toBe("applied");
  });

  test("a closed session with no visible work is not applied", async () => {
    const { store, caseId, replyId } = await setup();
    store.markReplyDelivered(replyId);
    store.setSessionState("sess-1", "ended");
    expect(applyState(store, caseId)).toBe("not_applied");
  });

  test("a closed session keeps an applied reply applied", async () => {
    const { store, shim, caseId, replyId } = await setup();
    store.markReplyDelivered(replyId);
    await shim.request("case.update", { case_id: caseId, message: "Went with Compact" });
    store.setSessionState("sess-1", "ended");
    expect(applyState(store, caseId)).toBe("applied");
  });

  test("each change emits reply.state_changed", async () => {
    const { store, bus, shim, caseId, replyId } = await setup();
    store.markReplyDelivered(replyId);
    const events: string[] = [];
    bus.subscribe((e) => events.push(e.type));
    await shim.request("case.update", { case_id: caseId, message: "Went with Compact" });
    expect(events).toContain("reply.state_changed");
  });

  test("schema: apply_state is optional, and an older reply still parses", () => {
    expect(ReplyApplyState.options).toEqual(["pending", "applied", "not_applied"]);
    const old = {
      id: "r1", case_id: "c1", idempotency_key: "k", comments: [], captures: [], intent: "decision",
      source: "mac", state: "delivered", created_at: "2026-10-07T10:00:00.000Z",
    };
    expect(Reply.parse(old).apply_state).toBeUndefined();
    expect(Reply.parse({ ...old, apply_state: "applied", applied_at: "2026-10-07T10:01:00.000Z" }).apply_state).toBe("applied");
    expect(() => Reply.parse({ ...old, apply_state: "done" })).toThrow();
  });
});
