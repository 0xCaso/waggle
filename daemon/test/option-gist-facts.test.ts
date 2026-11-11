import { afterEach, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { KnockAskInput, KnockUpdateInput, Option, PointOptionObject } from "../src/protocol";
import { rmrf, tmpHome } from "./helpers";

// Option card "Gist and facts" (docs/decisions/2026-11-10-option-card-gist-and-facts.md): an option
// carries up to 3 short facts, and a pro or con is a string or { gist, detail }. Stored and served as sent.

const homes: string[] = [];
afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

function setup() {
  const home = tmpHome();
  homes.push(home);
  const store = new Store(new Database(join(home, "knock.db")), home, new EventBus());
  return { store, taskId: store.createTask({ name: "Cache", project: "app" }).id };
}

const base = { title: "Where does the cache live?", need: "Where does the cache live?", why: "It sets the store shape." };

const newOption = {
  id: "a",
  title: "One store file",
  label: "One store file: keep the cache in src/store.ts",
  facts: ["~2 h", "no migration", "src/store.ts"],
  pros: ["Easy to test", { gist: "One file to change", detail: "Only src/store.ts changes, so the review stays small" }],
  cons: [{ gist: "Memory only", detail: "The cache stays in memory and is lost on restart" }],
};
const oldOption = { id: "b", title: "New module", label: "New module: a cache module", pros: ["Clean split"], cons: ["More files"] };

const issues = (v: unknown) => {
  const r = Option.safeParse(v);
  return r.success ? [] : r.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`);
};

describe("Option facts and gists: schema", () => {
  test("an old option (strings only, no facts) parses unchanged", () => {
    expect(Option.parse(oldOption)).toEqual(oldOption);
    expect("facts" in Option.parse(oldOption)).toBe(false);
  });

  test("facts and mixed string and object pros parse as sent", () => {
    expect(Option.parse(newOption)).toEqual(newOption);
    expect(Option.parse({ id: "x", label: "y", facts: [] })).toEqual({ id: "x", label: "y", facts: [] });
  });

  test("trims facts, gists and details", () => {
    expect(Option.parse({ id: "x", label: "y", facts: [" ~2 h "], pros: [{ gist: " Short ", detail: " Long text " }] })).toEqual({
      id: "x",
      label: "y",
      facts: ["~2 h"],
      pros: [{ gist: "Short", detail: "Long text" }],
    });
  });

  test("refuses a fourth fact, a long fact and an empty fact with a clear message", () => {
    expect(issues({ id: "x", label: "y", facts: ["a", "b", "c", "d"] })).toEqual(["facts: an option has at most 3 facts"]);
    expect(issues({ id: "x", label: "y", facts: ["x".repeat(25)] })).toEqual([
      'facts.0: a fact is at most 24 characters, like "~2 h" or "no migration"',
    ]);
    expect(issues({ id: "x", label: "y", facts: ["x".repeat(24)] })).toEqual([]);
    expect(issues({ id: "x", label: "y", facts: ["  "] })).toEqual(["facts.0: a fact needs text"]);
  });

  test("refuses a long gist, a long detail and an object without both keys", () => {
    expect(issues({ id: "x", label: "y", pros: [{ gist: "x".repeat(41), detail: "d" }] })).toEqual([
      "pros.0.gist: a gist is at most 40 characters; put the full sentence in detail",
    ]);
    expect(issues({ id: "x", label: "y", cons: [{ gist: "x".repeat(40), detail: "d" }] })).toEqual([]);
    expect(issues({ id: "x", label: "y", cons: [{ gist: "g", detail: "x".repeat(161) }] })[0]).toStartWith("cons.0.detail:");
    expect(issues({ id: "x", label: "y", pros: [{ gist: "g" }] })).toEqual([
      "pros.0: a pro or con is a string, or { gist, detail } with both set",
    ]);
    expect(issues({ id: "x", label: "y", pros: [{ detail: "d" }] })).toEqual([
      "pros.0: a pro or con is a string, or { gist, detail } with both set",
    ]);
    expect(issues({ id: "x", label: "y", pros: ["a", "b", "c", "d", "e", { gist: "g", detail: "f" }] }).length).toBe(1);
  });

  test("a point option takes facts and gists too", () => {
    expect(PointOptionObject.parse({ label: "Yes", facts: ["~1 h"], pros: [{ gist: "g", detail: "d" }] })).toEqual({
      label: "Yes",
      facts: ["~1 h"],
      pros: [{ gist: "g", detail: "d" }],
    });
    expect(PointOptionObject.safeParse({ label: "Yes", facts: ["a", "b", "c", "d"] }).success).toBe(false);
  });

  test("waggle_ask refuses over-limit facts in top-level options and in items", () => {
    const tooMany = { ...newOption, facts: ["a", "b", "c", "d"] };
    const top = KnockAskInput.safeParse({ ...base, recommendation: "a", recommendation_why: "Small.", options: [tooMany, oldOption] });
    expect(top.success).toBe(false);
    expect(top.error!.issues.map((i) => `${i.path.join(".")}: ${i.message}`)).toContain("options.0.facts: an option has at most 3 facts");
    const inItem = KnockAskInput.safeParse({
      ...base,
      items: [{ id: "cache", options: [oldOption, { ...newOption, pros: [{ gist: "x".repeat(41), detail: "d" }] }], recommendation: "b", recommendation_why: "Clean." }],
    });
    expect(inItem.success).toBe(false);
    expect(inItem.error!.issues.map((i) => i.path.join("."))).toContain("items.0.options.1.pros.0.gist");
  });
});

describe("Option facts and gists: stored and returned", () => {
  test("an old ask comes back exactly as before", () => {
    const { store, taskId } = setup();
    const c = store.createCase(
      taskId,
      KnockAskInput.parse({ ...base, recommendation: "b", recommendation_why: "Clean.", options: [{ ...oldOption, id: "a" }, oldOption] }),
    );
    const detail = store.getCase(c.id)!;
    expect(detail.case.options[1]).toEqual(oldOption);
    expect(detail.case.items![0]!.options[1]).toEqual(oldOption);
    expect(JSON.stringify(detail)).not.toContain('"facts"');
    expect(JSON.stringify(detail)).not.toContain('"gist"');
  });

  test("facts and mixed pros come back from cases.get, cases.list and the items", () => {
    const { store, taskId } = setup();
    const c = store.createCase(
      taskId,
      KnockAskInput.parse({ ...base, recommendation: "a", recommendation_why: "Small.", options: [newOption, oldOption] }),
    );
    const detail = store.getCase(c.id)!;
    expect(detail.case.options[0]).toEqual(newOption);
    expect(detail.case.options[1]).toEqual(oldOption);
    expect(detail.case.items![0]!.options[0]).toEqual(newOption);
    expect(store.listCases().find((x) => x.id === c.id)!.options[0]).toEqual(newOption);
  });

  test("an item option keeps facts and gists", () => {
    const { store, taskId } = setup();
    const c = store.createCase(
      taskId,
      KnockAskInput.parse({
        ...base,
        items: [
          { id: "cache", question: "Where?", options: [newOption, oldOption], recommendation: "a", recommendation_why: "Small." },
          { id: "ttl", question: "How long?", options: [{ id: "s", label: "Short", facts: ["5 min"] }, { id: "l", label: "Long" }], recommendation: "s", recommendation_why: "Fresh." },
        ],
      }),
    );
    const items = store.getCase(c.id)!.case.items!;
    expect(items[0]!.options[0]).toEqual(newOption);
    expect(items[1]!.options[0]).toEqual({ id: "s", label: "Short", facts: ["5 min"] });
    expect("facts" in items[1]!.options[1]!).toBe(false);
  });

  test("waggle_update options keep facts and gists", () => {
    const { store, taskId } = setup();
    const c = store.createCase(
      taskId,
      KnockAskInput.parse({ ...base, recommendation: "b", recommendation_why: "Clean.", options: [{ ...oldOption, id: "a" }, oldOption] }),
    );
    const upd = KnockUpdateInput.parse({
      case_id: c.id,
      message: "A smaller option.",
      options: [{ ...newOption, id: "c" }],
      recommendation: "c",
      recommendation_why: "Small.",
    });
    store.updateCase(c.id, upd);
    const detail = store.getCase(c.id)!;
    expect(detail.case.options[0]).toEqual({ ...newOption, id: "c" });
    expect(JSON.stringify(detail)).toContain('"gist":"One file to change"');
  });

  test("a source marker in a gist or a detail is checked like any text", () => {
    const { store, taskId } = setup();
    const c = store.createCase(
      taskId,
      KnockAskInput.parse({
        ...base,
        recommendation: "a",
        recommendation_why: "Small.",
        sources: [{ id: "s1", kind: "file", label: "src/store.ts" }],
        options: [
          { id: "a", label: "A", pros: [{ gist: "One file [[s:s1]]", detail: "Only one file [[s:zz]]" }] },
          { id: "b", label: "B" },
        ],
      }),
    );
    expect(store.getCase(c.id)!.case.options[0]!.pros).toEqual([{ gist: "One file [[s:s1]]", detail: "Only one file" }]);
  });
});
