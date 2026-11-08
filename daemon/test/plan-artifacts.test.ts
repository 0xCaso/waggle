import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { askMessageFor } from "../src/connectors/manager";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { CaseDetail, KnockAskInput, KnockUpdateInput, type Artifact } from "../src/protocol";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

// HAIL-156: every round of a plan ask can carry its own artifact of any kind. The daemon records
// which revision each round shows, and the history reads it back.

const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from("png")]);
const homes: string[] = [];

afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

function write(path: string, data: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
}

function setup(): { store: Store; taskId: string; home: string; cwd: string } {
  const home = tmpHome();
  homes.push(home);
  const cwd = join(home, "work");
  write(join(cwd, "a.png"), PNG);
  write(join(cwd, "b.png"), PNG);
  write(join(cwd, "proto", "index.html"), "<h1>proto</h1>");
  write(join(cwd, "flow.mmd"), "graph TD\n  A-->B\n");
  write(join(cwd, "spec.md"), "# Spec\n\nThe quoted line is here.\n");
  const store = new Store(new Database(":memory:"), home, new EventBus());
  return { store, taskId: store.createTask({ name: "HAIL-156", project: "app" }).id, home, cwd };
}

const opts = [
  { id: "ok", title: "Approve", label: "Approve this" },
  { id: "change", title: "Change", label: "Change this" },
];

function round(message: string, stage: object, artifact?: Artifact) {
  return KnockUpdateInput.parse({
    case_id: "x",
    message,
    stage,
    options: opts,
    recommendation: "ok",
    recommendation_why: "Fits.",
    ...(artifact ? { artifact } : {}),
  });
}

describe("plan rounds with their own artifacts", () => {
  test("a mixed walk records the revision each round shows", () => {
    const { store, taskId, home, cwd } = setup();
    const shots = stageIncoming(home, cwd, {
      type: "screenshots",
      items: [{ path: "a.png", caption: "One" }, { path: "b.png", caption: "Two" }],
    });
    const { id } = store.createCase(
      taskId,
      KnockAskInput.parse({
        kind: "plan",
        stage: { name: "questions", step: 1, total: 3 },
        title: "Plan: mixed",
        need: "Which look?",
        why: "It sets the tone.",
        options: opts,
        recommendation: "ok",
        recommendation_why: "Fits.",
        artifact: shots,
      }),
    );
    const send = (message: string, stage: object, artifact?: Artifact) => {
      store.createReply(id, { idempotency_key: `k-${message}`, choice: "ok", comments: [], captures: [] });
      return store.updateCase(id, {
        ...round(message, stage, artifact ? stageIncoming(home, cwd, artifact) : undefined),
        case_id: id,
      })!;
    };
    send("Which layout?", { name: "approaches" }, { type: "html_bundle", dir: "proto", entry: "index.html" });
    send("Design 1: data flow.", { name: "design", step: 1, total: 2 }, { type: "diagram", path: "flow.mmd" });
    send("Design 2: copy.", { name: "design", step: 2, total: 2 });
    send("The spec.", { name: "spec" }, { type: "markdown", path: "spec.md" });

    const rounds = CaseDetail.parse(store.getCase(id)).plan_rounds!;
    expect(rounds.map((r) => [r.stage.name, r.revision, r.own_artifact, r.artifact_kind])).toEqual([
      ["questions", 1, true, "screenshots"],
      ["approaches", 2, true, "html_bundle"],
      ["design", 3, true, "diagram"],
      ["design", 3, false, "diagram"],
      ["spec", 4, true, "markdown"],
    ]);
    expect(store.getCase(id)!.case.artifact_kind).toBe("markdown");
    // The queue row notes the newest round's own artifact only.
    expect(store.getCase(id)!.case.plan!.artifact_kind).toBe("markdown");
    // Every revision still opens, so the history can show an earlier round read-only.
    expect(rounds.map((r) => store.artifactPath(id, r.revision!)?.kind)).toEqual([
      "screenshots", "html_bundle", "diagram", "diagram", "markdown",
    ]);
  });

  test("a plan without an artifact has null revisions, then the first artifact shows from its round", () => {
    const { store, taskId, home, cwd } = setup();
    const { id } = store.createCase(
      taskId,
      KnockAskInput.parse({
        kind: "plan", stage: { name: "questions" }, title: "Plan", need: "Q1?", why: "Why.",
        options: opts, recommendation: "ok", recommendation_why: "Fits.",
      }),
    );
    store.createReply(id, { idempotency_key: "k1", choice: "ok", comments: [], captures: [] });
    store.updateCase(id, { ...round("Q2?", { name: "questions", step: 2 }), case_id: id });
    store.createReply(id, { idempotency_key: "k2", choice: "ok", comments: [], captures: [] });
    store.updateCase(id, {
      ...round("Layouts?", { name: "approaches" }, stageIncoming(home, cwd, { type: "screenshot", path: "a.png" })),
      case_id: id,
    });
    const rounds = store.getCase(id)!.plan_rounds!;
    expect(rounds.map((r) => [r.revision, r.own_artifact, r.artifact_kind])).toEqual([
      [null, false, null],
      [null, false, null],
      [1, true, "screenshot"],
    ]);
  });

  test("comments on a round's artifact travel with that round's answer", () => {
    const { store, taskId, home, cwd } = setup();
    const { id } = store.createCase(
      taskId,
      KnockAskInput.parse({
        kind: "plan", stage: { name: "spec" }, title: "Plan", need: "Approve?", why: "Why.",
        options: opts, recommendation: "ok", recommendation_why: "Fits.",
        artifact: stageIncoming(home, cwd, { type: "markdown", path: "spec.md" }),
      }),
    );
    store.submitReply(id, {
      idempotency_key: "k1",
      choice: "change",
      comments: [
        { id: "t1", n: 1, text: "Say more.", anchor: { kind: "text", revision: 1, quote: "quoted line", start: 12, end: 23 } },
      ],
      captures: [],
    });
    store.updateCase(id, {
      ...round("Spec again.", { name: "spec" }, stageIncoming(home, cwd, { type: "diagram", path: "flow.mmd" })),
      case_id: id,
    });
    store.submitReply(id, { idempotency_key: "k2", choice: "ok", comments: [], captures: [] });
    const detail = store.getCase(id)!;
    const answered = detail.plan_rounds!.map((r) => r.answer?.choice);
    expect(answered).toEqual(["change", "ok"]);
    const repliesWithComments = detail.replies.filter((r) => r.comments.length > 0);
    expect(repliesWithComments).toHaveLength(1);
    expect(repliesWithComments[0]!.choice).toBe("change");
    expect(repliesWithComments[0]!.comments[0]!.anchor).toMatchObject({ revision: 1, quote: "quoted line" });
  });

  test("the phone notes an artifact only when the round sent one", () => {
    const { store, taskId, home, cwd } = setup();
    const { id } = store.createCase(
      taskId,
      KnockAskInput.parse({
        kind: "plan", stage: { name: "questions" }, title: "Plan", need: "Q1?", why: "Why.",
        options: opts, recommendation: "ok", recommendation_why: "Fits.",
        artifact: stageIncoming(home, cwd, { type: "html_bundle", dir: "proto", entry: "index.html" }),
      }),
    );
    let detail = store.getCase(id)!;
    expect(askMessageFor(detail.case, "Q1?", detail.plan_rounds!.at(-1)).artifact_word).toBe("prototype");
    store.createReply(id, { idempotency_key: "k1", choice: "ok", comments: [], captures: [] });
    store.updateCase(id, { ...round("Q2?", { name: "questions", step: 2 }), case_id: id });
    detail = store.getCase(id)!;
    expect(detail.case.has_artifact).toBe(true);
    expect(askMessageFor(detail.case, "Q2?", detail.plan_rounds!.at(-1)).artifact_word).toBeNull();
    // A normal ask keeps its word.
    expect(askMessageFor(detail.case).artifact_word).toBe("prototype");
  });
});
