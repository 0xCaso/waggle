import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import { KnockAskInput } from "../src/protocol";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { rmrf, rpcConnect, tmpHome, type RpcClient } from "./helpers";

// WAG-295: the app copies the answer body that waggle_check formats, so the case carries it.

const homes: string[] = [];
const servers: RpcServer[] = [];
const clients: RpcClient[] = [];

afterEach(() => {
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

const options = {
  kind: "question" as const,
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

const questions = {
  kind: "question" as const,
  title: "Pricing page decisions",
  need: "Two decisions.",
  why: "They touch the same screen.",
  recommendation: "Three plans.",
  recommendation_why: "It is common.",
  questions: [
    {
      id: "plans",
      title: "How many plans?",
      points: [
        { id: "count", text: "How many plans?", options: ["Two", "Three"] },
        { id: "badge", text: "Badge the middle plan?" },
      ],
    },
    { id: "cta", title: "Button text?", points: [{ id: "label", text: "Start free?" }] },
  ],
};

function setup(input: object): { store: Store; caseId: string } {
  const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
  const task = store.createTask({ name: "WAG-295", project: "app" });
  return { store, caseId: store.createCase(task.id, KnockAskInput.parse(input)).id };
}

const submit = (store: Store, caseId: string, extra: Record<string, unknown>, key = "k") =>
  store.submitReply(caseId, { idempotency_key: key, comments: [], captures: [], ...extra });

// What waggle_check shows the agent, minus its "Reply to ..." header line.
function checkBody(store: Store, replyId: string): string {
  const first = store.buildReplyPayload(replyId)!.content[0]!;
  if (first.type !== "text") throw new Error("expected text");
  return first.text.split("\n").slice(1).join("\n");
}

describe("latest_reply_answer_text", () => {
  test("a choice reply carries the lines waggle_check shows after its header", () => {
    const { store, caseId } = setup(options);
    const reply = submit(store, caseId, { choice: "b", message: "also keep it small" });
    const text = store.getCase(caseId)!.case.latest_reply_answer_text;
    expect(text).toBe(checkBody(store, reply.id));
    expect(text).toContain("Choice: b (Detailed)");
    expect(text).toContain("Message: also keep it small");
    expect(text).not.toContain("Reply to");
  });

  test("a note-only reply carries the note", () => {
    const { store, caseId } = setup(options);
    submit(store, caseId, { message: "Neither, try a table" });
    expect(store.getCase(caseId)!.case.latest_reply_answer_text).toContain("Message: Neither, try a table");
  });

  test("several questions keep the Q and point lines of the delivered text", () => {
    const { store, caseId } = setup(questions);
    const reply = submit(store, caseId, {
      answers: [
        { question_id: "plans", point_id: "count", choice: "Three", note: "keep it  simple" },
        { question_id: "cta", point_id: "label", choice: "Yes" },
      ],
    });
    const text = store.getCase(caseId)!.case.latest_reply_answer_text!;
    expect(text).toBe(checkBody(store, reply.id));
    expect(text).toContain("Q1 · point 1: Three · note: keep it simple");
    expect(text).toContain("Q2 · point 1: Yes");
  });

  test("the list and caseById carry it too", () => {
    const { store, caseId } = setup(options);
    submit(store, caseId, { choice: "a" });
    expect(store.listCases().find((c) => c.id === caseId)!.latest_reply_answer_text).toContain("Choice: a (Compact)");
    expect(store.caseById(caseId)!.latest_reply_answer_text).toContain("Choice: a (Compact)");
  });

  test("no reply, a detail request or a delivered reply carries none", () => {
    const { store, caseId } = setup(options);
    expect(store.getCase(caseId)!.case.latest_reply_answer_text ?? null).toBeNull();
    const detail = submit(store, caseId, { intent: "more_detail", message: "why?" }, "k1");
    expect(store.getCase(caseId)!.case.latest_reply_answer_text ?? null).toBeNull();
    store.markReplyDelivered(detail.id);
    submit(store, caseId, { choice: "a" }, "k2");
    const latest = store.getCase(caseId)!.case;
    expect(latest.latest_reply_answer_text).toContain("Choice: a");
    store.markReplyDelivered(latest.latest_reply_id!);
    expect(store.getCase(caseId)!.case.latest_reply_answer_text ?? null).toBeNull();
  });
});

describe("a pasted answer then waggle_check (WAG-258 dedupe)", () => {
  test("waggle_check delivers the reply once; the case drops the text", async () => {
    const home = tmpHome();
    homes.push(home);
    const store = new Store(new Database(join(home, "knock.db")), home, new EventBus());
    servers.push(startRpcServer({ socketPath: join(home, "knock.sock"), store, bus: new EventBus(), version: "0.2.17" }));
    const shim = await rpcConnect(join(home, "knock.sock"));
    const app = await rpcConnect(join(home, "knock.sock"));
    clients.push(shim, app);
    await shim.request("session.hello", {
      session_id: "sess-295",
      cwd: "/tmp/no-git",
      branch: null,
      git_root: null,
      parent_pid: process.pid,
      client_name: "claude-code",
      can_nudge: true,
    });
    const caseId = ((await shim.request("case.create", { ...options, topic: "layout" })).result as { id: string }).id;
    store.setSessionState("sess-295", "ended");
    await app.request("reply.submit", { case_id: caseId, idempotency_key: "p1", choice: "a", comments: [], captures: [] });
    expect(store.getCase(caseId)!.case.latest_reply_answer_text).toContain("Choice: a (Compact)");
    store.setSessionState("sess-295", "live");
    const first = (await shim.request("case.wait", { case_id: caseId, wait_ms: 200 })).result as { reply_id: string };
    await shim.request("reply.ack", { reply_id: first.reply_id });
    expect(store.getCase(caseId)!.replies).toHaveLength(1);
    expect(store.getCase(caseId)!.replies[0].state).toBe("delivered");
    expect(store.getCase(caseId)!.case.latest_reply_answer_text ?? null).toBeNull();
    const second = (await shim.request("case.wait", { case_id: caseId, wait_ms: 100 })).result as { reply_id?: string };
    expect(second.reply_id).toBeUndefined();
  });
});
