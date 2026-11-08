import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { ChoiceNotOfferedError, Store } from "../src/store";
import { KnockAskInput, KnockUpdateInput, MCP_TOOLS, ReplySubmitParams } from "../src/protocol";

// HAIL-123: select "many" asks. The human ticks several options and sends them together.

const options = [
  { id: "a", title: "Rename", label: "Rename the module" },
  { id: "b", title: "Split", label: "Split the file" },
  { id: "c", title: "Docs", label: "Update the docs" },
];

const base = {
  kind: "question" as const,
  title: "Which cleanups?",
  need: "Which cleanups should I do?",
  why: "They touch the same files.",
  recommendation_why: "Cheap and safe.",
  options,
};

const many = { ...base, select: "many" as const, recommendation: ["a", "c"] };

function setup(ask: Record<string, unknown> = many): { store: Store; caseId: string } {
  const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
  store.setAskAfterDecide("none"); // WAG-385: these tests pin the reply text without the "After you decide" line
  const task = store.createTask({ name: "HAIL-123", project: "app" });
  return { store, caseId: store.createCase(task.id, KnockAskInput.parse(ask)).id };
}

const submit = (store: Store, caseId: string, extra: Record<string, unknown>, key = "k") =>
  store.submitReply(caseId, { idempotency_key: key, comments: [], captures: [], ...extra });

describe("KnockAskInput select / max", () => {
  test("select defaults to one and a single recommendation still parses", () => {
    const r = KnockAskInput.safeParse({ ...base, recommendation: "a" });
    expect(r.success).toBe(true);
    expect(r.data?.select).toBeUndefined();
  });

  test("many takes a list of recommendations and a max", () => {
    expect(KnockAskInput.safeParse({ ...many, max: 2 }).success).toBe(true);
    expect(KnockAskInput.safeParse({ ...many, recommendation: "a" }).success).toBe(true);
  });

  test("max needs many", () => {
    const r = KnockAskInput.safeParse({ ...base, recommendation: "a", max: 2 });
    expect(r.success).toBe(false);
    expect(JSON.stringify(r.error?.issues)).toContain("max only works with select");
  });

  test("max must be at least 1 and at most the number of options", () => {
    expect(KnockAskInput.safeParse({ ...many, max: 0 }).success).toBe(false);
    expect(KnockAskInput.safeParse({ ...many, max: 1.5 }).success).toBe(false);
    const r = KnockAskInput.safeParse({ ...many, max: 4 });
    expect(r.success).toBe(false);
    expect(JSON.stringify(r.error?.issues)).toContain("only 3 options");
    expect(KnockAskInput.safeParse({ ...many, max: 3 }).success).toBe(true);
  });

  test("every recommended id must be an option", () => {
    const r = KnockAskInput.safeParse({ ...many, recommendation: ["a", "z"] });
    expect(r.success).toBe(false);
    expect(JSON.stringify(r.error?.issues)).toContain("not an option id: z");
  });

  test("more recommendations than max are rejected", () => {
    expect(KnockAskInput.safeParse({ ...many, max: 1 }).success).toBe(false);
  });

  test("a list needs select many", () => {
    expect(KnockAskInput.safeParse({ ...base, recommendation: ["a", "b"] }).success).toBe(false);
  });

  test("many without options is rejected", () => {
    const { options: _o, ...noOptions } = many;
    expect(KnockAskInput.safeParse(noOptions).success).toBe(false);
  });

  test("the tool schema advertises select and max", () => {
    const schema = MCP_TOOLS.find((t) => t.name === "waggle_ask")!.inputSchema as {
      properties: Record<string, unknown>;
    };
    expect(Object.keys(schema.properties)).toEqual(expect.arrayContaining(["select", "max"]));
  });
});

describe("KnockUpdateInput select / max", () => {
  const upd = { case_id: "c1", message: "m", options, recommendation_why: "why" };

  test("accepts the same fields", () => {
    expect(KnockUpdateInput.safeParse({ ...upd, select: "many", max: 2, recommendation: ["a", "b"] }).success).toBe(true);
  });

  test("rejects a max over the options, and select without options", () => {
    expect(KnockUpdateInput.safeParse({ ...upd, select: "many", max: 9, recommendation: "a" }).success).toBe(false);
    expect(KnockUpdateInput.safeParse({ case_id: "c1", message: "m", select: "many" }).success).toBe(false);
  });
});

describe("stored multi-select case", () => {
  test("the case carries select, max and the recommended list", () => {
    const { store, caseId } = setup({ ...many, max: 2 });
    const c = store.getCase(caseId)!.case;
    expect(c.select).toBe("many");
    expect(c.max).toBe(2);
    expect(c.recommendations).toEqual(["a", "c"]);
    expect(c.recommendation).toBe("a");
  });

  test("a single-choice ask reads as before", () => {
    const { store, caseId } = setup({ ...base, recommendation: "b" });
    const c = store.getCase(caseId)!.case;
    expect([c.select, c.max, c.recommendations, c.recommendation]).toEqual(["one", null, ["b"], "b"]);
  });

  test("an update with options can switch to many", () => {
    const { store, caseId } = setup({ ...base, recommendation: "b" });
    store.updateCase(caseId, KnockUpdateInput.parse({
      case_id: caseId, message: "m", options, select: "many", max: 2, recommendation: ["a", "b"], recommendation_why: "w",
    }));
    const c = store.getCase(caseId)!.case;
    expect([c.select, c.max, c.recommendations]).toEqual(["many", 2, ["a", "b"]]);
  });
});

describe("reply choices", () => {
  test("a valid pick is stored and shown on the case", () => {
    const { store, caseId } = setup({ ...many, max: 2 });
    const r = submit(store, caseId, { choices: ["c", "a"] });
    expect(r.choices).toEqual(["c", "a"]);
    expect(r.choice).toBeUndefined();
    expect(store.getCase(caseId)!.case.latest_reply_choices).toEqual(["c", "a"]);
  });

  test("an id that is not an option is rejected", () => {
    const { store, caseId } = setup();
    expect(() => submit(store, caseId, { choices: ["a", "z"] })).toThrow(ChoiceNotOfferedError);
  });

  test("more than max is rejected", () => {
    const { store, caseId } = setup({ ...many, max: 2 });
    expect(() => submit(store, caseId, { choices: ["a", "b", "c"] })).toThrow(/max is 2/);
  });

  test("a repeated id is rejected", () => {
    const { store, caseId } = setup();
    expect(() => submit(store, caseId, { choices: ["a", "a"] })).toThrow(/twice/);
  });

  test("zero choices need a message", () => {
    const { store, caseId } = setup();
    expect(() => submit(store, caseId, { choices: [] })).toThrow(/message/);
    const r = submit(store, caseId, { choices: [], message: "None of these fit" }, "k2");
    expect(r.choices).toEqual([]);
  });

  test("choices on a single-choice ask are rejected", () => {
    const { store, caseId } = setup({ ...base, recommendation: "a" });
    expect(() => submit(store, caseId, { choices: ["a"] })).toThrow(/one choice/);
  });

  test("choice and choices together are rejected", () => {
    const { store, caseId } = setup();
    expect(() => submit(store, caseId, { choice: "a", choices: ["b"] })).toThrow(/not both/);
  });

  test("the old single path still works", () => {
    const { store, caseId } = setup({ ...base, recommendation: "a" });
    const r = submit(store, caseId, { choice: "b" });
    expect(r.choice).toBe("b");
    expect(r.choices).toBeUndefined();
    expect(store.buildReplyPayload(r.id)!.content[0]).toEqual({
      type: "text",
      text: expect.stringContaining("Choice: b (Split the file)"),
    });
  });

  test("replace changes the ticks and validates them", () => {
    const { store, caseId } = setup({ ...many, max: 2 });
    const r = submit(store, caseId, { choices: ["a"] });
    const next = store.replaceReply(r.id, { idempotency_key: "x", choices: ["b", "c"], comments: [], captures: [] })!;
    expect(next.choices).toEqual(["b", "c"]);
    expect(() =>
      store.replaceReply(r.id, { idempotency_key: "x", choices: ["a", "b", "c"], comments: [], captures: [] }),
    ).toThrow(ChoiceNotOfferedError);
  });

  test("reply.submit params accept choices", () => {
    const r = ReplySubmitParams.safeParse({ case_id: "c", idempotency_key: "k", choices: ["a"], comments: [], captures: [] });
    expect(r.success).toBe(true);
  });
});

describe("waggle_check text", () => {
  const text = (store: Store, id: string): string => {
    const first = store.buildReplyPayload(id)!.content[0]!;
    return first.type === "text" ? first.text : "";
  };

  test("lists the ids, then one line per choice, then the note", () => {
    const { store, caseId } = setup();
    const r = submit(store, caseId, { choices: ["a", "c"], message: "Do the docs first" });
    expect(text(store, r.id).split("\n")).toEqual([
      `Reply to "Which cleanups?" (case ${caseId})`,
      "Choices: a, c",
      "- a: Rename",
      "- c: Docs",
      "Message: Do the docs first",
    ]);
  });

  test("none of these reads Choices: none with the message", () => {
    const { store, caseId } = setup();
    const r = submit(store, caseId, { choices: [], message: "None fit" });
    expect(text(store, r.id)).toContain("Choices: none\nMessage: None fit");
  });
});
