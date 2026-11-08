import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { Store, CHOICE_WITH_CHANGES_LINE } from "../src/store";
import { ConnectorManager } from "../src/connectors/manager";
import type { KnockAskInput } from "../src/protocol";

// WAG-353: a choice with text reads as "approve with changes" for the agent.

const ask: KnockAskInput = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact layout", title: "Compact" },
    { id: "request_changes", label: "Ask for changes first", title: "Request changes" },
  ],
};

function seed() {
  const db = new Database(":memory:");
  const store = new Store(db, "/tmp/knock-test", new EventBus());
  const task = store.createTask({ name: "checkout", project: "knock" });
  store.createSession(task.id, { id: "sess-1", cwd: "/work", branch: null, pid: 4242 });
  return { store, caseId: store.createCase(task.id, ask).id };
}

const text = (store: Store, replyId: string): string => {
  const block = store.buildReplyPayload(replyId)!.content[0]!;
  return block.type === "text" ? block.text : "";
};

const base = { intent: "decision" as const, comments: [], captures: [] };

describe("approve with changes: agent wording", () => {
  test("a choice and a message says WITH CHANGES, then the message", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, { ...base, idempotency_key: "k1", choice: "a", message: "Also rename the tab." });
    const t = text(store, reply.id);
    expect(t).toContain("Choice: a (Compact layout)");
    expect(t).toContain(CHOICE_WITH_CHANGES_LINE);
    expect(t).toContain("WITH CHANGES");
    expect(t).toContain("Apply the changes");
    expect(t.indexOf("WITH CHANGES")).toBeLessThan(t.indexOf("Message: Also rename the tab."));
  });

  test("a choice with no message reads as before", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, { ...base, idempotency_key: "k1", choice: "a" });
    const t = text(store, reply.id);
    expect(t).toContain("Choice: a (Compact layout)");
    expect(t).not.toContain("WITH CHANGES");
  });

  test("a blank message adds no wording", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, { ...base, idempotency_key: "k1", choice: "a", message: "   " });
    expect(text(store, reply.id)).not.toContain("WITH CHANGES");
  });

  test("request_changes with a message keeps its own meaning", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, { ...base, idempotency_key: "k1", choice: "request_changes", message: "Fix X." });
    expect(text(store, reply.id)).not.toContain("WITH CHANGES");
  });

  test("a message with no choice is not approve with changes", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, { ...base, idempotency_key: "k1", message: "What about dark mode?" });
    expect(text(store, reply.id)).not.toContain("WITH CHANGES");
  });

  test("a chat connector reply with an option and text gives the same wording", () => {
    const { store, caseId } = seed();
    const manager = Object.create(ConnectorManager.prototype) as ConnectorManager;
    (manager as unknown as { store: Store }).store = store;
    const result = manager.answer("telegram", { case_id: caseId, key: "m1", choice: "a", message: "Use blue." });
    expect(result).toEqual({ ok: true, duplicate: false });
    const reply = store.findReplyByIdempotencyKey("telegram:m1")!;
    const t = text(store, reply.id);
    expect(t).toContain(CHOICE_WITH_CHANGES_LINE);
    expect(t).toContain("Message: Use blue.");
  });
});
