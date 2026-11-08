import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { AskTextAnchor, Comment } from "../src/protocol";
import type { Item, KnockAskInput } from "../src/protocol";
import { askCommentLine, Store } from "../src/store";

// WAG-357: comments on the text of a request. The anchor kind, the old kind and the agent wording.

const question: KnockAskInput = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact", title: "Compact view", pros: ["Fast"], cons: ["Dense"] },
    { id: "b", label: "Detailed" },
  ],
};

function seed() {
  const db = new Database(":memory:");
  const store = new Store(db, "/tmp/knock-test", new EventBus());
  const task = store.createTask({ name: "checkout", project: "knock" });
  store.createSession(task.id, { id: "sess-1", cwd: "/work", branch: null, pid: 4242 });
  return { store, caseId: store.createCase(task.id, question).id };
}

const title = { kind: "ask_text", part: "title", quote: "Pick a layout", start: 0, end: 13 } as const;

describe("ask_text anchor", () => {
  test("the schema takes the new kind and the old kind", () => {
    expect(AskTextAnchor.safeParse(title).success).toBe(true);
    const old = { id: "c", n: 1, text: "x", anchor: { kind: "text", revision: 1, quote: "q", start: 0, end: 1 } };
    expect(Comment.safeParse(old).success).toBe(true);
    expect(Comment.safeParse({ id: "c", n: 2, text: "x", anchor: title }).success).toBe(true);
    const parsed = Comment.parse({ id: "c", n: 2, text: "x", anchor: { ...title, part: "pro", option_id: "a" } });
    expect(parsed.anchor).toMatchObject({ kind: "ask_text", part: "pro", option_id: "a" });
  });

  test("the schema rejects a bad part, an empty range and a comment with a region too", () => {
    expect(AskTextAnchor.safeParse({ ...title, part: "label" }).success).toBe(false);
    expect(AskTextAnchor.safeParse({ ...title, start: 5, end: 5 }).success).toBe(false);
    expect(Comment.safeParse({ id: "c", n: 1, text: "x", anchor: title, capture_id: "k", rect: { x: 0, y: 0, w: 1, h: 1 } }).success).toBe(false);
  });

  test("the reply text lists them under Comments on the request, with the other kinds as before", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, {
      idempotency_key: "k",
      choice: "a",
      comments: [
        { id: "t1", n: 1, text: "Too vague.", anchor: { kind: "text", revision: 1, quote: "old words", start: 0, end: 9 } },
        { id: "a1", n: 2, text: "Say it shorter.", anchor: title },
        { id: "a2", n: 3, text: "Really?", anchor: { kind: "ask_text", part: "pro", option_id: "a", quote: "Fast", start: 0, end: 4 } },
        { id: "a3", n: 4, text: "Why?", anchor: { kind: "ask_text", part: "need", quote: "layout", start: 7, end: 13 } },
      ],
      captures: [],
    });
    expect(reply.comments.map((c) => c.anchor?.kind)).toEqual(["text", "ask_text", "ask_text", "ask_text"]);
    const payload = store.buildReplyPayload(reply.id)!;
    const text = payload.content[0].type === "text" ? payload.content[0].text : "";
    expect(text).toContain('Comments on the explanation (v1):\n[1] "old words" - Too vague.');
    expect(text).toContain(
      'Comments on the request:\n[2] On the title, "Pick a layout": Say it shorter.\n' +
        '[3] On a pro of "Compact view", "Fast": Really?\n[4] On what I need, "layout": Why?',
    );
  });

  test("the part reads in plain words and a question names its item", () => {
    const items: Item[] = [{ id: "q1", question: "Which card?", select: "one", options: [{ id: "x", label: "X" }] }];
    const anchor = (part: AskTextAnchor["part"], extra = {}): AskTextAnchor => ({ kind: "ask_text", part, quote: "w", start: 0, end: 1, ...extra });
    expect(askCommentLine(anchor("question", { item_id: "q1" }), [], items)).toBe('On the question of "Which card?", "w"');
    expect(askCommentLine(anchor("con", { item_id: "q1", option_id: "x" }), [], items)).toBe('On a con of "X", "w"');
    expect(askCommentLine(anchor("why"), [])).toBe('On the why, "w"');
    expect(askCommentLine(anchor("recommendation"), [])).toBe('On the recommendation, "w"');
    expect(askCommentLine(anchor("source", { source_id: "s1" }), [])).toBe('On a source, "w"');
  });
});
