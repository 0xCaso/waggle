import { afterEach, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { KnockAskInput, Option, PointOptionObject } from "../src/protocol";
import { rmrf, tmpHome } from "./helpers";

// WAG-360: an option carries up to 3 effect lines.

const homes: string[] = [];
afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

const ok = (effects: unknown) => Option.safeParse({ id: "x", label: "y", effects }).success;

describe("Option effects", () => {
  test("accepts 0 to 3 lines", () => {
    expect(ok([])).toBe(true);
    expect(ok(["a"])).toBe(true);
    expect(ok(["a", "b", "c"])).toBe(true);
  });

  test("refuses a fourth line, an empty line and a line over 160 characters", () => {
    expect(ok(["a", "b", "c", "d"])).toBe(false);
    expect(ok([""])).toBe(false);
    expect(ok(["   "])).toBe(false);
    expect(ok(["x".repeat(161)])).toBe(false);
    expect(ok(["x".repeat(160)])).toBe(true);
  });

  test("an option without effects parses unchanged", () => {
    expect(Option.parse({ id: "x", label: "y" })).toEqual({ id: "x", label: "y" });
  });

  test("a point option takes effects", () => {
    expect(PointOptionObject.safeParse({ label: "Yes", effects: ["a", "b"] }).success).toBe(true);
    expect(PointOptionObject.safeParse({ label: "Yes", effects: ["a", "b", "c", "d"] }).success).toBe(false);
  });
});

describe("effects in a stored ask", () => {
  function setup() {
    const home = tmpHome();
    homes.push(home);
    const store = new Store(new Database(join(home, "knock.db")), home, new EventBus());
    return { store, taskId: store.createTask({ name: "WAG-360", project: "app" }).id };
  }
  const base = { title: "Which flow?", need: "Which flow?", why: "It sets the first screen.", recommendation: "a", recommendation_why: "Simple." };

  test("effects come back from cases.get; an option without them has none", () => {
    const { store, taskId } = setup();
    const c = store.createCase(
      taskId,
      KnockAskInput.parse({
        ...base,
        options: [
          { id: "a", label: "One page", effects: ["Touches the form", "Closes the steps"] },
          { id: "b", label: "Steps" },
        ],
      }),
    );
    const options = store.getCase(c.id)!.case.options;
    expect(options[0]!.effects).toEqual(["Touches the form", "Closes the steps"]);
    expect("effects" in options[1]!).toBe(false);
  });

  test("a point option of a step carries effects into its item", () => {
    const { store, taskId } = setup();
    const c = store.createCase(
      taskId,
      KnockAskInput.parse({
        title: "Q",
        need: "Decide.",
        why: "Needed.",
        recommendation: "A",
        recommendation_why: "It is simple.",
        questions: [
          {
            id: "q1",
            title: "Q one",
            points: [{ id: "p1", text: "Which?", options: [{ label: "A", effects: ["Needs a migration"] }, "B"] }],
          },
        ],
      }),
    );
    const detail = JSON.stringify(store.getCase(c.id));
    expect(detail).toContain("Needs a migration");
  });
});
