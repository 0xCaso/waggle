import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import type { KnockAskInput, Reply } from "../src/protocol";
import { rpcConnect, rmrf, tmpHome, type RpcClient } from "./helpers";

// KNOCK-21: service.restart hands the daemon off to a newer binary, and an
// old-format hello (no client_version) still runs ask, reply and ack. These are
// in-process server tests over a real socket; the onRestart callback plays the
// role the daemon's stop() plays in production.

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

let home: string;
let socketPath: string;
let db: Database;
let store: Store;
let server: RpcServer;
let restartFired = false;
let clients: RpcClient[] = [];

beforeAll(() => {
  home = tmpHome();
  socketPath = join(home, "knock.sock");
  db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  store = new Store(db, home, bus);
  server = startRpcServer({
    socketPath,
    store,
    bus,
    version: "0.1.0",
    onRestart: () => {
      restartFired = true;
    },
  });
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

async function waitUntil(predicate: () => boolean, timeoutMs: number): Promise<boolean> {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) return false;
    await new Promise((r) => setTimeout(r, 25));
  }
  return true;
}

// Binds a shim connection with session.hello and creates one case. When
// `sendClientVersion` is false the hello uses the old format (no
// client_version), which the daemon must still accept (KNOCK-21).
async function helloAndCreateCase(
  sessionId: string,
  sendClientVersion: boolean,
): Promise<{ client: RpcClient; sessionId: string; caseId: string }> {
  const client = await connect();
  const helloParams: Record<string, unknown> = {
    session_id: sessionId,
    cwd: join(home, "work"),
    parent_pid: 4242,
  };
  if (sendClientVersion) helloParams.client_version = "0.1.0";
  const hello = await client.request("session.hello", helloParams);
  expect(hello.error).toBeUndefined();
  const created = await client.request("case.create", question);
  return {
    client,
    sessionId,
    caseId: (created.result as { id: string }).id,
  };
}

describe("service.restart", () => {
  beforeEach(() => {
    restartFired = false;
  });

  test("replies ok and asks the daemon to stop", async () => {
    const app = await connect();
    const res = await app.request("service.restart", {});
    expect(res.result).toEqual({ ok: true });
    expect(await waitUntil(() => restartFired, 2000)).toBe(true);
  });

  test("waits for an in-flight delivery before it stops", async () => {
    const { client, caseId } = await helloAndCreateCase("sess-restart", false);
    const app = await connect();

    const submitted = await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "key-restart",
      choice: "a",
      message: "Go with A.",
      comments: [],
      captures: [],
    });
    expect((submitted.result as Reply).state).toBe("queued");

    // case.wait returns the reply and marks the delivery in flight. The shim
    // has NOT acked yet, so a restart must wait for it.
    const wait = await client.request("case.wait", { case_id: caseId, wait_ms: 4000 });
    const replyId = (wait.result as { reply_id: string }).reply_id;
    expect(replyId).toBeTruthy();

    const restart = await app.request("service.restart", {});
    expect(restart.result).toEqual({ ok: true });

    // Still in flight: the stop must not have fired.
    await new Promise((r) => setTimeout(r, 200));
    expect(restartFired).toBe(false);

    // The ack completes the delivery; only now may the daemon stop.
    const ack = await client.request("reply.ack", { reply_id: replyId });
    expect((ack.result as Reply).state).toBe("delivered");

    expect(await waitUntil(() => restartFired, 2000)).toBe(true);

    // State is kept across the exit: a fresh store on the same file still sees
    // the case and its delivered reply.
    const reopened = new Database(join(home, "knock.db"));
    const reopenedStore = new Store(reopened, home);
    expect(reopenedStore.getCase(caseId)!.replies[0].state).toBe("delivered");
    reopened.close();
  });

  test("an old-format hello (no client_version) still runs ask, reply and ack", async () => {
    const { client, caseId } = await helloAndCreateCase("sess-old-hello", false);
    const app = await connect();

    const submitted = await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "key-old-hello",
      choice: "a",
      message: "Go with A.",
      comments: [],
      captures: [],
    });
    const replyId = (submitted.result as Reply).id;
    expect((submitted.result as Reply).state).toBe("queued");

    const wait = await client.request("case.wait", { case_id: caseId, wait_ms: 2000 });
    expect((wait.result as { reply_id: string }).reply_id).toBe(replyId);

    const ack = await client.request("reply.ack", { reply_id: replyId });
    expect((ack.result as Reply).state).toBe("delivered");
    expect(store.getCase(caseId)!.replies[0].state).toBe("delivered");
  });
});
