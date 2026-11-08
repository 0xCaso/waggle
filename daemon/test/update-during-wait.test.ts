import { afterAll, beforeAll, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { DaemonClient } from "../src/mcp/client";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import type { KnockAskInput } from "../src/protocol";
import { rmrf, tmpHome } from "./helpers";

// WAG-343: waggle_update on a case whose own waggle_ask is still waiting must not queue behind the
// wait. The shim keeps one connection; the daemon used to run its requests one at a time, and the
// client read answers in order.

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
let server: RpcServer;
let store: Store;
let client: DaemonClient;

beforeAll(async () => {
  home = tmpHome();
  const socketPath = join(home, "knock.sock");
  const bus = new EventBus();
  store = new Store(new Database(join(home, "knock.db")), home, bus);
  server = startRpcServer({ socketPath, store, bus, version: "0.1.0" });
  client = new DaemonClient();
  await client.connect(socketPath);
  await client.call("session.hello", { session_id: "sess-wag343", cwd: join(home, "work"), parent_pid: 4242 }, 5000);
});

afterAll(() => {
  client.close();
  server.stop();
  rmrf(home);
});

test("an update returns fast while the case's own wait is open, and the wait still gets the reply", async () => {
  const created = (await client.call("case.create", question, 5000)) as { id: string };
  const wait = client.call("case.wait", { case_id: created.id, wait_ms: 20000 }, 30000);
  await new Promise((r) => setTimeout(r, 100));

  const started = Date.now();
  const updated = (await client.call(
    "case.update",
    { case_id: created.id, message: "A note while you decide." },
    3000,
  )) as { id: string };
  expect(updated.id).toBe(created.id);
  expect(Date.now() - started).toBeLessThan(2000);

  store.submitReply(created.id, { idempotency_key: "k-wag343", choice: "b", comments: [], captures: [] });
  const reply = (await wait) as { reply_id?: string; status?: string };
  expect(reply.reply_id).toBeDefined();
  expect(reply.status).toBeUndefined();
});
