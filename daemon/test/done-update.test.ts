import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { KnockUpdateInput, MCP_TOOLS } from "../src/protocol";
import type { Event, KnockAskInput } from "../src/protocol";
import { rpcConnect, rmrf, tmpHome, type RpcClient } from "./helpers";

// HAIL-152: waggle_update with done: true is a closing note. The case waits for the human's Got it
// (case.dismiss), never returns to needs_you, creates no reply, and offers no nudge.

const question: KnockAskInput = {
  kind: "question",
  title: "Ship the rebrand?",
  need: "Ship the rebrand?",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is ready",
  options: [
    { id: "a", label: "Ship it" },
    { id: "b", label: "Wait" },
  ],
};

function setup(): { store: Store; bus: EventBus; caseId: string } {
  const bus = new EventBus();
  const store = new Store(new Database(":memory:"), "/tmp/knock-test", bus);
  const task = store.createTask({ name: "HAIL-152", project: "app" });
  return { store, bus, caseId: store.createCase(task.id, question).id };
}

const answer = (store: Store, caseId: string, key = "k1"): void => {
  store.submitReply(caseId, { idempotency_key: key, choice: "a", comments: [], captures: [] });
};

describe("KnockUpdateInput done", () => {
  const base = { case_id: "c1", message: "Done and live." };

  test("done round-trips and is optional", () => {
    expect(KnockUpdateInput.parse({ ...base, done: true }).done).toBe(true);
    expect(KnockUpdateInput.parse(base).done).toBeUndefined();
  });

  test("done with options is rejected", () => {
    const r = KnockUpdateInput.safeParse({
      ...base,
      done: true,
      options: [{ id: "x", label: "X" }],
      recommendation: "x",
    });
    expect(r.success).toBe(false);
    expect(JSON.stringify(r.error?.issues)).toContain("cannot carry options");
  });

  test("done false with options still parses", () => {
    const r = KnockUpdateInput.safeParse({
      ...base,
      done: false,
      options: [{ id: "x", label: "X" }],
      recommendation: "x",
    });
    expect(r.success).toBe(true);
  });

  test("the tool manifest names done and the closing note", () => {
    const tool = MCP_TOOLS.find((t) => t.name === "waggle_update")!;
    expect(JSON.stringify(tool.inputSchema)).toContain('"done"');
    expect(tool.description).toContain("done: true");
  });

});

describe("Store done update", () => {
  test("an answered case moves to waiting_on_agent with done_at, and no reply is created", () => {
    const { store, caseId } = setup();
    answer(store, caseId);
    const repliesBefore = store.getCase(caseId)!.replies.length;
    const updated = store.updateCase(caseId, { case_id: caseId, message: "Done and live.", done: true })!;
    expect(updated.status).toBe("waiting_on_agent");
    expect(updated.done_at).not.toBeNull();
    expect(updated.latest_update_message).toBe("Done and live.");
    expect(store.getCase(caseId)!.replies).toHaveLength(repliesBefore);
    expect(store.isDone(caseId)).toBe(true);
  });

  test("one done update stores exactly one message", () => {
    const { store, caseId } = setup();
    answer(store, caseId);
    store.updateCase(caseId, { case_id: caseId, message: "Done and live.", done: true });
    const n = (store as any).db.query("SELECT COUNT(*) AS n FROM messages WHERE case_id = ?").get(caseId).n;
    expect(n).toBe(1);
  });

  test("a done update never returns the case to needs_you", () => {
    const { store, caseId } = setup();
    answer(store, caseId);
    store.updateCase(caseId, { case_id: caseId, message: "Done.", done: true });
    expect(store.listCases("needs_you").map((c) => c.id)).not.toContain(caseId);
    expect(store.countNeedsYouCases()).toBe(0);
  });

  test("a done update on a case with no reply never goes to needs_you either", () => {
    const { store, caseId } = setup();
    const updated = store.updateCase(caseId, { case_id: caseId, message: "Done.", done: true })!;
    expect(updated.status).toBe("waiting_on_agent");
  });

  test("Got it (case.dismiss) closes the case and creates no reply", () => {
    const { store, caseId } = setup();
    answer(store, caseId);
    store.updateCase(caseId, { case_id: caseId, message: "Done.", done: true });
    const repliesBefore = store.getCase(caseId)!.replies.length;
    const closed = store.dismissCase(caseId)!;
    expect(closed.status).toBe("resolved");
    expect(closed.dismissed_at).not.toBeNull();
    expect(store.getCase(caseId)!.replies).toHaveLength(repliesBefore);
  });

  test("a done update on a dismissed case keeps it resolved", () => {
    const { store, caseId } = setup();
    store.dismissCase(caseId);
    const updated = store.updateCase(caseId, { case_id: caseId, message: "Done.", done: true })!;
    expect(updated.status).toBe("resolved");
  });


  test("a normal update after a done update clears done_at and returns to needs_you", () => {
    const { store, caseId } = setup();
    answer(store, caseId);
    store.updateCase(caseId, { case_id: caseId, message: "Done.", done: true });
    const again = store.updateCase(caseId, { case_id: caseId, message: "One more thing." })!;
    expect(again.status).toBe("needs_you");
    expect(again.done_at).toBeNull();
  });

  test("a normal update is unchanged: needs_you, no done_at", () => {
    const { store, caseId } = setup();
    answer(store, caseId);
    const updated = store.updateCase(caseId, { case_id: caseId, message: "Rewrote it." })!;
    expect(updated.status).toBe("needs_you");
    expect(updated.done_at).toBeNull();
    expect(store.isDone(caseId)).toBe(false);
  });

  test("a done update emits one case.updated and no reply event", () => {
    const { store, bus, caseId } = setup();
    answer(store, caseId);
    const events: Event[] = [];
    bus.subscribe((e) => events.push(e));
    store.updateCase(caseId, { case_id: caseId, message: "Done.", done: true });
    expect(events.filter((e) => e.type === "case.updated")).toHaveLength(1);
    expect(events.some((e) => e.type === "reply.state_changed" || e.type === "session.nudged")).toBe(false);
  });
});

describe("done update over the socket", () => {
  let home: string;
  let server: RpcServer;
  let store: Store;
  const clients: RpcClient[] = [];

  beforeAll(() => {
    home = tmpHome();
    const bus = new EventBus();
    store = new Store(new Database(join(home, "knock.db")), home, bus);
    server = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0" });
  });

  afterAll(() => {
    for (const c of clients.splice(0)) {
      try {
        c.close();
      } catch {
        // Already closed.
      }
    }
    server.stop();
    rmrf(home);
  });

  async function hello(sessionId: string): Promise<{ client: RpcClient; caseId: string }> {
    const client = await rpcConnect(join(home, "knock.sock"));
    clients.push(client);
    await client.request("session.hello", { session_id: sessionId, cwd: join(home, "work"), parent_pid: 4242 });
    const created = await client.request("case.create", question);
    return { client, caseId: (created.result as { id: string }).id };
  }

  test("case.update with done and options is rejected by the daemon", async () => {
    const { client, caseId } = await hello("sess-done-bad");
    const res = await client.request("case.update", {
      case_id: caseId,
      message: "x",
      done: true,
      options: [{ id: "x", label: "X" }],
      recommendation: "x",
    });
    expect(res.error).toBeDefined();
    expect(store.getCase(caseId)!.case.status).toBe("needs_you");
  });

  test("session.nudge on a done case sends nothing", async () => {
    const { client, caseId } = await hello("sess-done-nudge");
    // A queued reply that the agent never collected, then the agent's closing note.
    answer(store, caseId);
    await client.request("case.update", { case_id: caseId, message: "Done and live.", done: true });
    const app = await rpcConnect(join(home, "knock.sock"));
    clients.push(app);
    const res = await app.request("session.nudge", { case_id: caseId });
    expect(res.result).toEqual({ sent: false, reason: "already_picked_up" });
  });

  test("case.wait on a done case answers at once with a closed message", async () => {
    const { client, caseId } = await hello("sess-done-wait");
    await client.request("case.update", { case_id: caseId, message: "Done.", done: true });
    const res = await client.request("case.wait", { case_id: caseId, wait_ms: 3000 });
    const text = JSON.stringify(res.result);
    expect(text).toContain("closed as done");
  });
});
