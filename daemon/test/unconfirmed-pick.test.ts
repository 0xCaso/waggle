import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { ItemAnswer } from "../src/protocol/nouns";
import { KnockAskInput } from "../src/protocol";

// WAG-328: a pre-selected recommendation is a suggestion. An item answer marked confirmed:false whose
// choice equals the recommendation is stored as Keep talking. No marker (an older app) keeps today's rules.

const ask: KnockAskInput = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact layout with a sidebar", title: "Compact" },
    { id: "b", label: "Detailed layout with tabs", title: "Detailed" },
  ],
};

function seed() {
  const db = new Database(":memory:");
  const store = new Store(db, "/tmp/knock-test", new EventBus());
  const task = store.createTask({ name: "checkout", project: "knock" });
  store.createSession(task.id, { id: "sess-1", cwd: "/work", branch: null, pid: 4242 });
  return { store, caseId: store.createCase(task.id, ask).id };
}

const submit = (store: Store, caseId: string, extra: Record<string, unknown>) =>
  store.submitReply(caseId, { idempotency_key: `k-${Math.random()}`, comments: [], captures: [], ...extra } as never);

describe("an unconfirmed pre-pick", () => {
  test("the schema takes the confirmed marker", () => {
    expect(ItemAnswer.parse({ item_id: "main", choice: "a", confirmed: false }).confirmed).toBe(false);
  });

  test("confirmed:false on the recommendation is stored as discuss, with no choice", () => {
    const { store, caseId } = seed();
    const reply = submit(store, caseId, {
      choice: "a",
      item_answers: [{ item_id: "main", choice: "a", confirmed: false }],
      message: "what about cost?",
    });
    expect(reply.intent).toBe("discuss");
    expect(reply.choice).toBeUndefined();
    expect(reply.item_answers ?? []).toEqual([]);
    expect(reply.outcome).toBe("talk");
  });

  test("a bare unconfirmed pre-pick has nothing to store and is refused", () => {
    const { store, caseId } = seed();
    expect(() => submit(store, caseId, { item_answers: [{ item_id: "main", choice: "a", confirmed: false }] })).toThrow();
  });

  test("confirmed:true is a decision and the marker is not stored", () => {
    const { store, caseId } = seed();
    const reply = submit(store, caseId, { item_answers: [{ item_id: "main", choice: "a", confirmed: true }] });
    expect(reply.intent).toBe("decision");
    expect(reply.choice).toBe("a");
    expect(reply.item_answers).toEqual([{ item_id: "main", choice: "a" }]);
  });

  test("no marker, from an older app, keeps today's rules", () => {
    const { store, caseId } = seed();
    const reply = submit(store, caseId, { item_answers: [{ item_id: "main", choice: "a" }] });
    expect(reply.intent).toBe("decision");
    expect(reply.choice).toBe("a");
  });

  test("confirmed:false on a choice that is not the recommendation stays a decision", () => {
    const { store, caseId } = seed();
    const reply = submit(store, caseId, { item_answers: [{ item_id: "main", choice: "b", confirmed: false }] });
    expect(reply.intent).toBe("decision");
    expect(reply.choice).toBe("b");
  });
});

// WAG-329: the same guard for a pick-many item. The pre-pick is the whole recommendation set.
describe("an unconfirmed pre-pick on a pick-many item", () => {
  const manyAsk = KnockAskInput.parse({
    ...ask,
    select: "many",
    recommendation: ["a", "c"],
    options: [
      { id: "a", label: "Rename the module", title: "Rename" },
      { id: "b", label: "Split the file", title: "Split" },
      { id: "c", label: "Update the docs", title: "Docs" },
    ],
  });
  function seedMany() {
    const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
    const task = store.createTask({ name: "checkout", project: "knock" });
    return { store, caseId: store.createCase(task.id, manyAsk).id };
  }

  test("confirmed:false on exactly the recommendation set is stored as discuss, in any order", () => {
    const { store, caseId } = seedMany();
    const reply = submit(store, caseId, {
      item_answers: [{ item_id: "main", choices: ["c", "a"], confirmed: false }],
      message: "why these two?",
    });
    expect(reply.intent).toBe("discuss");
    expect(reply.choices).toBeUndefined();
    expect(reply.item_answers ?? []).toEqual([]);
  });

  test("confirmed:true on the recommendation set is a decision and the marker is not stored", () => {
    const { store, caseId } = seedMany();
    const reply = submit(store, caseId, { item_answers: [{ item_id: "main", choices: ["a", "c"], confirmed: true }] });
    expect(reply.intent).toBe("decision");
    expect(reply.choices).toEqual(["a", "c"]);
    expect(JSON.stringify(reply.item_answers)).not.toContain("confirmed");
  });

  test("confirmed:false on a different set stays a decision", () => {
    const { store, caseId } = seedMany();
    const reply = submit(store, caseId, { item_answers: [{ item_id: "main", choices: ["a"], confirmed: false }] });
    expect(reply.intent).toBe("decision");
    expect(reply.choices).toEqual(["a"]);
  });
});
