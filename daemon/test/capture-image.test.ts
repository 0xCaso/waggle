import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { rpcConnect, tmpHome } from "./helpers";

// PERF-2: cases.get and the reply echoes carry no capture images. The app
// fetches one image with capture.image when it shows it.
let home: string;
let socketPath: string;
let server: RpcServer;
let store: Store;
let caseId: string;
let otherCaseId: string;
let replyId: string;
const MB = 1024 * 1024;
const rawOf = (i: number) => `RAW${i}`.padEnd(MB, "r");
const annotatedOf = (i: number) => `ANN${i}`.padEnd(MB, "a");
const captures = [1, 2, 3, 4].map((i) => ({
  id: `cap_${i}`,
  revision: 1,
  png_base64: rawOf(i),
  annotated_png_base64: annotatedOf(i),
  taken_at: "2026-10-04T10:00:00Z",
  ...(i === 1 ? { note: "first" } : {}),
}));

beforeAll(() => {
  home = tmpHome();
  mkdirSync(home, { recursive: true });
  socketPath = join(home, "knock.sock");
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  store = new Store(db, home, bus);
  const task = store.createTask({ name: "imgs", project: "knock" });
  caseId = store.createCase(task.id, {
    kind: "question",
    title: "Images",
    need: "Answer",
    why: "Test",
    recommendation: "ok",
    recommendation_why: "Test",
  }).id;
  otherCaseId = store.createCase(task.id, {
    kind: "question",
    title: "Other",
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

describe("capture images on demand", () => {
  test("reply.submit echoes captures without image data", async () => {
    // The 8 MB request goes in through the store: the test client's socket write is not buffered.
    replyId = store.submitReply(caseId, { idempotency_key: "k1", message: "see images", comments: [], captures }).id;
    const client = await rpcConnect(socketPath);
    const small = await client.request("reply.submit", {
      case_id: otherCaseId,
      idempotency_key: "k-small",
      comments: [],
      captures: [{ id: "cap_s", revision: 1, png_base64: "AAAA", annotated_png_base64: "BBBB", taken_at: "t" }],
    });
    expect(small.result).toMatchObject({ captures: [{ id: "cap_s", has_image: true }] });
    expect(JSON.stringify(small.result)).not.toContain("png_base64");
    const res = await client.request("reply.retry", { reply_id: replyId });
    const raw = JSON.stringify(res.result);
    expect(raw.length).toBeLessThan(10_000);
    const reply = res.result as { id: string; captures: Record<string, unknown>[] };
    expect(reply.captures).toEqual([
      { id: "cap_1", revision: 1, taken_at: "2026-10-04T10:00:00Z", note: "first", has_image: true },
      ...[2, 3, 4].map((i) => ({ id: `cap_${i}`, revision: 1, taken_at: "2026-10-04T10:00:00Z", has_image: true })),
    ]);
    client.close();
  }, 20000);

  test("cases.get is slim: size drops from about 8 MB to a few KB", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("cases.get", { id: caseId });
    const after = JSON.stringify(res.result).length;
    const before = after + captures.reduce((n, c) => n + c.png_base64.length + c.annotated_png_base64.length, 0);
    console.log(`cases.get size, 4 captures of 2 images (1 MiB base64 each): before ~${before} bytes, after ${after} bytes`);
    expect(after).toBeLessThan(20_000);
    expect(JSON.stringify(res.result)).not.toContain("png_base64");
    const detail = res.result as { replies: { captures: { id: string; has_image: boolean }[] }[] };
    expect(detail.replies[0].captures.map((c) => c.id)).toEqual(["cap_1", "cap_2", "cap_3", "cap_4"]);
    expect(detail.replies[0].captures.every((c) => c.has_image)).toBe(true);
    client.close();
  }, 20000);

  test("capture.image returns the raw and the annotated image of one capture", async () => {
    const client = await rpcConnect(socketPath);
    const raw = await client.request("capture.image", { capture_id: "cap_3", which: "raw" });
    expect(raw.result).toEqual({ capture_id: "cap_3", which: "raw", png_base64: rawOf(3) });
    const ann = await client.request("capture.image", { capture_id: "cap_3", which: "annotated" });
    expect((ann.result as { png_base64: string }).png_base64).toBe(annotatedOf(3));
    client.close();
  }, 20000);

  test("capture.image rejects an unknown capture", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("capture.image", { capture_id: "nope", which: "raw" });
    expect(res.error).toBeDefined();
    client.close();
  });

  test("reply.replace and reply.retry echo no image data", async () => {
    const client = await rpcConnect(socketPath);
    const replaced = await client.request("reply.replace", {
      reply_id: replyId,
      message: "changed",
      comments: [],
      captures: [{ id: "cap_r", revision: 1, png_base64: "AAAA", annotated_png_base64: "BBBB", taken_at: "t" }],
    });
    expect(JSON.stringify(replaced.result).length).toBeLessThan(10_000);
    expect(JSON.stringify(replaced.result)).not.toContain("png_base64");
    const retried = await client.request("reply.retry", { reply_id: replyId });
    expect(JSON.stringify(retried.result)).not.toContain("png_base64");
    client.close();
  }, 20000);

  test("the agent still gets the annotated image in its reply payload", async () => {
    store.replaceReply(replyId, {
      message: "with a comment",
      comments: [{ id: "c1", capture_id: "cap_2", n: 1, rect: { x: 0.1, y: 0.1, w: 0.2, h: 0.2 }, text: "here" }],
      captures: captures.slice(0, 2),
    });
    const payload = store.buildReplyPayload(replyId);
    const images = (payload?.content ?? []).filter((c) => c.type === "image") as { data: string }[];
    expect(images).toHaveLength(1);
    expect(images[0].data).toBe(annotatedOf(2));
  });
});
