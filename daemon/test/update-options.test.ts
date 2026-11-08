import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { ChoiceNotOfferedError, Store } from "../src/store";
import { KnockUpdateInput, MCP_TOOLS } from "../src/protocol";
import type { KnockAskInput } from "../src/protocol";
import { CaseListRow, toCaseListRow } from "../src/protocol/rpc";

// HAIL-108: waggle_update may carry a new option set. The case's options follow
// the newest set; the first set stays reachable.

const ask: KnockAskInput = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", title: "Compact", label: "Compact layout" },
    { id: "b", title: "Detailed", label: "Detailed layout" },
    { id: "c", label: "Something else" },
  ],
};

const newOptions = [
  { id: "x", title: "Two steps", label: "Ship the schema first, then the UI" },
  { id: "a", title: "One step", label: "Ship both together" },
];

function setup(): { store: Store; caseId: string } {
  const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
  const task = store.createTask({ name: "HAIL-108", project: "app" });
  return { store, caseId: store.createCase(task.id, ask).id };
}

const tick = (): void => Bun.sleepSync(3);

describe("KnockUpdateInput schema", () => {
  const base = { case_id: "c1", message: "m" };

  test("message and artifact only still parse (old agents)", () => {
    expect(KnockUpdateInput.safeParse(base).success).toBe(true);
  });

  test("options with a recommendation that names one of them parse", () => {
    const r = KnockUpdateInput.safeParse({ ...base, options: newOptions, recommendation: "x", recommendation_why: "Smaller" });
    expect(r.success).toBe(true);
  });

  test("a recommendation outside the new options is rejected", () => {
    const r = KnockUpdateInput.safeParse({ ...base, options: newOptions, recommendation: "b" });
    expect(r.success).toBe(false);
    expect(JSON.stringify(r.error?.issues)).toContain("recommendation must equal one option id");
  });

  test("options without a recommendation are rejected", () => {
    expect(KnockUpdateInput.safeParse({ ...base, options: newOptions }).success).toBe(false);
  });

  test("a recommendation without options is rejected", () => {
    expect(KnockUpdateInput.safeParse({ ...base, recommendation: "a" }).success).toBe(false);
  });

  test("recommendation_why over 300 characters is rejected", () => {
    const r = KnockUpdateInput.safeParse({
      ...base,
      options: newOptions,
      recommendation: "x",
      recommendation_why: "y".repeat(301),
    });
    expect(r.success).toBe(false);
    expect(JSON.stringify(r.error?.issues)).toContain("the maximum is 300");
  });

  test("an option title longer than 80 characters is rejected like in waggle_ask", () => {
    const r = KnockUpdateInput.safeParse({
      ...base,
      options: [{ id: "x", label: "l", title: "t".repeat(81) }],
      recommendation: "x",
    });
    expect(r.success).toBe(false);
  });

  test("the MCP tool definition lists the new fields", () => {
    const tool = MCP_TOOLS.find((t) => t.name === "waggle_update")!;
    const props = (tool.inputSchema as { properties: Record<string, unknown> }).properties;
    expect(Object.keys(props)).toEqual(
      expect.arrayContaining(["options", "recommendation", "recommendation_why"]),
    );
  });
});

describe("option sets in the store", () => {
  test("a fresh case: first set equals the newest, no update time", () => {
    const { store, caseId } = setup();
    const c = store.getCase(caseId)!.case;
    expect(c.options).toEqual(ask.options!);
    expect(c.first_options).toEqual(ask.options!);
    expect(c.first_recommendation).toBe("a");
    expect(c.options_updated_at).toBeNull();
    expect(c.latest_reply_from_first_options).toBe(false);
  });

  test("an update with options makes them the case's options and keeps the first set", () => {
    const { store, caseId } = setup();
    store.submitReply(caseId, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    tick();
    const updated = store.updateCase(caseId, {
      case_id: caseId,
      message: "Here is a new proposal",
      options: newOptions,
      recommendation: "x",
      recommendation_why: "Smaller review",
    })!;
    expect(updated.status).toBe("needs_you");
    expect(updated.options).toEqual(newOptions);
    expect(updated.recommendation).toBe("x");
    expect(updated.recommendation_why).toBe("Smaller review");
    expect(updated.first_options).toEqual(ask.options!);
    expect(updated.first_recommendation).toBe("a");
    expect(updated.options_updated_at).toBe(updated.latest_update_at!);
  });

  test("HAIL-174: the newest set carries its seq and the update message as the round question", () => {
    const { store, caseId } = setup();
    expect(store.getCase(caseId)!.case.options_seq).toBe(0);
    expect(store.getCase(caseId)!.case.round_question).toBeNull();
    store.submitReply(caseId, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    tick();
    const message = "Which layout now?\n\nI changed the header.\n\nPick one.";
    const updated = store.updateCase(caseId, {
      case_id: caseId, message, options: newOptions, recommendation: "x",
    })!;
    expect(updated.options_seq).toBe(1);
    expect(updated.round_question).toBe(message);
  });

  test("an update without options leaves the sets alone (old agent path)", () => {
    const { store, caseId } = setup();
    store.submitReply(caseId, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    tick();
    const updated = store.updateCase(caseId, { case_id: caseId, message: "Just a note" })!;
    expect(updated.options).toEqual(ask.options!);
    expect(updated.recommendation).toBe("a");
    expect(updated.options_updated_at).toBeNull();
    expect(updated.latest_update_at).not.toBeNull();
  });

  test("a later update without options does not hide the options an earlier update sent", () => {
    const { store, caseId } = setup();
    store.updateCase(caseId, { case_id: caseId, message: "p", options: newOptions, recommendation: "x" });
    tick();
    const c = store.updateCase(caseId, { case_id: caseId, message: "note" })!;
    expect(c.options).toEqual(newOptions);
    expect(c.options_updated_at).not.toBeNull();
  });

  test("a second update with options replaces the newest set; the first set stays the ask's", () => {
    const { store, caseId } = setup();
    store.updateCase(caseId, { case_id: caseId, message: "p1", options: newOptions, recommendation: "x" });
    const third = [{ id: "z", label: "Third" }];
    const c = store.updateCase(caseId, { case_id: caseId, message: "p2", options: third, recommendation: "z" })!;
    expect(c.options).toEqual(third);
    expect(c.first_options).toEqual(ask.options!);
  });

  test("a detail reply update with options follows the same rules", () => {
    const { store, caseId } = setup();
    store.submitReply(caseId, {
      idempotency_key: "d1",
      message: "why?",
      intent: "more_detail",
      comments: [],
      captures: [],
    });
    const c = store.updateCase(caseId, {
      case_id: caseId,
      message: "Because",
      options: newOptions,
      recommendation: "x",
    })!;
    expect(c.options).toEqual(newOptions);
    expect(c.status).toBe("needs_you");
  });
});

describe("choice validation across both sets", () => {
  function updated() {
    const { store, caseId } = setup();
    store.updateCase(caseId, {
      case_id: caseId,
      message: "new",
      options: newOptions,
      recommendation: "x",
    });
    return { store, caseId };
  }
  const reply = (key: string, extra: Record<string, unknown>) => ({
    idempotency_key: key,
    comments: [],
    captures: [],
    ...extra,
  });

  test("an id from the newest set is accepted", () => {
    const { store, caseId } = updated();
    const r = store.submitReply(caseId, reply("k", { choice: "x" }));
    expect(r.choice).toBe("x");
    expect(store.getCase(caseId)!.case.latest_reply_from_first_options).toBe(false);
  });

  test("an id only the first set has is accepted and marked as from the first set", () => {
    const { store, caseId } = updated();
    store.submitReply(caseId, reply("k", { choice: "b" }));
    expect(store.getCase(caseId)!.case.latest_reply_from_first_options).toBe(true);
  });

  test("an id in neither set is rejected and stores no reply", () => {
    const { store, caseId } = updated();
    expect(() => store.submitReply(caseId, reply("k", { choice: "nope" }))).toThrow(ChoiceNotOfferedError);
    expect(store.getCase(caseId)!.replies).toHaveLength(0);
    expect(store.getCase(caseId)!.case.status).toBe("needs_you");
  });

  test("an id both sets use goes to the newest set, or the first with options_set first", () => {
    const { store, caseId } = updated();
    store.submitReply(caseId, reply("k1", { choice: "a" }));
    expect(store.getCase(caseId)!.case.latest_reply_from_first_options).toBe(false);
    tick();
    store.submitReply(caseId, reply("k2", { choice: "a", options_set: "first" }));
    expect(store.getCase(caseId)!.case.latest_reply_from_first_options).toBe(true);
  });

  test("options_set first with an id the first set lacks is rejected", () => {
    const { store, caseId } = updated();
    expect(() => store.submitReply(caseId, reply("k", { choice: "x", options_set: "first" }))).toThrow(
      ChoiceNotOfferedError,
    );
  });

  test("replace re-validates and re-records the set", () => {
    const { store, caseId } = updated();
    const r = store.submitReply(caseId, reply("k", { choice: "x" }));
    store.replaceReply(r.id, reply("k", { choice: "b" }));
    expect(store.getCase(caseId)!.case.latest_reply_from_first_options).toBe(true);
    expect(() => store.replaceReply(r.id, reply("k", { choice: "nope" }))).toThrow(ChoiceNotOfferedError);
  });

  test("a case that never had options still accepts any text choice (old path)", () => {
    const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
    const task = store.createTask({ name: "t", project: "p" });
    const { options: _o, ...noOptions } = ask;
    const id = store.createCase(task.id, noOptions).id;
    expect(store.submitReply(id, reply("k", { choice: "whatever" })).choice).toBe("whatever");
  });
});

describe("reply text names the title from the set it came from", () => {
  function text(store: Store, replyId: string): string {
    return store.buildReplyPayload(replyId)!.content[0]!.type === "text"
      ? (store.buildReplyPayload(replyId)!.content[0] as { text: string }).text
      : "";
  }

  test("a newest-set choice reads the new label", () => {
    const { store, caseId } = setup();
    store.updateCase(caseId, { case_id: caseId, message: "n", options: newOptions, recommendation: "x" });
    const r = store.submitReply(caseId, { idempotency_key: "k", choice: "a", comments: [], captures: [] });
    expect(text(store, r.id)).toContain("Choice: a (Ship both together)");
  });

  test("a first-set choice reads the first label, even when the newest set reuses the id", () => {
    const { store, caseId } = setup();
    store.updateCase(caseId, { case_id: caseId, message: "n", options: newOptions, recommendation: "x" });
    const r = store.submitReply(caseId, {
      idempotency_key: "k",
      choice: "a",
      options_set: "first",
      comments: [],
      captures: [],
    });
    expect(text(store, r.id)).toContain("Choice: a (Compact layout)");
  });

  test("a reply to a case with no update reads as before", () => {
    const { store, caseId } = setup();
    const r = store.submitReply(caseId, { idempotency_key: "k", choice: "b", comments: [], captures: [] });
    expect(text(store, r.id)).toContain("Choice: b (Detailed layout)");
  });
});

describe("migration 20", () => {
  test("backfills set 0 for existing cases", () => {
    const { store, caseId } = setup();
    const db = (store as unknown as { db: Database }).db;
    db.exec("DELETE FROM option_sets");
    db.exec("PRAGMA user_version = 19");
    const { migrate } = require("../src/schema") as typeof import("../src/schema");
    migrate(db);
    const row = db.query(`SELECT seq, recommendation FROM option_sets WHERE case_id = ?`).get(caseId);
    expect(row).toEqual({ seq: 0, recommendation: "a" });
  });
});

describe("cases.list rows (PERF-4)", () => {
  test("first_options is left out while it equals options, and kept once an update changed them", () => {
    const { store, caseId } = setup();
    const same = toCaseListRow(store.getCase(caseId)!.case);
    expect("first_options" in same).toBe(false);
    expect(CaseListRow.parse(same).options).toEqual(ask.options!);
    store.submitReply(caseId, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    tick();
    const updated = store.updateCase(caseId, {
      case_id: caseId,
      message: "New proposal",
      options: newOptions,
      recommendation: "x",
      recommendation_why: "Smaller",
    })!;
    const diff = toCaseListRow(updated);
    expect(diff.first_options).toEqual(ask.options!);
    expect(CaseListRow.parse(diff).first_options).toEqual(ask.options!);
  });

  test("a row carries the task name and the artifact kind the queue needs", () => {
    const { store, caseId } = setup();
    const row = toCaseListRow(store.getCase(caseId)!.case);
    expect(typeof row.task_name).toBe("string");
    expect(row).toHaveProperty("artifact_kind");
    expect(row).toHaveProperty("has_artifact");
  });
});
