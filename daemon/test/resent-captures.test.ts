import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { rpcConnect, tmpHome } from "./helpers";

// WAG-358: a reply that carries a capture or a comment an earlier reply already stored
// must not fail with "Internal error". The old ones are not stored or sent again.
let home: string;
let server: RpcServer;
let store: Store;
let caseId: string;
let socketPath: string;

const cap = (id: string) => ({ id, revision: 3, png_base64: "AAAA", annotated_png_base64: "BBBB", taken_at: "2026-10-10T10:00:00Z" });
const com = (id: string, captureId: string, n: number) => ({
  id,
  capture_id: captureId,
  n,
  rect: { x: 0.1, y: 0.1, w: 0.2, h: 0.2 },
  text: `text ${id}`,
});

beforeAll(() => {
  home = tmpHome();
  mkdirSync(home, { recursive: true });
  socketPath = join(home, "knock.sock");
  const bus = new EventBus();
  store = new Store(new Database(join(home, "knock.db")), home, bus);
  const task = store.createTask({ name: "resent", project: "knock" });
  caseId = store.createCase(task.id, {
    kind: "question",
    title: "Resend",
    need: "Answer",
    why: "Test",
    recommendation: "ok",
    recommendation_why: "Test",
  }).id;
  server = startRpcServer({ socketPath, store, bus, version: "0.1.0" });
});

afterAll(() => {
  server.stop();
  rmSync(home, { recursive: true, force: true });
});

describe("a reply that carries already-sent captures and comments", () => {
  test("reply.submit with only old ids succeeds and stores nothing twice", async () => {
    const first = store.submitReply(caseId, {
      idempotency_key: "r1",
      message: "first",
      comments: [com("com_a", "cap_a", 1)],
      captures: [cap("cap_a")],
    });
    const client = await rpcConnect(socketPath);
    const res = await client.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "r2",
      message: "second",
      comments: [com("com_a", "cap_a", 1)],
      captures: [cap("cap_a")],
    });
    expect(res.error).toBeUndefined();
    const second = res.result as { id: string; captures: unknown[]; comments: unknown[] };
    expect(second.captures).toHaveLength(0);
    expect(second.comments).toHaveLength(0);
    const rows = store.db.query(`SELECT reply_id FROM captures WHERE id = 'cap_a'`).all() as { reply_id: string }[];
    expect(rows).toEqual([{ reply_id: first.id }]);
    client.close();
  });

  test("a reply with one old and one new capture stores only the new one", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "r3",
      message: "third",
      comments: [com("com_a", "cap_a", 1), com("com_b", "cap_b", 2)],
      captures: [cap("cap_a"), cap("cap_b")],
    });
    expect(res.error).toBeUndefined();
    const reply = res.result as { id: string; captures: { id: string }[]; comments: { id: string }[] };
    expect(reply.captures.map((c) => c.id)).toEqual(["cap_b"]);
    expect(reply.comments.map((c) => c.id)).toEqual(["com_b"]);
    client.close();
  });

  test("reply.replace with an old capture succeeds", async () => {
    const queued = store.submitReply(caseId, { idempotency_key: "r4", message: "x", comments: [], captures: [] });
    const client = await rpcConnect(socketPath);
    const res = await client.request("reply.replace", {
      reply_id: queued.id,
      message: "y",
      comments: [com("com_a", "cap_a", 1), com("com_c", "cap_c", 3)],
      captures: [cap("cap_a"), cap("cap_c")],
    });
    expect(res.error).toBeUndefined();
    const reply = res.result as { captures: { id: string }[] };
    expect(reply.captures.map((c) => c.id)).toEqual(["cap_c"]);
    client.close();
  });
});
