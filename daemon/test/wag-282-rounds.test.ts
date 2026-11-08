import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { KnockAskInput, KnockUpdateInput, type Artifact } from "../src/protocol";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

// WAG-282: what the decision page reads after each kind of waggle_update. The daemon keeps the ask's
// own title, need and why (the first round). Round 2 and later ride on the option set (round_question,
// options, options_seq, plan_rounds), the messages and the revisions. The app shows the newest of these.

// `WAG282_FIXTURES=<dir> bun test test/wag-282-rounds.test.ts` writes each scenario's cases.get result
// there. The app's WAG282RoundTests decode those files: the daemon's own output, not a hand-made copy.
const fixtureDir = process.env.WAG282_FIXTURES;
function emit(name: string, detail: unknown): void {
  if (!fixtureDir) return;
  mkdirSync(fixtureDir, { recursive: true });
  writeFileSync(join(fixtureDir, `${name}.json`), JSON.stringify(detail, null, 1) + "\n");
}

const homes: string[] = [];
afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

function setup() {
  const home = tmpHome();
  homes.push(home);
  const cwd = join(home, "work");
  for (const name of ["one.md", "two.md", "three.md"]) {
    mkdirSync(dirname(join(cwd, name)), { recursive: true });
    writeFileSync(join(cwd, name), `# ${name}\n`);
  }
  const store = new Store(new Database(":memory:"), home, new EventBus());
  const taskId = store.createTask({ name: "WAG-282", project: "app" }).id;
  const stage = (path: string, name?: string): Artifact => ({
    ...stageIncoming(home, cwd, { type: "markdown", path }),
    ...(name ? { name } : {}),
  });
  return { store, taskId, stage };
}

const opts = [
  { id: "a", title: "Flow", label: "Build the flow" },
  { id: "b", title: "Intake", label: "Build the intake" },
];
const roundTwo = "Where does the intake go in the demo?\n\nIt sits after the sign-in screen.\n\nPick one.";

function ask(store: Store, taskId: string, extra: object = {}) {
  return store.createCase(
    taskId,
    KnockAskInput.parse({
      kind: "question",
      title: "Investor demo: is this the flow to build?",
      need: "Review the drawn flow of 25 screens.",
      why: "It sets the demo scope.",
      options: opts,
      recommendation: "a",
      recommendation_why: "Fits.",
      ...extra,
    }),
  ).id;
}

// An update counts as "after the reply" by timestamp, so let the clock tick between the two.
const answer = (store: Store, id: string, key: string) => {
  store.createReply(id, { idempotency_key: key, choice: "a", comments: [], captures: [] });
  Bun.sleepSync(5);
};

describe("what each update kind leaves for the decision page", () => {
  test("a question update with options: the round question and options are the new ones", () => {
    const { store, taskId } = setup();
    const id = ask(store, taskId);
    answer(store, id, "k1");
    store.updateCase(id, KnockUpdateInput.parse({
      case_id: id, message: roundTwo, options: [{ id: "c", title: "After sign-in", label: "Put it after sign-in" }],
      recommendation: "c", recommendation_why: "Shortest path.",
    }));
    const detail = store.getCase(id)!;
    emit("question-options", detail);
    expect(detail.case.title).toBe("Investor demo: is this the flow to build?");
    expect(detail.case.need).toBe("Review the drawn flow of 25 screens.");
    expect(detail.case.options_seq).toBe(1);
    expect(detail.case.round_question).toBe(roundTwo);
    expect(detail.case.options.map((o) => o.id)).toEqual(["c"]);
    expect(detail.case.first_options.map((o) => o.id)).toEqual(["a", "b"]);
    expect(detail.case.recommendation).toBe("c");
    expect(detail.case.status).toBe("needs_you");
    expect(detail.messages.at(-1)?.text).toBe(roundTwo);
  });

  test("an update with only a message opens no round and leaves the open question", () => {
    const { store, taskId } = setup();
    const id = ask(store, taskId);
    answer(store, id, "k1");
    store.updateCase(id, KnockUpdateInput.parse({ case_id: id, message: "I fixed the copy.\n\nSee the note." }));
    const detail = store.getCase(id)!;
    emit("message-only", detail);
    expect(detail.case.options_seq).toBe(0);
    expect(detail.case.round_question).toBeNull();
    expect(detail.case.options.map((o) => o.id)).toEqual(["a", "b"]);
    expect(detail.messages.at(-1)?.text).toBe("I fixed the copy.\n\nSee the note.");
    expect(detail.case.latest_update_message).toBe("I fixed the copy.\n\nSee the note.");
  });

  test("an update with a new artifact adds a revision of the same name and a revision of a new name", () => {
    const { store, taskId, stage } = setup();
    const id = ask(store, taskId, { artifact: stage("one.md", "Flow") });
    answer(store, id, "k1");
    store.updateCase(id, KnockUpdateInput.parse({ case_id: id, message: "Flow v2.", artifact: stage("two.md", "Flow") }));
    store.updateCase(id, KnockUpdateInput.parse({ case_id: id, message: "Plus a spec.", artifact: stage("three.md", "Spec") }));
    const detail = store.getCase(id)!;
    emit("artifacts", detail);
    expect(detail.revisions.map((r) => [r.n, r.name])).toEqual([[1, "Flow"], [2, "Flow"], [3, "Spec"]]);
    expect(detail.case.revision_count).toBe(3);
    expect(detail.case.artifact_kind).toBe("markdown");
  });

  test("an options round with its own artifact records the revision the round shows", () => {
    const { store, taskId, stage } = setup();
    const id = ask(store, taskId, { artifact: stage("one.md") });
    answer(store, id, "k1");
    store.updateCase(id, KnockUpdateInput.parse({
      case_id: id, message: roundTwo, artifact: stage("two.md"), options: opts, recommendation: "a",
    }));
    const detail = store.getCase(id)!;
    emit("round-artifact", detail);
    expect(detail.case.round_question).toBe(roundTwo);
    expect(detail.revisions.map((r) => r.n)).toEqual([1, 2]);
  });

  test("plan rounds: the newest round's text, options and revision lead", () => {
    const { store, taskId, stage } = setup();
    const id = ask(store, taskId, {
      kind: "plan", stage: { name: "questions", step: 1, total: 3 }, artifact: stage("one.md"),
    });
    answer(store, id, "k1");
    store.updateCase(id, KnockUpdateInput.parse({
      case_id: id, message: roundTwo, stage: { name: "approaches" }, artifact: stage("two.md"),
      options: [{ id: "x", title: "Approach X", label: "Approach X in full" }], recommendation: "x",
    }));
    const detail = store.getCase(id)!;
    emit("plan-rounds", detail);
    expect(detail.case.need).toBe("Review the drawn flow of 25 screens.");
    expect(detail.plan_rounds?.map((r) => r.question)).toEqual(["Review the drawn flow of 25 screens.", roundTwo]);
    const last = detail.plan_rounds!.at(-1)!;
    expect(last.revision).toBe(2);
    expect(last.own_artifact).toBe(true);
    expect(detail.case.plan?.rounds).toBe(2);
    expect(detail.case.plan?.stage.name).toBe("approaches");
  });

  test("a done note closes the case and opens no round", () => {
    const { store, taskId } = setup();
    const id = ask(store, taskId);
    answer(store, id, "k1");
    store.updateCase(id, KnockUpdateInput.parse({ case_id: id, message: "All shipped.", done: true }));
    const detail = store.getCase(id)!;
    emit("done", detail);
    expect(detail.case.done_at).not.toBeNull();
    expect(detail.case.status).toBe("waiting_on_agent");
    expect(detail.case.options_seq).toBe(0);
    expect(detail.case.round_question).toBeNull();
    expect(detail.case.latest_update_message).toBe("All shipped.");
  });
});

// WAG-351: each revision names the round it belongs to, derived from the option sets' times.
describe("revision round", () => {
  test("a revision carries the round that was newest when it was made", () => {
    const { store, taskId, stage } = setup();
    const id = ask(store, taskId, { artifact: stage("one.md", "Flow") });
    answer(store, id, "k1");
    store.updateCase(id, KnockUpdateInput.parse({
      case_id: id, message: roundTwo, artifact: stage("two.md", "Spec"), options: opts, recommendation: "a",
    }));
    Bun.sleepSync(5);
    // An artifact-only update stays with the round on screen.
    store.updateCase(id, KnockUpdateInput.parse({ case_id: id, message: "Flow v2.", artifact: stage("three.md", "Flow") }));
    const detail = store.getCase(id)!;
    expect(detail.revisions.map((r) => [r.n, r.round])).toEqual([[1, 0], [2, 1], [3, 1]]);
  });
});
