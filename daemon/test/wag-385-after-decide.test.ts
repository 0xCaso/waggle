import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { EventBus } from "../src/events";
import { getGuide, guideTopics } from "../src/guide";
import { projectGuide } from "../src/guide/project";
import { KnockAskInput, KnockUpdateInput, SettingsGetParams, SettingsSetParams, type Artifact } from "../src/protocol";
import { Store } from "../src/store";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

// WAG-385: "After you decide". The setting, the line a decision reply ends with, the guide topic, and a done
// update with an artifact on a case that is already decided.

const homes: string[] = [];
afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

function setup() {
  const home = tmpHome();
  homes.push(home);
  const cwd = join(home, "work");
  mkdirSync(dirname(join(cwd, "record.md")), { recursive: true });
  writeFileSync(join(cwd, "record.md"), "# Decision record\n");
  const dbPath = join(home, "knock.db");
  const store = new Store(new Database(dbPath), home, new EventBus());
  const taskId = store.createTask({ name: "WAG-385", project: "app" }).id;
  const record = (): Artifact => ({ ...stageIncoming(home, cwd, { type: "markdown", path: "record.md" }), name: "Decision record" });
  const id = store.createCase(
    taskId,
    KnockAskInput.parse({
      kind: "question",
      title: "Which flow?",
      need: "Pick the flow.",
      why: "It sets the scope.",
      options: [
        { id: "a", title: "Flow", label: "Build the flow" },
        { id: "b", title: "Intake", label: "Build the intake" },
      ],
      recommendation: "a",
      recommendation_why: "Fits.",
    }),
  ).id;
  return { home, dbPath, store, id, record };
}

const replyText = (store: Store, id: string, reply: object): string => {
  const created = store.createReply(id, { idempotency_key: `k${Math.random()}`, comments: [], captures: [], ...reply });
  const content = store.buildReplyPayload(created.id)!.content[0]!;
  return content.type === "text" ? content.text : "";
};

describe("askAfterDecide setting", () => {
  test("default record_tasks, each value persists, unknown value refused", () => {
    expect(SettingsGetParams.safeParse({ key: "askAfterDecide" }).success).toBe(true);
    expect(SettingsSetParams.safeParse({ key: "askAfterDecide", value: "all" }).success).toBe(false);
    const { home, dbPath, store } = setup();
    expect(store.getAskAfterDecide()).toBe("record_tasks");
    for (const v of ["none", "record", "record_tasks"] as const) {
      store.setAskAfterDecide(v);
      expect(new Store(new Database(dbPath), home, new EventBus()).getAskAfterDecide()).toBe(v);
      expect(SettingsSetParams.safeParse({ key: "askAfterDecide", value: v }).success).toBe(true);
    }
    (store as unknown as { db: Database }).db.exec("UPDATE settings SET value = 'nope' WHERE key = 'askAfterDecide'");
    expect(store.getAskAfterDecide()).toBe("record_tasks");
  });
});

describe("the reply instruction", () => {
  test("none adds nothing; record and record_tasks end with one instruction that names the guide topic", () => {
    const { store, id } = setup();
    store.setAskAfterDecide("none");
    const none = replyText(store, id, { choice: "a" });
    expect(none).not.toContain("decision-record");
    store.setAskAfterDecide("record");
    const record = replyText(store, id, { choice: "a" });
    expect(record.split("\n").at(-1)).toContain("topic decision-record");
    expect(record).not.toContain("plan the tasks");
    store.setAskAfterDecide("record_tasks");
    const tasks = replyText(store, id, { choice: "a" });
    expect(tasks.split("\n").at(-1)).toContain("topic decision-record");
    expect(tasks).toContain("plan the tasks from the record");
    expect(none.split("\n").length + 1).toBe(record.split("\n").length);
  });

  test("Keep talking, and a reply that chose nothing, get no instruction", () => {
    const { store, id } = setup();
    expect(store.getAskAfterDecide()).toBe("record_tasks");
    expect(replyText(store, id, { intent: "discuss", message: "Let us talk." })).not.toContain("decision-record");
    expect(replyText(store, id, { message: "Change the title first." })).not.toContain("decision-record");
    expect(replyText(store, id, { choice: "a" })).toContain("decision-record");
  });
});

describe("a done update after the decision", () => {
  test("is stored as a last round with its artifact", () => {
    const { store, id, record } = setup();
    store.createReply(id, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    const updated = store.updateCase(id, KnockUpdateInput.parse({ case_id: id, message: "Record written.", done: true, artifact: record() }))!;
    expect(updated.done_at).not.toBeNull();
    expect(updated.status).toBe("waiting_on_agent");
    expect(updated.latest_update_message).toBe("Record written.");
    const detail = store.getCase(id)!;
    expect(detail.revisions.map((r) => r.name)).toEqual(["Decision record"]);
    expect(detail.messages.at(-1)?.text).toBe("Record written.");
    expect(detail.replies).toHaveLength(1);
  });

  test("is stored on a case the human already dismissed", () => {
    const { store, id, record } = setup();
    store.createReply(id, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    store.dismissCase(id);
    const updated = store.updateCase(id, KnockUpdateInput.parse({ case_id: id, message: "Record written.", done: true, artifact: record() }))!;
    expect(updated.status).toBe("resolved");
    expect(store.getCase(id)!.revisions).toHaveLength(1);
  });
});

describe("guide topics", () => {
  test("decision-record holds the template, the path and the send rule", () => {
    expect(guideTopics()).toContain("decision-record");
    const text = getGuide("decision-record");
    for (const part of ["Question and choice", "## Why", "Constraints", "Ruled out", "Comments", "Open questions", "Sources"]) {
      expect(text).toContain(part);
    }
    expect(text).toContain("docs/decisions/<yyyy-mm-dd>-<slug>.md");
    expect(text).toContain('done: true');
    expect(text).toContain('"Decision record"');
    expect(text).toContain("Acceptance criteria");
  });

  test("project tells the agent to read docs/decisions before it asks", () => {
    const text = projectGuide({ project: "app", decisions: [], themes: [], repoRecords: false, stale: false, comments: [] });
    expect(text).toContain("docs/decisions");
    expect(text).toContain("Do not ask again what a record already answers");
  });
});
