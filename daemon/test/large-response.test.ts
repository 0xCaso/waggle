import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { rpcConnect, tmpHome } from "./helpers";

// Bun's socket.write is not buffered: a response larger than the kernel send
// buffer is written partially. Before the outbox fix the rest was dropped and
// a client waited forever for cases.get / reply.submit on a case whose reply
// carried a capture (operator report, 0.1.1).
let home: string;
let socketPath: string;
let server: RpcServer;
let caseId: string;
const big = "x".repeat(4 * 1024 * 1024);

beforeAll(() => {
  home = tmpHome();
  socketPath = join(home, "knock.sock");
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  const task = store.createTask({ name: "big", project: "knock" });
  caseId = store.createCase(task.id, {
    kind: "question",
    title: "Large response",
    need: "Answer",
    why: "Test",
    recommendation: "ok",
    recommendation_why: "Test",
  }).id;
  store.submitReply(caseId, { idempotency_key: "k-big", message: big, comments: [], captures: [] });
  server = startRpcServer({ socketPath, store, bus, version: "0.1.0" });
});

afterAll(() => {
  server.stop();
  rmSync(home, { recursive: true, force: true });
});

describe("large responses", () => {
  test("cases.get with a 4 MB reply arrives whole", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("cases.get", { id: caseId });
    const detail = res.result as { replies: { message: string }[] };
    expect(detail.replies[0].message.length).toBe(big.length);
    client.close();
  }, 20000);
});
