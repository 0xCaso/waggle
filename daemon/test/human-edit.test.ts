import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { Database } from "bun:sqlite";
import { ArtifactError } from "../src/artifacts";
import { EventBus } from "../src/events";
import { diffMarkdown } from "../src/markdown-diff";
import { Store } from "../src/store";
import type { Event, KnockAskInput } from "../src/protocol";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

// HAIL-168: the person edits a markdown revision in place; Done stores the next revision by "you",
// and the reply carries the edit (new text, a unified diff, the count of changed passages).

const homes: string[] = [];
afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

const question: KnockAskInput = {
  kind: "question",
  title: "Explain the cache",
  need: "Read this",
  why: "Needs a decision",
  recommendation: "a",
  recommendation_why: "Simple",
  options: [{ id: "a", label: "Ship it" }],
};

const ORIGINAL = "# Cache\n\nWe cache for **ten** minutes.\n\n- one\n- two\n\nDone.\n";
const EDITED = "# Cache\n\nWe cache for **five** minutes.\n\n- one\n- two\n- three\n\nDone.\n";

function setup(events?: Event[]) {
  const home = tmpHome();
  homes.push(home);
  const cwd = join(home, "work");
  mkdirSync(dirname(join(cwd, "a.md")), { recursive: true });
  writeFileSync(join(cwd, "a.md"), ORIGINAL);
  const bus = new EventBus();
  if (events) bus.subscribe((e) => events.push(e));
  const store = new Store(new Database(join(home, "knock.db")), home, bus);
  const task = store.createTask({ name: "cache", project: "knock" });
  store.createSession(task.id, { id: "sess-1", cwd, branch: null, pid: 4242 });
  const caseId = store.createCase(task.id, question).id;
  store.createRevision(caseId, stageIncoming(home, cwd, { type: "markdown", path: "./a.md" }));
  return { store, home, caseId };
}

describe("revision by the person", () => {
  test("is stored as the next revision, author you, with its base and size", () => {
    const events: Event[] = [];
    const { store, home, caseId } = setup(events);
    const revision = store.addHumanRevision(caseId, 1, EDITED);
    expect(revision).toMatchObject({ n: 2, author: "you", base_revision: 1, passages_changed: 2 });
    const detail = store.getCase(caseId)!;
    expect(detail.revisions.map((r) => [r.n, r.author])).toEqual([
      [1, "agent"],
      [2, "you"],
    ]);
    const path = store.artifactPath(caseId, 2)!;
    expect(path.kind).toBe("markdown");
    expect(readFileSync(path.root, "utf8")).toBe(EDITED);
    expect(path.root.startsWith(join(home, "blobs"))).toBe(true);
    expect(events.filter((e) => e.type === "revision.added")).toHaveLength(2);
    // The person's revision is not an agent update.
    expect(store.listCases()[0]!.revision_count).toBe(1);
  });

  test("rejects an unknown base, a non markdown base and a missing case", () => {
    const { store, caseId } = setup();
    expect(() => store.addHumanRevision(caseId, 9, EDITED)).toThrow(ArtifactError);
    expect(() => store.addHumanRevision("nope", 1, EDITED)).toThrow(ArtifactError);
  });

  test("the reply payload carries the new text, a unified diff and the count", () => {
    const { store, caseId } = setup();
    const revision = store.addHumanRevision(caseId, 1, EDITED);
    const reply = store.submitReply(caseId, {
      idempotency_key: "k1",
      choice: "a",
      comments: [],
      captures: [],
      edit: { revision: revision.n },
    });
    expect(reply.edit).toEqual({ revision: 2, base_revision: 1, passages_changed: 2 });
    const payload = store.buildReplyPayload(reply.id)!;
    const text = payload.content[0]!.type === "text" ? payload.content[0]!.text : "";
    expect(text).toContain("Choice: a (Ship it)");
    expect(text).toContain("2 passages changed");
    expect(text).toContain("Use their version as the base.");
    expect(text).toContain("-We cache for **ten** minutes.");
    expect(text).toContain("+We cache for **five** minutes.");
    expect(text).toContain("+- three");
    expect(text).toContain(EDITED);
  });

  test("Remove drops the edit from the reply and keeps the revision", () => {
    const { store, caseId } = setup();
    store.addHumanRevision(caseId, 1, EDITED);
    const reply = store.submitReply(caseId, {
      idempotency_key: "k1",
      choice: "a",
      comments: [],
      captures: [],
      edit: { revision: 2 },
    });
    const replaced = store.replaceReply(reply.id, { choice: "a", comments: [], captures: [] })!;
    expect(replaced.edit).toBeUndefined();
    const payload = store.buildReplyPayload(reply.id)!;
    const text = payload.content[0]!.type === "text" ? payload.content[0]!.text : "";
    expect(text).not.toContain("edited your document");
    expect(store.getCase(caseId)!.revisions).toHaveLength(2);
  });

  test("a reply cannot carry an agent revision as the edit", () => {
    const { store, caseId } = setup();
    expect(() =>
      store.submitReply(caseId, { idempotency_key: "k1", comments: [], captures: [], edit: { revision: 1 } }),
    ).toThrow(ArtifactError);
  });
});

describe("diffMarkdown", () => {
  test("equal texts give an empty diff", () => {
    expect(diffMarkdown("a\nb\n", "a\nb\n", "v1", "v2")).toEqual({ unified: "", passages: 0 });
  });
  test("counts separate groups of changed lines", () => {
    const before = ["1", "2", "3", "4", "5", "6", "7", "8", "9"].join("\n");
    const after = ["1", "X", "3", "4", "5", "6", "7", "Y", "9"].join("\n");
    const result = diffMarkdown(before, after, "v1", "v2");
    expect(result.passages).toBe(2);
    expect(result.unified).toContain("--- v1\n+++ v2\n");
    expect(result.unified).toContain("-2\n+X");
    expect(result.unified).toContain("-8\n+Y");
  });
});
