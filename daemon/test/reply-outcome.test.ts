import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { askMessageFor, outcomeFor } from "../src/connectors/manager";
import { EventBus } from "../src/events";
import { ChoiceNotOfferedError, Store } from "../src/store";
import { KnockAskInput, KnockUpdateInput, type Artifact } from "../src/protocol";
import { withStagedArtifact } from "../src/mcp/shim";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

// WAG-313 (T2): the reply outcome (decide or talk), item_answers, the plan round fix (spec 2.8), several
// artifacts on one ask, and the new shapes on the connector side.

const homes: string[] = [];
afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

function setup(): { store: Store; taskId: string; home: string; cwd: string } {
  const home = tmpHome();
  homes.push(home);
  const cwd = join(home, "work");
  mkdirSync(join(cwd, "proto"), { recursive: true });
  writeFileSync(join(cwd, "proto", "index.html"), "<h1>proto</h1>");
  writeFileSync(join(cwd, "notes.md"), "# Notes\n");
  writeFileSync(join(cwd, "spec.md"), "# Spec\n");
  const store = new Store(new Database(":memory:"), home, new EventBus());
  return { store, taskId: store.createTask({ name: "WAG-313", project: "app" }).id, home, cwd };
}

const send = (store: Store, caseId: string, extra: Record<string, unknown>, key = `k${Math.random()}`) =>
  store.submitReply(caseId, { idempotency_key: key, comments: [], captures: [], ...extra } as never);

const text = (store: Store, replyId: string): string => {
  const block = store.buildReplyPayload(replyId)!.content[0]!;
  return block.type === "text" ? block.text : "";
};

const AB = [
  { id: "a", title: "Compact", label: "Compact: one screen" },
  { id: "b", title: "Detailed", label: "Detailed: two screens" },
];
const XYZ = [
  { id: "x", label: "Cart" },
  { id: "y", label: "Search" },
  { id: "z", label: "Profile" },
];
const single = { title: "Layout?", need: "Pick one.", why: "Both work.", options: AB, recommendation: "a", recommendation_why: "Fits." };
const multi = {
  title: "Checkout decisions",
  need: "Three decisions on checkout.",
  why: "They touch one screen.",
  items: [
    { id: "layout", question: "Which layout?", options: AB, recommendation: "a", recommendation_why: "Fits." },
    { id: "areas", question: "Which areas?", select: "many", max: 2, options: XYZ, recommendation: ["x", "z"], recommendation_why: "Most used." },
    { id: "free", question: "Any other idea?", select: "reply" },
  ],
};

describe("reply outcome on reads", () => {
  test("decide for a pick; talk for more detail, discuss and a comments-only reply", () => {
    const { store, taskId } = setup();
    const id = store.createCase(taskId, KnockAskInput.parse(single)).id;
    const pick = send(store, id, { choice: "a" });
    const detail = send(store, id, { intent: "more_detail", message: "Why?" });
    const discuss = send(store, id, { intent: "discuss", leaning: ["a"] });
    const feedback = send(store, id, { message: "Change the title first." });
    expect([pick, detail, discuss, feedback].map((r) => r.outcome)).toEqual(["decide", "talk", "talk", "talk"]);
    expect(store.getCase(id)!.replies.map((r) => r.outcome)).toEqual(["decide", "talk", "talk", "talk"]);
  });

  test("a message on an ask with nothing to pick is a decision", () => {
    const { store, taskId } = setup();
    const id = store.createCase(taskId, KnockAskInput.parse({ title: "Name?", need: "Name it.", why: "None.", recommendation: "Hive", recommendation_why: "Short." })).id;
    expect(send(store, id, { message: "Call it Comb." }).outcome).toBe("decide");
  });
});

describe("plan round answer fix (spec 2.8)", () => {
  const plan = {
    ...single,
    kind: "plan",
    stage: { name: "questions", step: 1, total: 3 },
  };
  const next = {
    message: "Which approach?",
    stage: { name: "approaches" },
    options: [{ id: "x", label: "Wizard" }, { id: "y", label: "Checklist" }],
    recommendation: "x",
    recommendation_why: "Shortest.",
  };

  test("a comments-only reply does not mark the round answered; a decision does", () => {
    const { store, taskId } = setup();
    const id = store.createCase(taskId, KnockAskInput.parse(plan)).id;
    send(store, id, { message: "Not sure yet." });
    let detail = store.getCase(id)!;
    expect(detail.case.plan).toMatchObject({ rounds: 1, answered: 0 });
    expect(detail.plan_rounds![0]!.answer).toBeNull();
    expect(detail.rounds![0]).toMatchObject({ answer: null, talk_count: 1 });
    send(store, id, { choice: "a" });
    detail = store.getCase(id)!;
    expect(detail.case.plan).toMatchObject({ answered: 1 });
    expect(detail.plan_rounds![0]!.answer?.choice).toBe("a");
    expect(detail.rounds![0]!.answer).toMatchObject({ choice: "a", item_answers: [{ item_id: "main", choice: "a" }] });
    expect(detail.rounds![0]!.talk_count).toBe(1);
  });

  test("a discuss reply that becomes a decision on replace answers the round only when it picks", () => {
    const { store, taskId } = setup();
    const id = store.createCase(taskId, KnockAskInput.parse(plan)).id;
    const discuss = send(store, id, { intent: "discuss", leaning: ["a"] });
    expect(store.getCase(id)!.case.plan!.answered).toBe(0);
    store.replaceReply(discuss.id, { choice: "b", comments: [], captures: [] });
    expect(store.getCase(id)!.case.plan!.answered).toBe(1);
    expect(store.getCase(id)!.plan_rounds![0]!.answer?.choice).toBe("b");
  });

  test("the fix holds for a case that is not a plan: a round is answered by its own reply", async () => {
    const { store, taskId } = setup();
    const id = store.createCase(taskId, KnockAskInput.parse(single)).id;
    send(store, id, { message: "Looks off." });
    await Bun.sleep(5); // a reply and a round made in one millisecond cannot be told apart by time
    store.updateCase(id, KnockUpdateInput.parse({ case_id: id, ...next, stage: undefined }));
    await Bun.sleep(5);
    send(store, id, { choice: "x" });
    const rounds = store.getCase(id)!.rounds!;
    expect(rounds.map((r) => [r.seq, r.answer?.choice ?? null, r.talk_count])).toEqual([[0, null, 1], [1, "x", 0]]);
  });

  test("a reply with a stage added later still finds its round", async () => {
    const { store, taskId } = setup();
    const id = store.createCase(taskId, KnockAskInput.parse(single)).id;
    send(store, id, { choice: "a" });
    await Bun.sleep(5);
    store.updateCase(id, KnockUpdateInput.parse({ case_id: id, ...next }));
    const detail = store.getCase(id)!;
    expect(detail.rounds!.map((r) => r.answer?.choice ?? null)).toEqual(["a", null]);
    expect(detail.case.plan!.stage.name).toBe("approaches");
  });
});

describe("item_answers", () => {
  test("a single item: the old fields are filled, the note follows the choice line, the text is unchanged", () => {
    const { store, taskId } = setup();
    const id = store.createCase(taskId, KnockAskInput.parse(single)).id;
    const old = send(store, id, { choice: "a" });
    const viaItems = send(store, id, { item_answers: [{ item_id: "main", choice: "a" }] });
    expect(viaItems).toMatchObject({ choice: "a", outcome: "decide", item_answers: [{ item_id: "main", choice: "a" }] });
    expect(text(store, viaItems.id).split("\n").slice(1)).toEqual(text(store, old.id).split("\n").slice(1));
    expect(text(store, viaItems.id)).toContain("Choice: a (Compact: one screen)");
    const noted = send(store, id, { item_answers: [{ item_id: "main", choice: "b", note: "Keep   it small" }] });
    expect(text(store, noted.id)).toContain("Choice: b (Detailed: two screens)\nNote: Keep it small");
  });

  test("a single item with several choices, and a reply item with text", () => {
    const { store, taskId } = setup();
    const many = store.createCase(taskId, KnockAskInput.parse({ title: "Areas?", need: "Pick areas.", why: "Several.", select: "many", max: 2, options: XYZ, recommendation: ["x"], recommendation_why: "Used." })).id;
    const r = send(store, many, { item_answers: [{ item_id: "main", choices: ["x", "z"] }] });
    expect(r.choices).toEqual(["x", "z"]);
    expect(text(store, r.id)).toContain("Choices: x, z");
    const free = store.createCase(taskId, KnockAskInput.parse({ title: "Name?", need: "Name it.", why: "None.", recommendation: "Hive", recommendation_why: "Short." })).id;
    const t = send(store, free, { item_answers: [{ item_id: "main", text: "Call it Comb." }] });
    expect(t).toMatchObject({ message: "Call it Comb.", outcome: "decide" });
  });

  test("several items: the Answers block, the old answers, one stored reply", () => {
    const { store, taskId } = setup();
    const created = store.createCase(taskId, KnockAskInput.parse(multi));
    expect(created.items.map((i) => i.id)).toEqual(["layout", "areas", "free"]);
    // The old columns: a "many" item degrades to a single pick, a "reply" item to Yes, No, Talk with the team.
    expect(created.options).toEqual([]);
    expect(created.questions.map((q) => q.id)).toEqual(["layout", "areas", "free"]);
    const reply = send(store, created.id, {
      item_answers: [
        { item_id: "layout", choice: "a", note: "keep it small" },
        { item_id: "areas", choices: ["x", "z"] },
        { item_id: "free", text: "Ship in two steps" },
      ],
    });
    expect(reply.outcome).toBe("decide");
    expect(reply.item_answers).toHaveLength(3);
    expect(text(store, reply.id)).toContain(
      "Answers:\nItem 1 (Which layout?): a (Compact) · note: keep it small\nItem 2 (Which areas?): x (Cart), z (Profile)\nItem 3 (Any other idea?): Ship in two steps",
    );
    expect(text(store, reply.id)).not.toContain("Q1 ·");
    expect(store.getCase(created.id)!.case.latest_reply_answers).toHaveLength(3);
    expect(store.getCase(created.id)!.rounds![0]!.answer?.item_answers).toHaveLength(3);
  });

  test("a decision that skips an item fails and names the item; a legacy answers reply may stay partial", () => {
    const { store, taskId } = setup();
    const id = store.createCase(taskId, KnockAskInput.parse(multi)).id;
    expect(() => send(store, id, { item_answers: [{ item_id: "layout", choice: "a" }, { item_id: "areas", choices: ["x"] }] })).toThrow(/no answer for item free/);
    expect(() => send(store, id, { item_answers: [{ item_id: "nope", choice: "a" }] })).toThrow(/nope/);
    expect(() => send(store, id, { item_answers: [{ item_id: "layout", choice: "q" }, { item_id: "areas", choices: ["x"] }, { item_id: "free", text: "t" }] })).toThrow(ChoiceNotOfferedError);
    expect(() => send(store, id, { item_answers: [{ item_id: "areas", choices: ["x", "y", "z"] }] })).toThrow(/at most 2/);
    expect(() => send(store, id, { item_answers: [{ item_id: "free", choice: "a" }] })).toThrow(/free/);
    expect(() => send(store, id, { item_answers: [{ item_id: "layout", choice: "a" }, { item_id: "layout", choice: "b" }] })).toThrow(/twice/);
    // Nothing was stored by the failures.
    expect(store.getCase(id)!.replies).toHaveLength(0);
    // Legacy answers on a questions request stay partial.
    const questions = store.createCase(taskId, KnockAskInput.parse({
      title: "Q", need: "N", why: "W", recommendation: "r", recommendation_why: "r",
      questions: [{ id: "q", title: "Q", points: [{ id: "p1", text: "One?" }, { id: "p2", text: "Two?" }] }],
    })).id;
    const partial = send(store, questions, { answers: [{ question_id: "q", point_id: "p1", choice: "Yes" }] });
    expect(partial.outcome).toBe("decide");
  });

  test("a talk reply on several items needs no full answer", () => {
    const { store, taskId } = setup();
    const id = store.createCase(taskId, KnockAskInput.parse(multi)).id;
    expect(send(store, id, { message: "Not sure." }).outcome).toBe("talk");
    expect(send(store, id, { intent: "more_detail" }).outcome).toBe("talk");
    expect(text(store, send(store, id, { message: "Hmm." }).id)).toContain("They chose nothing");
  });

  test("replace changes item answers while the reply is queued", () => {
    const { store, taskId } = setup();
    const id = store.createCase(taskId, KnockAskInput.parse(multi)).id;
    const reply = send(store, id, { item_answers: [{ item_id: "layout", choice: "a" }, { item_id: "areas", choices: ["x"] }, { item_id: "free", text: "One" }] });
    const next = store.replaceReply(reply.id, {
      comments: [],
      captures: [],
      item_answers: [{ item_id: "layout", choice: "b" }, { item_id: "areas", choices: ["y"] }, { item_id: "free", text: "Two" }],
    })!;
    expect(next.item_answers![0]).toMatchObject({ choice: "b" });
    expect(text(store, reply.id)).toContain("Item 1 (Which layout?): b (Detailed)");
  });

  test("a later round with several items takes item answers; the old questions column stays", () => {
    const { store, taskId } = setup();
    const id = store.createCase(taskId, KnockAskInput.parse(single)).id;
    send(store, id, { choice: "a" });
    store.updateCase(id, KnockUpdateInput.parse({ case_id: id, message: "Two more.", items: multi.items }));
    const c = store.getCase(id)!;
    expect(c.case.items.map((i) => i.id)).toEqual(["layout", "areas", "free"]);
    expect(c.case.options).toEqual([]);
    expect(c.rounds!.map((r) => r.items.length)).toEqual([1, 3]);
    const reply = send(store, id, { item_answers: [{ item_id: "layout", choice: "b" }, { item_id: "areas", choices: ["y"] }, { item_id: "free", text: "ok" }] });
    expect(reply.outcome).toBe("decide");
    expect(store.getCase(id)!.rounds![1]!.answer?.item_answers).toHaveLength(3);
    // An old choice from the first round still validates against the first round.
    expect(send(store, id, { choice: "a" }).outcome).toBe("decide");
  });
});

describe("several artifacts on one ask", () => {
  function staged(home: string, cwd: string, a: Artifact, name?: string): Artifact {
    return { ...stageIncoming(home, cwd, a), ...(name ? { name } : {}) } as Artifact;
  }

  test("each artifact is a revision, in order, with its name", () => {
    const { store, taskId, home, cwd } = setup();
    const created = store.createCase(
      taskId,
      KnockAskInput.parse({
        ...single,
        artifacts: [
          staged(home, cwd, { type: "markdown", path: "notes.md" }, "Write-up"),
          staged(home, cwd, { type: "html_bundle", dir: "./proto", entry: "index.html" }, "Prototype"),
        ],
      }),
    );
    expect(created).toMatchObject({ has_artifact: true, revision_count: 2, artifact_kind: "html_bundle" });
    const detail = store.getCase(created.id)!;
    expect(detail.revisions.map((r) => [r.n, r.kind, r.name])).toEqual([[1, "markdown", "Write-up"], [2, "html_bundle", "Prototype"]]);
    expect(detail.rounds![0]).toMatchObject({ revision: 2, own_artifact: true, artifact_kind: "html_bundle" });
    expect(detail.case.items).toHaveLength(1);
  });

  test("one artifact still works as before", () => {
    const { store, taskId, home, cwd } = setup();
    const created = store.createCase(taskId, KnockAskInput.parse({ ...single, artifact: staged(home, cwd, { type: "markdown", path: "notes.md" }) }));
    expect(created).toMatchObject({ has_artifact: true, revision_count: 1, artifact_kind: "markdown" });
    const same = store.createCase(taskId, KnockAskInput.parse({ ...single, artifacts: [staged(home, cwd, { type: "markdown", path: "spec.md" })] }));
    expect(same).toMatchObject({ has_artifact: true, revision_count: 1, artifact_kind: "markdown" });
    expect(store.getCase(same.id)!.revisions).toHaveLength(1);
  });

  test("a rejected artifact leaves no case behind", () => {
    const { store, taskId, home, cwd } = setup();
    const good = staged(home, cwd, { type: "markdown", path: "notes.md" }, "A");
    const bad = { type: "markdown", path: join(home, "incoming", "missing.md"), name: "B" } as Artifact;
    expect(() => store.createCase(taskId, KnockAskInput.parse({ ...single, artifacts: [good, bad] }))).toThrow();
    expect(store.listCases()).toHaveLength(0);
  });

  test("the shim stages every artifact of artifacts[] and keeps each name", () => {
    const { store, taskId, home, cwd } = setup();
    const prev = process.env.KNOCK_HOME;
    process.env.KNOCK_HOME = home;
    try {
      const out = withStagedArtifact({ cwd } as never, {
        ...single,
        artifacts: [
          { type: "markdown", path: "notes.md", name: "Write-up" },
          { type: "markdown", content: "# inline", name: "Inline" },
          { type: "html_bundle", dir: "./proto", entry: "index.html", name: "Prototype" },
        ],
      });
      const list = out.artifacts as Record<string, any>[];
      expect(list.map((a) => [a.type, a.name])).toEqual([["markdown", "Write-up"], ["markdown", "Inline"], ["html_bundle", "Prototype"]]);
      for (const a of list) expect(String(a.path ?? a.dir)).toContain(join(home, "incoming"));
      // The daemon takes the staged list.
      const created = store.createCase(taskId, KnockAskInput.parse(out));
      expect(store.getCase(created.id)!.revisions.map((r) => r.name)).toEqual(["Write-up", "Inline", "Prototype"]);
      // An ask with the single artifact form is staged as before.
      const one = withStagedArtifact({ cwd } as never, { ...single, artifact: { type: "markdown", path: "spec.md", name: "Spec" } });
      expect(one.artifacts).toBeUndefined();
      expect(one.artifact).toMatchObject({ type: "markdown", name: "Spec" });
    } finally {
      if (prev === undefined) delete process.env.KNOCK_HOME;
      else process.env.KNOCK_HOME = prev;
    }
  });
});

describe("connectors do not crash on the new shapes", () => {
  test("askMessageFor and outcomeFor read a multi-item case, a reply item and a review", () => {
    const { store, taskId, home, cwd } = setup();
    const multiCase = store.getCase(store.createCase(taskId, KnockAskInput.parse(multi)).id)!.case;
    const message = askMessageFor(multiCase);
    expect(message).toMatchObject({ options: [], select: "one", recommendation: null });
    const replyItem = store.getCase(store.createCase(taskId, KnockAskInput.parse({ title: "Name?", need: "Name it.", why: "None.", items: [{ id: "a", select: "reply" }] })).id)!.case;
    expect(askMessageFor(replyItem).options).toEqual([]);
    const review = store.getCase(
      store.createCase(
        taskId,
        KnockAskInput.parse({
          title: "Ship?", need: "Review it.", why: "Ready.", kind: "review", recommendation: "approve", recommendation_why: "Good.",
          artifact: stageIncoming(home, cwd, { type: "markdown", path: "notes.md" }),
        }),
      ).id,
    )!.case;
    expect(review.kind).toBe("review");
    expect(askMessageFor(review).title).toBe("Ship?");
    // A decision and a more detail reply read as today.
    const decision = send(store, store.createCase(taskId, KnockAskInput.parse(single)).id, { choice: "a", source: "telegram" });
    const asked = store.getCase(decision.case_id)!.case;
    expect(outcomeFor(asked, decision)).toBe("Answered: Compact");
    const more = send(store, decision.case_id, { intent: "more_detail", source: "telegram" });
    expect(outcomeFor(asked, more)).toBe("Asked for more detail");
    // A phone reply to a multi-item ask is words with no pick: it is talk, and it is stored.
    const phone = send(store, multiCase.id, { message: "Ship it all", source: "telegram" });
    expect(phone.outcome).toBe("talk");
    expect(outcomeFor(multiCase, phone)).toBe("Answered: Ship it all");
  });
});
