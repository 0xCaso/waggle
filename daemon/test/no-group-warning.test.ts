import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { NO_GROUP_WARNING } from "../src/guide/ste100";

// WAG-361: a request of 2 or more items warns when the items do not all share one group id.

type G = { id: string; title: string } | undefined;
const item = (id: string, group: G) => ({
  id,
  question: `Question ${id}?`,
  ...(group ? { group } : {}),
  options: [{ id: "a", title: "A", label: "A: one" }, { id: "b", title: "B", label: "B: two" }],
  recommendation: "a",
  recommendation_why: "It is simple.",
});
const g1: G = { id: "one", title: "Group one" };
const g2: G = { id: "two", title: "Group two" };
const ask = (...items: ReturnType<typeof item>[]) => ({ title: "Which ones?", need: "Pick", why: "Both matter", items }) as never;

function setup() {
  const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
  const task = store.createTask({ name: "t", project: "knock" });
  return { store, task };
}

describe("no group warning", () => {
  test("warns for no group, two groups and a mix", () => {
    const { store, task } = setup();
    expect(store.createCase(task.id, ask(item("x", undefined), item("y", undefined))).words_warning).toBe(NO_GROUP_WARNING);
    expect(store.createCase(task.id, ask(item("x", g1), item("y", g2))).words_warning).toBe(NO_GROUP_WARNING);
    expect(store.createCase(task.id, ask(item("x", g1), item("y", undefined))).words_warning).toBe(NO_GROUP_WARNING);
  });

  test("no warning for one item or one shared group", () => {
    const { store, task } = setup();
    expect(store.createCase(task.id, ask(item("x", undefined))).words_warning).toBeNull();
    expect(store.createCase(task.id, ask(item("x", g1), item("y", g1))).words_warning).toBeNull();
  });

  test("no warning for the questions shortcut", () => {
    const { store, task } = setup();
    const q = (id: string) => ({ id, title: `Q ${id}`, points: [{ id: "p", text: "Pick?" }] });
    const created = store.createCase(task.id, { title: "Q?", need: "Pick", why: "Both", questions: [q("x"), q("y")] } as never);
    expect(created.words_warning).toBeNull();
  });

  test("an update with items warns the same way", () => {
    const { store, task } = setup();
    const id = store.createCase(task.id, ask(item("x", undefined))).id;
    const upd = (...items: ReturnType<typeof item>[]) => ({ case_id: id, message: "Next?", items }) as never;
    expect(store.updateCase(id, upd(item("p", undefined), item("q", g1)))?.words_warning).toBe(NO_GROUP_WARNING);
    expect(store.updateCase(id, upd(item("p", g1), item("q", g1)))?.words_warning).toBeNull();
    expect(store.updateCase(id, upd(item("p", undefined)))?.words_warning).toBeNull();
  });
});
