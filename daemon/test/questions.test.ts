import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { ChoiceNotOfferedError, Store } from "../src/store";
import { KnockAskInput, Questions } from "../src/protocol";

// A decision request with questions, points and variants; the reply carries answers.

const questions = [
  {
    id: "plans",
    title: "How many plans on the pricing page?",
    now: ["Three plans, side by side.", "Annual toggle sits above them."],
    points: [
      { id: "count", text: "How many plans?", options: ["Two", "Three", "Four"] },
      { id: "badge", text: "Badge the middle plan?" },
    ],
    variants: [
      { id: "cards", label: "Cards" },
      { id: "table", label: "Table" },
    ],
    variant_label: "Layout",
  },
  { id: "cta", title: "What does the button say?", points: [{ id: "label", text: "Start free?" }] },
];

const base = {
  kind: "question" as const,
  title: "Pricing page decisions",
  need: "Three decisions on the pricing page.",
  why: "They touch the same screen.",
  recommendation: "Three plans, badge the middle one.",
  recommendation_why: "It is the common pattern.",
  questions,
};

function setup(): { store: Store; caseId: string } {
  const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
  const task = store.createTask({ name: "WAG-252", project: "app" });
  return { store, caseId: store.createCase(task.id, KnockAskInput.parse(base)).id };
}

const submit = (store: Store, caseId: string, extra: Record<string, unknown>, key = "k") =>
  store.submitReply(caseId, { idempotency_key: key, comments: [], captures: [], ...extra });

describe("questions schema", () => {
  test("a request with questions parses; one without still does", () => {
    expect(KnockAskInput.safeParse(base).success).toBe(true);
    expect(KnockAskInput.safeParse({ ...base, questions: undefined }).success).toBe(true);
  });

  test("at most 12 questions", () => {
    const many = Array.from({ length: 13 }, (_, i) => ({ id: `q${i}`, title: "T", points: [{ id: "p", text: "P" }] }));
    expect(Questions.safeParse(many.slice(0, 12)).success).toBe(true);
    expect(Questions.safeParse(many).success).toBe(false);
  });

  test("a question needs a point, and ids stay unique", () => {
    expect(Questions.safeParse([{ id: "a", title: "T", points: [] }]).success).toBe(false);
    expect(Questions.safeParse([questions[0], questions[0]]).success).toBe(false);
    const twice = { id: "a", title: "T", points: [{ id: "p", text: "x" }, { id: "p", text: "y" }] };
    expect(Questions.safeParse([twice]).success).toBe(false);
  });

  test("a point's options and a question's variants need two or more", () => {
    const point = { id: "p", text: "x", options: ["only"] };
    expect(Questions.safeParse([{ id: "a", title: "T", points: [point] }]).success).toBe(false);
    const variants = [{ id: "v", label: "V" }];
    expect(Questions.safeParse([{ id: "a", title: "T", points: [{ id: "p", text: "x" }], variants }]).success).toBe(false);
  });

  test("questions do not mix with options or alternatives", () => {
    const withOptions = { ...base, options: [{ id: "a", label: "A" }, { id: "b", label: "B" }], recommendation: "a" };
    expect(KnockAskInput.safeParse(withOptions).success).toBe(false);
  });

  test("the case keeps its questions", () => {
    const { store, caseId } = setup();
    expect(store.getCase(caseId)?.case.questions).toEqual(questions);
  });
});

describe("answers", () => {
  test("a reply keeps its answers, and a point with no options takes Yes / No / Talk with the team", () => {
    const { store, caseId } = setup();
    const answers = [
      { question_id: "plans", point_id: "count", choice: "Three" },
      { question_id: "plans", point_id: "badge", choice: "Talk with the team", note: "ask sales" },
    ];
    const reply = submit(store, caseId, { answers });
    expect(reply.answers).toEqual(answers);
    expect(store.getReply(reply.id)?.answers).toEqual(answers);
  });

  test("an answer for an unknown point, a repeat, or a choice not offered is rejected", () => {
    const { store, caseId } = setup();
    const bad = (answers: object[]) => () => submit(store, caseId, { answers }, `k${Math.random()}`);
    expect(bad([{ question_id: "nope", point_id: "count", choice: "Two" }])).toThrow(ChoiceNotOfferedError);
    expect(bad([{ question_id: "plans", point_id: "count", choice: "Five" }])).toThrow(ChoiceNotOfferedError);
    expect(bad([{ question_id: "plans", point_id: "badge", choice: "Maybe" }])).toThrow(ChoiceNotOfferedError);
    const same = { question_id: "plans", point_id: "badge", choice: "Yes" };
    expect(bad([same, same])).toThrow(ChoiceNotOfferedError);
  });

  test("answers on a case with no questions are rejected", () => {
    const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
    const task = store.createTask({ name: "WAG-252", project: "app" });
    const c = store.createCase(task.id, KnockAskInput.parse({ ...base, questions: undefined }));
    expect(() => submit(store, c.id, { answers: [{ question_id: "plans", point_id: "count", choice: "Two" }] })).toThrow(ChoiceNotOfferedError);
  });

  test("the case shows the answers of its latest reply", () => {
    const { store, caseId } = setup();
    expect(store.getCase(caseId)?.case.latest_reply_answers).toEqual([]);
    const answers = [{ question_id: "cta", point_id: "label", choice: "Yes" }];
    submit(store, caseId, { answers });
    expect(store.getCase(caseId)?.case.latest_reply_answers).toEqual(answers);
  });

  test("replace changes the answers while the reply is queued", () => {
    const { store, caseId } = setup();
    const reply = submit(store, caseId, { answers: [{ question_id: "cta", point_id: "label", choice: "Yes" }] });
    const next = store.replaceReply(reply.id, {
      comments: [],
      captures: [],
      answers: [{ question_id: "cta", point_id: "label", choice: "No" }],
    });
    expect(next?.answers?.[0]?.choice).toBe("No");
  });
});

describe("reply formatting", () => {
  test("one plain line per answered point, then the free note", () => {
    const { store, caseId } = setup();
    const reply = submit(store, caseId, {
      message: "Ship it Friday.",
      answers: [
        { question_id: "plans", point_id: "count", choice: "Three", note: "keep   it\nsmall" },
        { question_id: "cta", point_id: "label", choice: "Yes" },
      ],
    });
    const text = store.buildReplyPayload(reply.id)!.content[0]!;
    expect(text.type === "text" && text.text).toContain(
      "Answers:\nQ1 · point 1: Three · note: keep it small\nQ2 · point 1: Yes\nMessage: Ship it Friday.",
    );
  });

  test("a reply with no answers has no Answers block", () => {
    const { store, caseId } = setup();
    const reply = submit(store, caseId, { message: "Later." });
    const text = store.buildReplyPayload(reply.id)!.content[0]!;
    expect(text.type === "text" && text.text).not.toContain("Answers:");
  });
});

describe("feedback without answers (WAG-285)", () => {
  const textOf = (store: Store, replyId: string) => {
    const first = store.buildReplyPayload(replyId)!.content[0]!;
    return first.type === "text" ? first.text : "";
  };

  test("a note with no answer tells the agent to revise the page and send a new round", () => {
    const { store, caseId } = setup();
    const note = "The prototype should be a dynamic html that one can navigate.";
    const reply = submit(store, caseId, { message: note });
    expect(reply.choice).toBeUndefined();
    expect(reply.answers).toBeUndefined();
    const text = textOf(store, reply.id);
    expect(text).toContain("The human wants changes to the page before deciding.");
    expect(text).toContain("send a new round with waggle_update");
    expect(text).toContain(`Message: ${note}`);
    expect(text).not.toContain("Answers:");
  });

  test("the case stays open for the next round, not decided", () => {
    const { store, caseId } = setup();
    submit(store, caseId, { message: "Change the page first." });
    const found = store.getCase(caseId)!.case;
    expect(found.status).toBe("waiting_on_agent");
    expect(found.done_at ?? null).toBeNull();
    expect(found.latest_reply_choice).toBeNull();
    expect(found.latest_reply_answers).toEqual([]);
    expect(found.latest_reply_message).toBe("Change the page first.");
  });

  test("an answered point with a note is a decision, not feedback", () => {
    const { store, caseId } = setup();
    const reply = submit(store, caseId, {
      message: "Also, shorter copy.",
      answers: [{ question_id: "cta", point_id: "label", choice: "Yes" }],
    });
    const text = textOf(store, reply.id);
    expect(text).not.toContain("wants changes to the page");
    expect(text).toContain("Answers:");
  });

  test("a note on a single-question ask with no option picked is feedback too", () => {
    const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
    const task = store.createTask({ name: "WAG-285", project: "app" });
    const ask = KnockAskInput.parse({
      kind: "question",
      title: "Pick one",
      need: "Pick one.",
      why: "Needed.",
      recommendation: "a",
      recommendation_why: "Fine.",
      options: [
        { id: "a", label: "A" },
        { id: "b", label: "B" },
      ],
    });
    const caseId = store.createCase(task.id, ask).id;
    const reply = submit(store, caseId, { message: "Rework the page." });
    expect(textOf(store, reply.id)).toContain("The human wants changes to the page before deciding.");
    const picked = submit(store, caseId, { choice: "a", message: "Ok." }, "k2");
    expect(textOf(store, picked.id)).not.toContain("wants changes to the page");
  });
});

describe("point options with pros and cons", () => {
  const rich = [
    {
      id: "q",
      title: "Layout?",
      points: [
        { id: "p", text: "Which?", options: [{ label: "Cards", pros: ["Easy to scan"], cons: ["Takes room"] }, "Table"] },
      ],
    },
  ];
  test("an option may be an object or an old string", () => {
    expect(Questions.safeParse(rich).success).toBe(true);
    expect(Questions.safeParse([{ id: "q", title: "T", points: [{ id: "p", text: "P", options: ["A", "B"] }] }]).success).toBe(true);
  });
  test("an object option needs a label, and labels stay unique", () => {
    const bad = (options: unknown[]) => Questions.safeParse([{ id: "q", title: "T", points: [{ id: "p", text: "P", options }] }]).success;
    expect(bad([{ pros: ["x"] }, "B"])).toBe(false);
    expect(bad([{ label: "A", pros: ["x"] }, "A"])).toBe(false);
    expect(bad([{ label: "A", pros: Array(6).fill("x") }, "B"])).toBe(false);
  });
  test("an answer names the label of an object option", () => {
    const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
    const task = store.createTask({ name: "WAG-257", project: "app" });
    const c = store.createCase(task.id, KnockAskInput.parse({ ...base, questions: rich }));
    expect(() => submit(store, c.id, { answers: [{ question_id: "q", point_id: "p", choice: "Nope" }] })).toThrow(ChoiceNotOfferedError);
    const r = submit(store, c.id, { answers: [{ question_id: "q", point_id: "p", choice: "Cards" }] });
    expect(r.answers?.[0]?.choice).toBe("Cards");
  });
});

// WAG-313: a questions request is stored as items, one per point, grouped by question.
describe("questions as items (three blocks)", () => {
  test("the case reads one item per point, grouped by question; the old questions stay as sent", () => {
    const { store, caseId } = setup();
    const c = store.getCase(caseId)!.case;
    expect(c.questions).toEqual(questions as never);
    expect(c.items.map((i) => i.id)).toEqual(["plans/count", "plans/badge", "cta/label"]);
    expect(c.items[0]).toMatchObject({ question: "How many plans?", select: "one", group: { id: "plans", title: questions[0]!.title, variant_label: "Layout" } });
    expect(c.items[0]!.options.map((o) => o.label)).toEqual(["Two", "Three", "Four"]);
    expect(c.items[1]!.options.map((o) => o.label)).toEqual(["Yes", "No", "Talk with the team"]);
    expect(c.options).toEqual([]);
    expect(store.getCase(caseId)!.rounds![0]!.items).toEqual(c.items);
  });

  test("item answers on a questions request give the same reply text as the legacy answers", () => {
    const { store, caseId } = setup();
    const legacy = submit(store, caseId, { answers: [{ question_id: "plans", point_id: "count", choice: "Three", note: "Common." }, { question_id: "cta", point_id: "label", choice: "Yes" }] }, "k1");
    const viaItems = submit(
      store,
      caseId,
      {
        item_answers: [
          { item_id: "plans/count", choice: "o2", note: "Common." },
          { item_id: "plans/badge", choice: "o1" },
          { item_id: "cta/label", choice: "o1" },
        ],
      },
      "k2",
    );
    const text = (id: string) => {
      const block = store.buildReplyPayload(id)!.content[0]!;
      return block.type === "text" ? block.text : "";
    };
    expect(text(legacy.id)).toContain("Answers:\nQ1 · point 1: Three · note: Common.\nQ2 · point 1: Yes");
    expect(viaItems.answers).toEqual([
      { question_id: "plans", point_id: "count", choice: "Three", note: "Common." },
      { question_id: "plans", point_id: "badge", choice: "Yes" },
      { question_id: "cta", point_id: "label", choice: "Yes" },
    ]);
    expect(text(viaItems.id)).toContain("Item 1 (How many plans?): o2 (Three) · note: Common.");
    expect(() => submit(store, caseId, { item_answers: [{ item_id: "plans/count", choice: "o2" }] }, "k3")).toThrow(/no answer for item plans\/badge/);
  });
});
