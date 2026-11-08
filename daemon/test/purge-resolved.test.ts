import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import type { KnockAskInput } from "../src/protocol";
import { rmrf, rpcConnect, stageIncoming, tmpHome, type RpcClient } from "./helpers";

// HAIL-52: cases.resolved_stats / cases.purge_resolved. Store-level tests
// cover the byte accounting, the blob-sharing edge case and the FK-nulling
// edge case; RPC-level tests cover routing.

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

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

function newStore(home: string): { store: Store; db: Database; bus: EventBus } {
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  return { store, db, bus };
}

function rowCount(db: Database, table: string, caseId: string): number {
  return (
    db.query(`SELECT COUNT(*) AS n FROM ${table} WHERE case_id = ?`).get(caseId) as { n: number }
  ).n;
}

describe("Store cases.resolved_stats / cases.purge_resolved", () => {
  test("both are zero when nothing is resolved", () => {
    const home = tmpHome();
    const { store } = newStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    store.createCase(task.id, question);

    expect(store.resolvedCaseStats()).toEqual({ count: 0, bytes: 0 });
    expect(store.purgeResolvedCases()).toEqual({ purged_cases: 0, freed_bytes: 0 });
    rmrf(home);
  });

  test("purges a dismissed case's revisions, replies, comments, captures and messages, and its bundle dir", () => {
    const home = tmpHome();
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });
    const { store, db } = newStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    const caseId = store.createCase(task.id, {
      kind: "review",
      title: "Checkout layout",
      need: "Approve the layout",
      why: "It needs a human eye",
      recommendation: "a",
      recommendation_why: "It is the default",
      options: [{ id: "a", label: "Compact" }],
    }).id;

    writeFileSync(join(cwd, "index.html"), "<h1>hi</h1>");
    mkdirSync(join(cwd, "proto"));
    writeFileSync(join(cwd, "proto", "index.html"), "<h1>hi</h1>");
    store.createRevision(
      caseId,
      stageIncoming(home, cwd, { type: "html_bundle", dir: "proto", entry: "index.html" }),
    );
    const bundleDir = join(home, "bundles", caseId, "r1");
    expect(existsSync(bundleDir)).toBe(true);

    store.submitReply(caseId, {
      idempotency_key: "k1",
      choice: "a",
      comments: [{ id: "c1", capture_id: "cap1", n: 1, rect: { x: 0, y: 0, w: 0.1, h: 0.1 }, text: "x" }],
      captures: [
        {
          id: "cap1",
          revision: 1,
          png_base64: "abc",
          annotated_png_base64: "abcd",
          taken_at: "2026-09-26T00:00:00.000Z",
        },
      ],
    });
    store.dismissCase(caseId);

    const result = store.purgeResolvedCases();
    expect(result.purged_cases).toBe(1);
    expect(result.freed_bytes).toBeGreaterThan(0);

    expect(store.getCase(caseId)).toBeNull();
    expect(rowCount(db, "revisions", caseId)).toBe(0);
    expect(rowCount(db, "replies", caseId)).toBe(0);
    expect(rowCount(db, "comments", caseId)).toBe(0);
    expect(rowCount(db, "captures", caseId)).toBe(0);
    expect(rowCount(db, "messages", caseId)).toBe(0);
    expect(existsSync(bundleDir)).toBe(false);

    // Idempotent: nothing left to purge.
    expect(store.purgeResolvedCases()).toEqual({ purged_cases: 0, freed_bytes: 0 });
    rmrf(home);
  });

  test("never touches a case that still needs the human or is waiting on the agent", () => {
    const home = tmpHome();
    const { store } = newStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    const keep = store.createCase(task.id, question).id;
    const dismissed = store.createCase(task.id, question).id;
    store.dismissCase(dismissed);

    const result = store.purgeResolvedCases();
    expect(result.purged_cases).toBe(1);
    expect(store.getCase(keep)).not.toBeNull();
    expect(store.getCase(keep)!.case.status).toBe("needs_you");
    expect(store.getCase(dismissed)).toBeNull();
    rmrf(home);
  });

  test("HAIL-236: counts and purges every finished case, never an open or waiting one", () => {
    const home = tmpHome();
    const { store } = newStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    const answer = (id: string, key: string) =>
      store.submitReply(id, { idempotency_key: key, choice: "a", comments: [], captures: [] });

    const needsYou = store.createCase(task.id, question).id;
    const dismissed = store.createCase(task.id, question).id;
    store.dismissCase(dismissed);
    const delivered = store.createCase(task.id, question).id;
    store.markReplyDelivered(answer(delivered, "k-delivered").id);
    const queued = store.createCase(task.id, question).id;
    answer(queued, "k-queued");
    const waiting = store.createCase(task.id, question).id;
    store.markReplyDelivered(answer(waiting, "k-waiting").id);
    store.updateCase(waiting, { message: "more", done: true });
    const closed = store.createCase(task.id, question).id;
    store.updateCase(closed, { message: "done", done: true });
    store.dismissCase(closed);

    expect(store.resolvedCaseStats().count).toBe(3);
    const result = store.purgeResolvedCases();
    expect(result.purged_cases).toBe(3);
    for (const id of [dismissed, delivered, closed]) expect(store.getCase(id)).toBeNull();
    for (const id of [needsYou, queued, waiting]) expect(store.getCase(id)).not.toBeNull();
    expect(store.resolvedCaseStats().count).toBe(0);
    rmrf(home);
  });

  test("keeps an answered ask while its agent session is live (it may still update it)", () => {
    const home = tmpHome();
    const { store } = newStore(home);
    const liveTask = store.createTask({ name: "plan", project: "knock" });
    const s = store.createSession(liveTask.id, { id: "s-live", cwd: home, branch: null, pid: 1 });
    store.setSessionState(s.id, "live");
    const answered = store.createCase(liveTask.id, question).id;
    store.markReplyDelivered(
      store.submitReply(answered, { idempotency_key: "k-live", choice: "a", comments: [], captures: [] }).id,
    );
    expect(store.resolvedCaseStats().count).toBe(0);
    store.setSessionState(s.id, "ended");
    expect(store.resolvedCaseStats().count).toBe(1);
    rmrf(home);
  });

  test("keeps a blob a surviving case still shares, then removes it once that case is purged too", () => {
    const home = tmpHome();
    const cwd = join(home, "work");
    mkdirSync(join(cwd, "shots"), { recursive: true });
    const { store } = newStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });

    // Both cases stage the exact same bytes, so they land on the same
    // content-addressed blob path.
    const png = Buffer.concat([PNG_SIG, Buffer.from("shared bytes")]);
    writeFileSync(join(cwd, "shots", "a.png"), png);
    const caseA = store.createCase(task.id, {
      ...question,
      artifact: stageIncoming(home, cwd, { type: "screenshot", path: "./shots/a.png" }),
    }).id;
    const caseB = store.createCase(task.id, {
      ...question,
      artifact: stageIncoming(home, cwd, { type: "screenshot", path: "./shots/a.png" }),
    }).id;

    const blobPath = store.artifactPath(caseA, 1)!.root;
    expect(blobPath).toBe(store.artifactPath(caseB, 1)!.root);
    expect(existsSync(blobPath)).toBe(true);

    store.dismissCase(caseA);
    let result = store.purgeResolvedCases();
    expect(result.purged_cases).toBe(1);
    expect(existsSync(blobPath)).toBe(true); // caseB still references it

    store.dismissCase(caseB);
    result = store.purgeResolvedCases();
    expect(result.purged_cases).toBe(1);
    expect(existsSync(blobPath)).toBe(false); // nothing references it now
    rmrf(home);
  });

  test("nulls a surviving case's follows_case_id instead of failing the purge", () => {
    const home = tmpHome();
    const { store } = newStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    const earlier = store.createCase(task.id, question).id;
    store.dismissCase(earlier);
    const follower = store.createCase(task.id, { ...question, follows: earlier }).id;
    expect(store.getCase(follower)!.case.follows_case_id).toBe(earlier);

    const result = store.purgeResolvedCases();
    expect(result.purged_cases).toBe(1);
    expect(store.getCase(follower)!.case.follows_case_id).toBeNull();
    rmrf(home);
  });

  test("resolvedCaseStats reports the same case count and byte total purgeResolvedCases then frees", () => {
    const home = tmpHome();
    const cwd = join(home, "work");
    mkdirSync(join(cwd, "shots"), { recursive: true });
    const { store } = newStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    const png = Buffer.concat([PNG_SIG, Buffer.from("only one case uses this")]);
    writeFileSync(join(cwd, "shots", "a.png"), png);
    const caseId = store.createCase(task.id, {
      ...question,
      artifact: stageIncoming(home, cwd, { type: "screenshot", path: "./shots/a.png" }),
    }).id;
    store.dismissCase(caseId);

    const stats = store.resolvedCaseStats();
    expect(stats.count).toBe(1);
    expect(stats.bytes).toBe(png.length);

    const purged = store.purgeResolvedCases();
    expect(purged.purged_cases).toBe(1);
    expect(purged.freed_bytes).toBe(png.length);
    rmrf(home);
  });
});

describe("cases.resolved_stats / cases.purge_resolved RPC", () => {
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

  async function helloAndCreateCase(sessionId: string): Promise<{ client: RpcClient; caseId: string }> {
    const client = await connect();
    await client.request("session.hello", {
      session_id: sessionId,
      cwd: join(home, "work"),
      parent_pid: 4242,
    });
    const created = await client.request("case.create", question);
    return { client, caseId: (created.result as { id: string }).id };
  }

  test("cases.resolved_stats reports zero with nothing resolved", async () => {
    const app = await connect();
    const res = await app.request("cases.resolved_stats", {});
    expect(res.result).toEqual({ count: 0, bytes: 0 });
  });

  test("cases.purge_resolved purges a dismissed case; cases.get on it is then case-not-found", async () => {
    const { caseId } = await helloAndCreateCase("sess-purge-1");
    const app = await connect();

    await app.request("case.dismiss", { case_id: caseId });
    const purgeRes = await app.request("cases.purge_resolved", {});
    expect(purgeRes.result).toEqual({ purged_cases: 1, freed_bytes: 0 });

    const getRes = await app.request("cases.get", { id: caseId });
    expect(getRes.error?.code).toBe(-32001);
  });

  test("cases.purge_resolved never removes a case that still needs the human or is waiting on the agent", async () => {
    const { caseId } = await helloAndCreateCase("sess-purge-2");
    const app = await connect();

    const purgeRes = await app.request("cases.purge_resolved", {});
    expect((purgeRes.result as { purged_cases: number }).purged_cases).toBe(0);

    const getRes = await app.request("cases.get", { id: caseId });
    expect(getRes.error).toBeUndefined();
    expect((getRes.result as { case: { status: string } }).case.status).toBe("needs_you");
  });
});
