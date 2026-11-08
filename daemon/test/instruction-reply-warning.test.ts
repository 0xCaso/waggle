import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { INSTRUCTION_REPLY_WARNING } from "../src/guide/ste100";

// WAG-371: a reply item whose suggested reply reads as an instruction to the human gets a warning.

const reply = (recommendation?: string) => ({
  id: "r",
  question: "What did the app show after you saved the check?",
  select: "reply",
  ...(recommendation !== undefined ? { recommendation, recommendation_why: "It is likely." } : {}),
});
const pick = (recommendation: string) => ({
  id: "p",
  question: "Which one?",
  options: [{ id: "a", title: "A", label: "A: one" }, { id: "b", title: "B", label: "B: two" }],
  recommendation,
  recommendation_why: "It is simple.",
});
const ask = (item: object) => ({ title: "What did you see?", need: "Tell us", why: "We need it", items: [item] }) as never;

function setup() {
  const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
  return { store, task: store.createTask({ name: "t", project: "knock" }) };
}

describe("instruction reply warning", () => {
  test("warns when the suggested reply starts like an instruction", () => {
    const { store, task } = setup();
    for (const text of ["Describe the button and the next screen.", "  please share a log", "Let me know what you see", "TELL ME more"]) {
      expect(store.createCase(task.id, ask(reply(text))).words_warning).toBe(INSTRUCTION_REPLY_WARNING);
    }
  });

  test("a reply item with no recommendation is accepted without a warning", () => {
    const { store, task } = setup();
    expect(store.createCase(task.id, ask(reply())).words_warning).toBeNull();
  });

  test("a real answer does not warn", () => {
    const { store, task } = setup();
    expect(store.createCase(task.id, ask(reply("It showed the home screen with no error."))).words_warning).toBeNull();
  });

  test("a pick-one item is not checked", () => {
    const { store, task } = setup();
    expect(store.createCase(task.id, ask(pick("a"))).words_warning).toBeNull();
  });

  test("an update with items warns the same way", () => {
    const { store, task } = setup();
    const id = store.createCase(task.id, ask(reply())).id;
    const upd = (item: object) => ({ case_id: id, message: "Next?", items: [item] }) as never;
    expect(store.updateCase(id, upd(reply("Paste the error.")))?.words_warning).toBe(INSTRUCTION_REPLY_WARNING);
    expect(store.updateCase(id, upd(reply()))?.words_warning).toBeNull();
  });
});
