import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import type { Event, KnockAskInput } from "../src/protocol";
import { rpcConnect, rmrf, tmpHome, type RpcClient } from "./helpers";

// HAIL-32: case.dismiss / case.restore. Store-level tests cover the state
// machine (any status -> resolved -> restored to the prior status) and
// idempotency; RPC-level tests cover routing and the dismissal message a
// waiting agent's case.wait/waggle_check receives.

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

function newStore(): { store: Store; db: Database; bus: EventBus } {
  const db = new Database(":memory:");
  const bus = new EventBus();
  const store = new Store(db, "/tmp/knock-test", bus);
  return { store, db, bus };
}

function seedCase(store: Store): string {
  const task = store.createTask({ name: "checkout", project: "knock" });
  return store.createCase(task.id, question).id;
}

describe("Store dismiss/restore", () => {
  test("dismissCase sets resolved and dismissed_at, and emits one case.updated", () => {
    const { store, bus } = newStore();
    const caseId = seedCase(store);
    const events: Event[] = [];
    bus.subscribe((e) => events.push(e));

    const dismissed = store.dismissCase(caseId)!;
    expect(dismissed.status).toBe("resolved");
    expect(dismissed.dismissed_at).not.toBeNull();
    expect(events.filter((e) => e.type === "case.updated" && e.case_id === caseId)).toHaveLength(1);
  });

  test("dismissCase is idempotent: a second call changes nothing and emits nothing further", () => {
    const { store, bus } = newStore();
    const caseId = seedCase(store);

    const first = store.dismissCase(caseId)!;
    const events: Event[] = [];
    bus.subscribe((e) => events.push(e));
    const second = store.dismissCase(caseId)!;

    expect(second.dismissed_at).toBe(first.dismissed_at);
    expect(second.status).toBe("resolved");
    expect(events).toHaveLength(0);
  });

  test("dismissCase on an unknown case returns null", () => {
    const { store } = newStore();
    expect(store.dismissCase("c_missing")).toBeNull();
  });

  test("restoreCase clears dismissed_at and puts the case back in its prior status", () => {
    const { store } = newStore();
    const caseId = seedCase(store);
    store.submitReply(caseId, { idempotency_key: "k1", comments: [], captures: [] });
    expect(store.getCase(caseId)!.case.status).toBe("waiting_on_agent");

    store.dismissCase(caseId);
    expect(store.getCase(caseId)!.case.status).toBe("resolved");

    const restored = store.restoreCase(caseId)!;
    expect(restored.status).toBe("waiting_on_agent");
    expect(restored.dismissed_at).toBeNull();
  });

  test("restoreCase on a case that was never dismissed is a no-op", () => {
    const { store } = newStore();
    const caseId = seedCase(store);
    const restored = store.restoreCase(caseId)!;
    expect(restored.status).toBe("needs_you");
    expect(restored.dismissed_at).toBeNull();
  });

  test("restoreCase on an unknown case returns null", () => {
    const { store } = newStore();
    expect(store.restoreCase("c_missing")).toBeNull();
  });

  test("isDismissed reflects dismissed_at", () => {
    const { store } = newStore();
    const caseId = seedCase(store);
    expect(store.isDismissed(caseId)).toBe(false);
    store.dismissCase(caseId);
    expect(store.isDismissed(caseId)).toBe(true);
    store.restoreCase(caseId);
    expect(store.isDismissed(caseId)).toBe(false);
  });
});

describe("case.dismiss / case.restore RPC", () => {
  let home: string;
  let socketPath: string;
  let server: RpcServer;
  let store: Store;
  let clients: RpcClient[] = [];

  beforeAll(() => {
    home = tmpHome();
    socketPath = join(home, "knock.sock");
    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    store = new Store(db, home, bus);
    server = startRpcServer({ socketPath, store, bus, version: "0.1.0" });
  });

  afterAll(() => {
    for (const client of clients.splice(0)) {
      try {
        client.close();
      } catch {
        // Already closed.
      }
    }
    server.stop();
    rmrf(home);
  });

  async function connect(): Promise<RpcClient> {
    const client = await rpcConnect(socketPath);
    clients.push(client);
    return client;
  }

  async function helloAndCreateCase(
    sessionId: string,
  ): Promise<{ client: RpcClient; caseId: string }> {
    const client = await connect();
    await client.request("session.hello", {
      session_id: sessionId,
      cwd: join(home, "work"),
      parent_pid: 4242,
    });
    const created = await client.request("case.create", question);
    return { client, caseId: (created.result as { id: string }).id };
  }

  test("case.dismiss over the socket resolves the case", async () => {
    const { caseId } = await helloAndCreateCase("sess-dismiss-1");
    const app = await connect();

    const res = await app.request("case.dismiss", { case_id: caseId });
    expect((res.result as { status: string }).status).toBe("resolved");
    expect(store.getCase(caseId)!.case.status).toBe("resolved");
  });

  test("case.dismiss on an unknown case is -32001", async () => {
    const app = await connect();
    const res = await app.request("case.dismiss", { case_id: "c_missing" });
    expect(res.error?.code).toBe(-32001);
  });

  test("case.restore on an unknown case is -32001", async () => {
    const app = await connect();
    const res = await app.request("case.restore", { case_id: "c_missing" });
    expect(res.error?.code).toBe(-32001);
  });

  test("case.restore over the socket clears dismissed_at and restores needs_you", async () => {
    const { caseId } = await helloAndCreateCase("sess-dismiss-2");
    const app = await connect();

    await app.request("case.dismiss", { case_id: caseId });
    const restored = await app.request("case.restore", { case_id: caseId });
    const result = restored.result as { status: string; dismissed_at: string | null };
    expect(result.status).toBe("needs_you");
    expect(result.dismissed_at).toBeNull();
  });

  test("a waiting agent's case.wait gets the dismissal message instead of hanging or erroring", async () => {
    const { client, caseId } = await helloAndCreateCase("sess-dismiss-wait");
    const app = await connect();

    const waitPromise = client.request("case.wait", { case_id: caseId, wait_ms: 5000 });
    // Give case.wait time to register its bus subscription before the
    // dismiss fires, so this exercises the live-wait path, not the immediate
    // "already dismissed" check the next test covers.
    await new Promise((r) => setTimeout(r, 50));

    const dismissRes = await app.request("case.dismiss", { case_id: caseId });
    expect((dismissRes.result as { status: string }).status).toBe("resolved");

    const wait = await waitPromise;
    expect(wait.error).toBeUndefined();
    const payload = wait.result as { reply_id: string; content: { type: string; text?: string }[] };
    const text = payload.content.find((c) => c.type === "text")?.text ?? "";
    expect(text).toBe("The human dismissed this ask without answering.");
  });

  test("waggle_check on an already-dismissed case gets the dismissal message immediately", async () => {
    const { client, caseId } = await helloAndCreateCase("sess-dismiss-already");
    const app = await connect();

    await app.request("case.dismiss", { case_id: caseId });

    const wait = await client.request("case.wait", { case_id: caseId, wait_ms: 2000 });
    expect(wait.error).toBeUndefined();
    const payload = wait.result as { content: { type: string; text?: string }[] };
    const text = payload.content.find((c) => c.type === "text")?.text ?? "";
    expect(text).toBe("The human dismissed this ask without answering.");
  });
});
