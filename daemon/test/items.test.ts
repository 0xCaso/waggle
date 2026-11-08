import { describe, expect, test } from "bun:test";
import golden from "./fixtures/items-golden.json" with { type: "json" };
import {
  Case,
  Item,
  ItemAnswer,
  KnockAskInput,
  KnockUpdateInput,
  MCP_TOOLS,
  ReplyIntent,
  ReplyOutcome,
  ReplySubmitParams,
  itemsOfRound,
  normalizeAsk,
  normalizeReply,
  normalizeUpdate,
  projectLegacy,
  projectLegacyReply,
  replyOutcome,
} from "../src/protocol";

// WAG-312 (T1): the item model and the normaliser. The golden file holds the expected values by hand,
// one case per row of the mapping table (spec 2.3).

type Json = Record<string, any>;
const asks = golden.asks as Json[];
const askByName = (name: string): Json => asks.find((a) => a.name === name)!;
const parseAsk = (input: Json) => KnockAskInput.parse(input);

const base = { title: "T", need: "N", why: "W" };
const optionsAsk = {
  ...base,
  options: [{ id: "a", label: "A" }, { id: "b", label: "B" }],
  recommendation: "a",
  recommendation_why: "R",
};

function issuesOf(input: unknown, schema: { safeParse: (v: unknown) => any } = KnockAskInput): string {
  const r = schema.safeParse(input);
  expect(r.success).toBe(false);
  return JSON.stringify(r.error.issues);
}

describe("golden: every old waggle_ask input normalises to the expected items", () => {
  for (const c of asks) {
    test(`${c.name} (${c.row})`, () => {
      const n = normalizeAsk(parseAsk(c.input));
      expect(n.items).toEqual(c.expect.items);
      expect(n.kind).toBe(c.expect.kind);
      expect(n.artifacts).toHaveLength(c.expect.artifacts);
      expect(n.stage).toEqual(c.expect.stage);
      expect(n.title).toBe(c.input.title);
      expect(n.need).toBe(c.input.need);
      expect(n.why).toBe(c.input.why);
      // Every normalised item parses with the stored Item schema.
      for (const item of n.items) expect(Item.safeParse(item).success).toBe(true);
    });

    test(`${c.name}: projectLegacy gives the old fields back`, () => {
      const expected = { ...c.expect.legacy };
      if (expected.questions === "$input.questions") expected.questions = c.input.questions;
      expect(projectLegacy(normalizeAsk(parseAsk(c.input)))).toEqual(expected);
    });
  }

  test("for an input with no item, the old fields round trip to the values the agent sent", () => {
    for (const name of ["question-options", "options-many", "options-many-single-id", "review-own-options", "plan-stage", "reply-only"]) {
      const input = askByName(name).input;
      const legacy = projectLegacy(normalizeAsk(parseAsk(input)));
      expect(legacy.options).toEqual(input.options ?? []);
      expect(legacy.select).toBe(input.select ?? "one");
      expect(legacy.max).toBe(input.max ?? null);
      expect(legacy.recommendation).toBe(Array.isArray(input.recommendation) ? input.recommendation[0] : input.recommendation);
      expect(legacy.recommendation_why).toBe(input.recommendation_why);
      expect(legacy.questions).toEqual([]);
    }
  });

  test("the artifact shortcut is a list of one; several artifacts keep their order", () => {
    expect(normalizeAsk(parseAsk(askByName("review-approve").input)).artifacts).toEqual([{ type: "markdown", content: "# Pricing" }]);
    const several = normalizeAsk(parseAsk(askByName("several-artifacts").input));
    expect(several.artifacts.map((a) => a.name)).toEqual(["Write-up", "Prototype"]);
  });

  test("follows, replaces, topic and session_title pass through", () => {
    const n = normalizeAsk(parseAsk({ ...optionsAsk, follows: "c1", replaces: "c2", topic: "Job", session_title: "Pricing" }));
    expect([n.follows, n.replaces, n.topic, n.session_title]).toEqual(["c1", "c2", "Job", "Pricing"]);
  });
});

describe("golden: a shortcut equals its canonical twin", () => {
  golden.twins.forEach((t, i) => {
    test(`${t.shortcut} twin ${i}`, () => {
      const a = normalizeAsk(parseAsk(askByName(t.shortcut).input));
      const b = normalizeAsk(parseAsk(t.canonical));
      expect(b.items).toEqual(a.items);
      expect(b.kind).toBe(a.kind);
      expect(b.stage).toEqual(a.stage);
      expect(b.artifacts).toEqual(a.artifacts);
    });
  });
});

describe("golden: waggle_update", () => {
  for (const c of golden.updates as Json[]) {
    test(`${c.name} (${c.row})`, () => {
      expect(normalizeUpdate(KnockUpdateInput.parse(c.input))).toEqual(c.expect);
    });
  }
});

describe("golden: reply", () => {
  for (const c of golden.replies as Json[]) {
    test(`${c.name} (${c.row})`, () => {
      const ask = askByName(c.ask);
      const n = normalizeAsk(parseAsk(ask.input));
      const reply = c.reply;
      expect(replyOutcome({ items: n.items }, reply)).toBe(c.expect.outcome);
      // The same answer from the legacy columns alone (what an old row has).
      const legacy = projectLegacy(n);
      if (n.items.length === 1 || legacy.questions.length > 0) {
        expect(replyOutcome({ options: legacy.options, questions: legacy.questions }, reply)).toBe(c.expect.outcome);
      }
      const answers = normalizeReply(n.items, reply);
      expect(answers).toEqual(c.expect.item_answers);
      for (const a of answers) expect(ItemAnswer.safeParse(a).success).toBe(true);
      if (c.expect.back !== undefined) expect(projectLegacyReply(n.items, answers)).toEqual(c.expect.back);
    });
  }

  test("replyOutcome: talk for more_detail, discuss and a feedback reply; decide otherwise", () => {
    const withOptions = { options: [{ id: "a" }] };
    expect(replyOutcome(withOptions, { intent: "more_detail" })).toBe("talk");
    expect(replyOutcome(withOptions, { intent: "discuss" })).toBe("talk");
    expect(replyOutcome(withOptions, { intent: "decision", message: "change it" })).toBe("talk");
    expect(replyOutcome(withOptions, { intent: "decision", choice: "a" })).toBe("decide");
    expect(replyOutcome(withOptions, { intent: "decision" })).toBe("decide");
    expect(replyOutcome({ options: [], questions: [] }, { intent: "decision", message: "free text" })).toBe("decide");
    expect(replyOutcome(withOptions, { intent: "decision", message: "x", item_answers: [{}] })).toBe("decide");
  });
});

describe("itemsOfRound: a stored round gives the items of its ask", () => {
  function rowOf(c: Json) {
    const legacy = projectLegacy(normalizeAsk(parseAsk(c.input)));
    return {
      row: {
        seq: 0,
        options_json: JSON.stringify(legacy.options),
        recommendation: legacy.recommendation,
        recommendation_why: legacy.recommendation_why,
        select_mode: legacy.select,
        max_choices: legacy.max,
        recommendations_json: JSON.stringify(legacy.recommendations),
      },
      caseRow: { questions_json: JSON.stringify(legacy.questions) },
    };
  }
  const lossless = [
    "question-options",
    "options-many",
    "options-many-single-id",
    "review-own-options",
    "plan-stage",
    "reply-only",
    "questions-to-groups",
    "review-approve",
    "review-free-text-recommendation",
  ];
  for (const name of lossless) {
    test(`${name}: legacy columns give the items back`, () => {
      const c = askByName(name);
      const { row, caseRow } = rowOf(c);
      const expected = normalizeAsk(parseAsk(c.input)).items.map((i) => (i.id === "decision" ? { ...i, id: "main" } : i));
      expect(itemsOfRound(row, caseRow)).toEqual(expected);
    });
  }

  test("items_json wins over every legacy column", () => {
    const items = [{ id: "z", select: "reply", options: [] }];
    expect(itemsOfRound({ seq: 2, items_json: JSON.stringify(items), options_json: '[{"id":"a","label":"A"}]', recommendation: "a" }, {})).toEqual(items);
  });

  test("questions apply to round 0 only; a later round reads its options", () => {
    const questions = JSON.stringify([{ id: "q", title: "Q", points: [{ id: "p", text: "P?" }] }]);
    const row = { seq: 1, options_json: '[{"id":"a","label":"A"},{"id":"b","label":"B"}]', recommendation: "b", recommendation_why: "Why" };
    expect(itemsOfRound(row, { questions_json: questions })).toEqual([
      { id: "main", select: "one", options: [{ id: "a", label: "A" }, { id: "b", label: "B" }], recommendation: "b", recommendation_why: "Why" },
    ]);
    expect(itemsOfRound({ ...row, seq: 0 }, { questions_json: questions })[0]!.id).toBe("q/p");
  });

  test("no options and no questions give one reply item; no limit applies to stored items", () => {
    expect(itemsOfRound({ seq: 0, options_json: "[]", recommendation: "Try it", recommendation_why: "" }, { questions_json: "[]" })).toEqual([
      { id: "main", select: "reply", options: [], recommendation: "Try it" },
    ]);
    const questions = Array.from({ length: 12 }, (_, q) => ({
      id: `q${q}`,
      title: "Q",
      points: Array.from({ length: 12 }, (_, p) => ({ id: `p${p}`, text: "P?" })),
    }));
    expect(itemsOfRound({ seq: 0, options_json: "[]", recommendation: "", recommendation_why: "" }, { questions_json: JSON.stringify(questions) })).toHaveLength(144);
  });
});

describe("KnockAskInput rules", () => {
  test("kind plan without a stage fails; kind review without an artifact fails", () => {
    expect(issuesOf({ ...optionsAsk, kind: "plan" })).toContain("a plan ask requires a stage");
    expect(issuesOf({ ...optionsAsk, kind: "review" })).toContain("a review requires an artifact");
    expect(KnockAskInput.safeParse({ ...optionsAsk, kind: "review", artifacts: [{ type: "markdown", content: "x" }] }).success).toBe(true);
  });

  test("kind is optional", () => {
    expect(KnockAskInput.safeParse(optionsAsk).success).toBe(true);
  });

  test("items with options, questions, select or max fails with one message", () => {
    const item = { id: "i", options: [{ id: "a", label: "A" }, { id: "b", label: "B" }] };
    const msg = "give items, or options, or questions, not two of them";
    expect(issuesOf({ ...base, items: [item], options: optionsAsk.options })).toContain(msg);
    expect(issuesOf({ ...base, items: [item], questions: [{ id: "q", title: "Q", points: [{ id: "p", text: "P" }] }] })).toContain(msg);
    expect(issuesOf({ ...base, items: [item], select: "many" })).toContain(msg);
    expect(issuesOf({ ...base, items: [item], max: 1 })).toContain(msg);
    expect(issuesOf({ ...optionsAsk, questions: [{ id: "q", title: "Q", points: [{ id: "p", text: "P" }] }] })).toContain(msg);
  });

  test("12 items pass, 13 fail, a duplicate item id fails", () => {
    const mk = (n: number) => Array.from({ length: n }, (_, i) => ({ id: `i${i}`, question: "Q?", select: "reply" }));
    expect(KnockAskInput.safeParse({ ...base, items: mk(12) }).success).toBe(true);
    expect(KnockAskInput.safeParse({ ...base, items: mk(13) }).success).toBe(false);
    expect(issuesOf({ ...base, items: [{ id: "x", question: "Q?" }, { id: "x", question: "R?" }] })).toContain("item id x is used twice");
  });

  test("item rules: question needed with more than one item, options 2 to 12, ids unique, recommendation an option id", () => {
    expect(issuesOf({ ...base, items: [{ id: "a" }, { id: "b", question: "Q?" }] })).toContain("each item needs a question");
    expect(KnockAskInput.safeParse({ ...base, items: [{ id: "a" }] }).success).toBe(true);
    const opts = (n: number) => Array.from({ length: n }, (_, i) => ({ id: `o${i}`, label: `L${i}` }));
    expect(KnockAskInput.safeParse({ ...base, items: [{ id: "a", options: opts(12) }] }).success).toBe(true);
    expect(KnockAskInput.safeParse({ ...base, items: [{ id: "a", options: opts(13) }] }).success).toBe(false);
    expect(KnockAskInput.safeParse({ ...base, items: [{ id: "a", options: opts(1) }] }).success).toBe(false);
    expect(issuesOf({ ...base, items: [{ id: "a", options: [{ id: "o", label: "A" }, { id: "o", label: "B" }] }] })).toContain("uses an option id twice");
    expect(issuesOf({ ...base, items: [{ id: "a", options: opts(2), recommendation: "zz" }] })).toContain("recommendation must equal one option id");
    expect(issuesOf({ ...base, items: [{ id: "a", select: "reply", options: opts(2) }] })).toContain("a reply item has no options");
    expect(issuesOf({ ...base, items: [{ id: "a", options: opts(2), max: 1 }] })).toContain('max only works with select \\"many\\"');
    expect(issuesOf({ ...base, items: [{ id: "a", select: "many", options: opts(2), max: 3 }] })).toContain("max is 3 but there are only 2 options");
    expect(issuesOf({ ...base, items: [{ id: "a", options: opts(2), recommendation_why: "x".repeat(301) }] })).toContain("recommendation_why is 301 characters");
    expect(issuesOf({ ...base, items: [{ id: "a".repeat(41) }] })).toContain("id");
  });

  test("recommendation is required without items and optional with items", () => {
    const { recommendation: _r, recommendation_why: _w, ...noRec } = optionsAsk;
    expect(issuesOf(noRec)).toContain("recommendation is required");
    expect(issuesOf({ ...noRec, recommendation: "a" })).toContain("recommendation_why is required");
    expect(KnockAskInput.safeParse({ ...base, items: [{ id: "a" }] }).success).toBe(true);
  });

  test("a top-level recommendation goes to the one item that has none; never to many", () => {
    const opts = [{ id: "a", label: "A" }, { id: "b", label: "B" }];
    const n = normalizeAsk(parseAsk({ ...base, recommendation: "b", recommendation_why: "R", items: [{ id: "i", options: opts }] }));
    expect(n.items[0]!.recommendation).toBe("b");
    expect(n.items[0]!.recommendation_why).toBe("R");
    expect(issuesOf({ ...base, recommendation: "b", items: [{ id: "i", options: opts, recommendation: "a" }] })).toContain("not both");
    expect(issuesOf({ ...base, recommendation: "zz", items: [{ id: "i", options: opts }] })).toContain("recommendation must equal one option id");
    expect(issuesOf({ ...base, recommendation: "b", items: [{ id: "i", question: "Q?", options: opts }, { id: "j", question: "R?" }] })).toContain("inside each item");
  });

  test("a stage is allowed on any ask", () => {
    expect(KnockAskInput.safeParse({ ...optionsAsk, kind: "question", stage: { name: "spec" } }).success).toBe(true);
    expect(KnockAskInput.safeParse({ ...optionsAsk, stage: { name: "spec" } }).success).toBe(true);
  });

  test("the old why and recommendation_why limits stay", () => {
    expect(issuesOf({ ...optionsAsk, why: "x".repeat(501) })).toContain("why is 501 characters");
    expect(issuesOf({ ...optionsAsk, recommendation_why: "x".repeat(301) })).toContain("recommendation_why is 301 characters");
  });

  test("artifact and artifacts exclude each other; artifacts need their own names", () => {
    const md = { type: "markdown", content: "x" };
    expect(issuesOf({ ...optionsAsk, artifact: md, artifacts: [md] })).toContain("artifact or artifacts, not both");
    expect(issuesOf({ ...optionsAsk, artifacts: [md, md] })).toContain("give each artifact its own name");
    expect(issuesOf({ ...optionsAsk, artifacts: [{ ...md, name: "A" }, { ...md, name: "A" }] })).toContain("give each artifact its own name");
    expect(KnockAskInput.safeParse({ ...optionsAsk, artifacts: [md, { type: "diagram", path: "a.mmd" }] }).success).toBe(true);
    expect(KnockAskInput.safeParse({ ...optionsAsk, artifacts: [{ ...md, name: "A" }, { ...md, name: "B" }] }).success).toBe(true);
    expect(KnockAskInput.safeParse({ ...optionsAsk, artifacts: [] }).success).toBe(false);
    const nine = Array.from({ length: 9 }, (_, i) => ({ ...md, name: `n${i}` }));
    expect(KnockAskInput.safeParse({ ...optionsAsk, artifacts: nine }).success).toBe(false);
  });
});

describe("KnockUpdateInput rules", () => {
  const msg = { case_id: "c1", message: "m" };
  const opts = [{ id: "a", label: "A" }, { id: "b", label: "B" }];

  test("a stage alone is allowed; options still need a recommendation", () => {
    expect(KnockUpdateInput.safeParse({ ...msg, stage: { name: "design" } }).success).toBe(true);
    expect(issuesOf({ ...msg, options: opts }, KnockUpdateInput)).toContain("recommendation must equal one option id");
  });

  test("items replace options; done cannot carry items", () => {
    expect(KnockUpdateInput.safeParse({ ...msg, items: [{ id: "a", options: opts }] }).success).toBe(true);
    expect(issuesOf({ ...msg, items: [{ id: "a", options: opts }], options: opts, recommendation: "a" }, KnockUpdateInput)).toContain("not both");
    expect(issuesOf({ ...msg, items: [{ id: "a", options: opts }], recommendation: "a" }, KnockUpdateInput)).toContain("not both");
    expect(issuesOf({ ...msg, done: true, items: [{ id: "a", options: opts }] }, KnockUpdateInput)).toContain("done");
    expect(issuesOf({ ...msg, items: [{ id: "a" }, { id: "b", question: "Q?" }] }, KnockUpdateInput)).toContain("each item needs a question");
  });

  test("recommendation, select and max still need options", () => {
    expect(issuesOf({ ...msg, recommendation: "a" }, KnockUpdateInput)).toContain("need options");
  });
});

describe("the wire does not grow (spec decision 4, risk R1)", () => {
  test("the enums the app decodes as closed Swift enums keep their values", () => {
    expect(ReplyIntent.options).toEqual(["decision", "more_detail", "discuss"]);
    const shape = Case.shape;
    expect(shape.kind.options).toEqual(["question", "review"]);
    expect(shape.select.options).toEqual(["one", "many"]);
    expect(ReplyOutcome.options).toEqual(["decide", "talk"]);
  });

  test("an item answer is rejected without exactly one of choice, choices or text", () => {
    expect(ItemAnswer.safeParse({ item_id: "a" }).success).toBe(false);
    expect(ItemAnswer.safeParse({ item_id: "a", choice: "x", text: "y" }).success).toBe(false);
    expect(ItemAnswer.safeParse({ item_id: "a", choices: [] }).success).toBe(true);
  });

  test("reply.submit takes item_answers and still takes the old fields", () => {
    const common = { case_id: "c", idempotency_key: "k", comments: [], captures: [] };
    const r = ReplySubmitParams.parse({ ...common, item_answers: [{ item_id: "a", choice: "x" }] });
    expect(r.item_answers).toHaveLength(1);
    expect(r.intent).toBe("decision");
    expect(ReplySubmitParams.safeParse({ ...common, choice: "x" }).success).toBe(true);
  });
});

describe("the tool manifest", () => {
  test("waggle_ask lists items and artifacts; waggle_update lists items", () => {
    const props = (name: string) => (MCP_TOOLS.find((t) => t.name === name)!.inputSchema as Json).properties as Json;
    expect(Object.keys(props("waggle_ask"))).toEqual(expect.arrayContaining(["items", "artifacts", "artifact", "kind"]));
    expect(Object.keys(props("waggle_update"))).toContain("items");
  });

  test("kind and the recommendation fields are no longer required in the advertised schema", () => {
    const schema = MCP_TOOLS.find((t) => t.name === "waggle_ask")!.inputSchema as Json;
    expect(schema.required).toEqual(expect.arrayContaining(["title", "need", "why"]));
    for (const field of ["kind", "recommendation", "recommendation_why", "items"]) expect(schema.required).not.toContain(field);
  });
});
