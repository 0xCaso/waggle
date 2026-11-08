import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { checkAskWords, TITLE_WARNING, titleLengthWarning, wordsWarning } from "../src/guide/ste100";
import type { KnockAskInput, KnockUpdateInput } from "../src/protocol";

// HAIL-140: the ASD-STE100 checker. It reports the limits an ask breaks and
// never rejects it; the store turns a non-empty list into the one warning line
// only while `askWords` is "asd".

const words = (n: number): string => Array(n).fill("w").join(" ");

const clean: KnockAskInput = {
  kind: "question",
  title: "Checkout layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It fits on one line",
  options: [{ id: "a", title: "Compact", label: "Compact: one screen" }],
};

function newStore(): { store: Store } {
  const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
  return { store };
}

describe("checkAskWords", () => {
  test("clean ask has no violations", () => {
    expect(checkAskWords({ need: clean.need, why: clean.why, options: clean.options, recommendation_why: clean.recommendation_why })).toEqual([]);
  });

  test("need sentence over 20 words", () => {
    expect(checkAskWords({ need: words(21) })).toEqual(["need sentence over 20 words"]);
  });

  test("need sentence at exactly 20 words is fine", () => {
    expect(checkAskWords({ need: words(20) })).toEqual([]);
  });

  test("why sentence over 25 words", () => {
    expect(checkAskWords({ why: words(26) })).toEqual(["why sentence over 25 words"]);
  });

  test("why over 3 sentences", () => {
    expect(checkAskWords({ why: "One. Two. Three. Four." })).toEqual(["why over 3 sentences"]);
  });

  test("option label sentence over 20 words", () => {
    expect(checkAskWords({ options: [{ label: words(21) }] })).toEqual(["option label sentence over 20 words"]);
  });

  test("option title over 6 words", () => {
    expect(checkAskWords({ options: [{ label: "L", title: words(7) }] })).toEqual(["option title over 6 words"]);
  });

  test("recommendation_why sentence over 25 words", () => {
    expect(checkAskWords({ recommendation_why: words(26) })).toEqual(["recommendation_why sentence over 25 words"]);
  });

  test("more than 6 options", () => {
    const options = Array.from({ length: 7 }, (_, i) => ({ label: `Option ${i}` }));
    expect(checkAskWords({ options })).toEqual(["over 6 options"]);
  });

  test("a paragraph over 6 sentences", () => {
    expect(checkAskWords({ need: "One. Two. Three. Four. Five. Six. Seven." })).toEqual([
      "a paragraph over 6 sentences",
    ]);
  });

  test("collects several limits once, in order", () => {
    const violations = checkAskWords({
      need: words(21),
      why: words(26),
      options: Array.from({ length: 7 }, (_, i) => ({ label: `Option ${i}` })),
      recommendation_why: words(26),
    });
    expect(violations).toEqual([
      "need sentence over 20 words",
      "why sentence over 25 words",
      "over 6 options",
      "recommendation_why sentence over 25 words",
    ]);
  });

  test("wordsWarning formats the one line", () => {
    expect(wordsWarning(["need sentence over 20 words", "why over 3 sentences"])).toBe(
      "Waggle: this ask breaks ASD-STE100 limits (need sentence over 20 words, why over 3 sentences).",
    );
  });
});

describe("store words warning", () => {
  test("a breaking ask carries the warning in asd mode; a clean ask does not", () => {
    const { store } = newStore();
    const task = store.createTask({ name: "checkout", project: "knock" });
    expect(store.getAskWords()).toBe("asd");

    const broken = store.createCase(task.id, { ...clean, need: words(21) });
    expect(broken.words_warning).toBe("Waggle: this ask breaks ASD-STE100 limits (need sentence over 20 words).");

    const good = store.createCase(task.id, clean);
    expect(good.words_warning).toBeNull();
  });

  test("normal mode adds no warning and never rejects", () => {
    const { store } = newStore();
    const task = store.createTask({ name: "checkout", project: "knock" });
    store.setAskWords("normal");
    const created = store.createCase(task.id, { ...clean, need: words(21) });
    expect(created.words_warning).toBeNull();
    expect(store.listCases()).toHaveLength(1);
  });

  test("update with a breaking proposal carries the warning; clean and normal do not", () => {
    const { store } = newStore();
    const task = store.createTask({ name: "checkout", project: "knock" });
    const id = store.createCase(task.id, clean).id;

    const breaking: KnockUpdateInput = {
      case_id: id,
      message: "New choices",
      options: Array.from({ length: 7 }, (_, i) => ({ id: `o${i}`, label: `Option ${i}` })),
      recommendation: "o0",
    };
    expect(store.updateCase(id, breaking)?.words_warning).toBe("Waggle: this ask breaks ASD-STE100 limits (over 6 options).");

    const tidy: KnockUpdateInput = {
      case_id: id,
      message: "Two choices",
      options: [{ id: "a", label: "Compact" }, { id: "b", label: "Detailed" }],
      recommendation: "a",
    };
    expect(store.updateCase(id, tidy)?.words_warning).toBeNull();

    store.setAskWords("normal");
    expect(store.updateCase(id, breaking)?.words_warning).toBeNull();
  });
});

// WAG-249: the title stays short. The warning does not depend on the writing mode.
describe("title length warning", () => {
  const over80 = "Here is the side panel variant. Open a flagged conversation. The panel slides in from the right.";

  test("titleLengthWarning checks the first line only, at 80 characters", () => {
    expect(titleLengthWarning("Ship the side panel?")).toBeNull();
    expect(titleLengthWarning("a".repeat(80))).toBeNull();
    expect(titleLengthWarning("a".repeat(81))).toBe(TITLE_WARNING);
    expect(titleLengthWarning(`Short question?\n\n${over80}`)).toBeNull();
    expect(titleLengthWarning(undefined)).toBeNull();
  });

  test("an update with options and a long first line carries the warning, in any mode", () => {
    const { store } = newStore();
    const task = store.createTask({ name: "checkout", project: "knock" });
    const id = store.createCase(task.id, clean).id;
    const update = (message: string, withOptions = true): KnockUpdateInput => ({
      case_id: id,
      message,
      ...(withOptions
        ? { options: [{ id: "a", label: "Compact" }, { id: "b", label: "Detailed" }], recommendation: "a" }
        : {}),
    });
    expect(store.updateCase(id, update(over80))?.words_warning).toBe(TITLE_WARNING);
    expect(store.updateCase(id, update(`Which layout?\n\n${over80}`))?.words_warning).toBeNull();
    expect(store.updateCase(id, update(over80, false))?.words_warning).toBeNull();
    store.setAskWords("normal");
    expect(store.updateCase(id, update(over80))?.words_warning).toBe(TITLE_WARNING);
  });

  test("an ask with a long title carries the warning next to the ASD line", () => {
    const { store } = newStore();
    const task = store.createTask({ name: "checkout", project: "knock" });
    const created = store.createCase(task.id, { ...clean, title: over80, need: words(21) });
    expect(created.words_warning).toBe(
      `Waggle: this ask breaks ASD-STE100 limits (need sentence over 20 words). ${TITLE_WARNING}`,
    );
    expect(store.createCase(task.id, { ...clean, title: over80 }).words_warning).toBe(TITLE_WARNING);
  });
});
