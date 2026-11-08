import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import type { KnockAskInput } from "../src/protocol";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

// HAIL-67: the Case payload carries what a queue row needs to show that an ask
// came back after the human's reply (update_count, latest_update_*,
// revision_count), so cases.list needs no per-row detail fetch.

const question: KnockAskInput = {
  kind: "question",
  title: "Do the screens match?",
  need: "Confirm the screens match the design",
  why: "I cannot tell",
  recommendation: "a",
  recommendation_why: "They look the same",
  options: [
    { id: "a", label: "Yes" },
    { id: "b", label: "No" },
  ],
};

function setup(): { store: Store; caseId: string } {
  const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
  const task = store.createTask({ name: "OME-534", project: "app" });
  return { store, caseId: store.createCase(task.id, question).id };
}

// Timestamps are millisecond ISO strings and the rule is "after the reply".
const tick = (): void => Bun.sleepSync(3);

describe("update fields on Case", () => {
  test("a fresh case has no updates", () => {
    const { store, caseId } = setup();
    const c = store.getCase(caseId)!.case;
    expect(c).toMatchObject({
      update_count: 0,
      latest_update_at: null,
      latest_update_message: null,
      revision_count: 0,
    });
  });

  test("an update before any reply does not count", () => {
    const { store, caseId } = setup();
    store.updateCase(caseId, { case_id: caseId, message: "More context first" });
    const c = store.listCases("needs_you")[0];
    expect(c.update_count).toBe(0);
    expect(c.latest_update_at).toBeNull();
    expect(c.latest_update_message).toBeNull();
  });

  test("updates after the first reply are counted, newest wins", () => {
    const { store, caseId } = setup();
    store.updateCase(caseId, { case_id: caseId, message: "before" });
    tick();
    store.submitReply(caseId, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    tick();
    store.updateCase(caseId, { case_id: caseId, message: "first update" });
    tick();
    store.updateCase(caseId, { case_id: caseId, message: "second update" });
    const c = store.listCases("needs_you")[0];
    expect(c.status).toBe("needs_you");
    expect(c.update_count).toBe(2);
    expect(c.latest_update_message).toBe("second update");
    expect(c.latest_update_at).toBe(store.getCase(caseId)!.messages.at(-1)!.created_at);
    expect(Date.parse(c.latest_update_at!)).toBeGreaterThan(Date.parse(c.latest_reply_at!));
  });

  test("the message is cut to 140 characters", () => {
    const { store, caseId } = setup();
    store.submitReply(caseId, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    tick();
    store.updateCase(caseId, { case_id: caseId, message: "x".repeat(400) });
    expect(store.getCase(caseId)!.case.latest_update_message).toBe("x".repeat(140));
  });

  test("revision_count follows created revisions, with and without an update artifact", () => {
    const home = tmpHome();
    try {
      const cwd = join(home, "work");
      mkdirSync(cwd, { recursive: true });
      writeFileSync(join(cwd, "a.md"), "# One");
      writeFileSync(join(cwd, "b.md"), "# Two");
      const store = new Store(new Database(join(home, "knock.db")), home, new EventBus());
      const task = store.createTask({ name: "OME-534", project: "app" });
      const caseId = store.createCase(task.id, question).id;
      store.createRevision(caseId, stageIncoming(home, cwd, { type: "markdown", path: "./a.md" }));
      expect(store.getCase(caseId)!.case.revision_count).toBe(1);
      store.submitReply(caseId, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
      tick();
      store.updateCase(caseId, { case_id: caseId, message: "text only" });
      expect(store.getCase(caseId)!.case.revision_count).toBe(1);
      tick();
      store.updateCase(caseId, {
        case_id: caseId,
        message: "new revision",
        artifact: stageIncoming(home, cwd, { type: "markdown", path: "./b.md" }),
      });
      const c = store.getCase(caseId)!.case;
      expect(c.revision_count).toBe(2);
      expect(c.update_count).toBe(2);
      // HAIL-68: the newest revision's time, later than the reply.
      expect(c.latest_revision_at! > store.getCase(caseId)!.replies[0]!.created_at).toBe(true);
    } finally {
      rmrf(home);
    }
  });
});
