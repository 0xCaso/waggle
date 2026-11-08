import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { migrate, MIGRATIONS } from "../src/schema";
import { Store } from "../src/store";
import { ReplyIntent } from "../src/protocol/states";
import { ReplySubmitParams } from "../src/protocol/rpc";
import { outcomeFor } from "../src/connectors/manager";
import type { KnockAskInput } from "../src/protocol";

// WAG-301: a discuss reply. The human leans to options, rules some out, or asks a question, and has not decided.

const ask: KnockAskInput = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact layout with a sidebar", title: "Compact" },
    { id: "b", label: "Detailed layout with tabs", title: "Detailed" },
    { id: "c", label: "Wizard layout, one step at a time", title: "Wizard" },
  ],
};

function seed() {
  const db = new Database(":memory:");
  const store = new Store(db, "/tmp/knock-test", new EventBus());
  const task = store.createTask({ name: "checkout", project: "knock" });
  store.createSession(task.id, { id: "sess-1", cwd: "/work", branch: null, pid: 4242 });
  const caseId = store.createCase(task.id, ask).id;
  return { db, store, caseId };
}

const text = (store: Store, replyId: string): string => {
  const block = store.buildReplyPayload(replyId)!.content[0]!;
  return block.type === "text" ? block.text : "";
};

describe("discuss reply protocol", () => {
  test("ReplyIntent accepts discuss", () => {
    expect(ReplyIntent.parse("discuss")).toBe("discuss");
    const parsed = ReplySubmitParams.parse({
      case_id: "c",
      idempotency_key: "k",
      intent: "discuss",
      leaning: ["a"],
      ruled_out: ["c"],
      comments: [],
      captures: [],
    });
    expect(parsed.leaning).toEqual(["a"]);
    expect(parsed.ruled_out).toEqual(["c"]);
  });
});

describe("discuss reply in the store", () => {
  test("round trip: leaning, ruled_out and message come back, the case waits on the agent", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, {
      idempotency_key: "k1",
      intent: "discuss",
      leaning: ["a", "b"],
      ruled_out: ["c"],
      message: "Does the sidebar hide on a phone?",
      comments: [],
      captures: [],
    });
    expect(reply.intent).toBe("discuss");
    expect(reply.leaning).toEqual(["a", "b"]);
    expect(reply.ruled_out).toEqual(["c"]);
    expect(reply.message).toBe("Does the sidebar hide on a phone?");
    expect(reply.choice).toBeUndefined();
    const c = store.getCase(caseId)!.case;
    expect(c.status).toBe("waiting_on_agent");
    expect(c.latest_reply_intent).toBe("discuss");
    expect(store.findReplyByIdempotencyKey("k1")!.leaning).toEqual(["a", "b"]);
  });

  test("check text says the human has not decided and lists leaning, ruled out and message", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, {
      idempotency_key: "k1",
      intent: "discuss",
      leaning: ["a", "b"],
      ruled_out: ["c"],
      message: "Does the sidebar hide on a phone?",
      comments: [],
      captures: [],
    });
    const t = text(store, reply.id);
    expect(t).toContain(`Reply to "Pick a layout" (case ${caseId})`);
    expect(t).toContain("The human has not decided");
    expect(t).toContain("Leaning: Compact, Detailed");
    expect(t).toContain("Ruled out: Wizard");
    expect(t).toContain("Message: Does the sidebar hide on a phone?");
    expect(t).toContain("waggle_update on this case");
    expect(t).toContain("drop the ruled-out options or send new ones");
    expect(t).toContain("The ask stays open");
    expect(t).not.toContain("Choice:");
  });

  test("leaning only and ruled out only leave out the other line", () => {
    const { store, caseId } = seed();
    const lean = store.submitReply(caseId, {
      idempotency_key: "k1",
      intent: "discuss",
      leaning: ["b"],
      comments: [],
      captures: [],
    });
    const t = text(store, lean.id);
    expect(t).toContain("Leaning: Detailed");
    expect(t).not.toContain("Ruled out:");
    expect(t).not.toContain("Message:");
    const out = store.submitReply(caseId, {
      idempotency_key: "k2",
      intent: "discuss",
      ruled_out: ["c"],
      comments: [],
      captures: [],
    });
    expect(text(store, out.id)).toContain("Ruled out: Wizard");
    expect(text(store, out.id)).not.toContain("Leaning:");
  });

  test("a discuss reply needs leaning, ruled_out or a message", () => {
    const { store, caseId } = seed();
    expect(() =>
      store.submitReply(caseId, { idempotency_key: "k1", intent: "discuss", comments: [], captures: [] }),
    ).toThrow();
    expect(() =>
      store.submitReply(caseId, { idempotency_key: "k2", intent: "discuss", leaning: [], message: "  ", comments: [], captures: [] }),
    ).toThrow();
  });

  test("a discuss reply with comments only is allowed: a review with comments and no pick keeps talking", () => {
    const { store, caseId } = seed();
    const comment = { id: "k1", capture_id: "cap", n: 1, rect: { x: 0, y: 0, w: 0.1, h: 0.1 }, text: "Fix this title" };
    const reply = store.submitReply(caseId, { idempotency_key: "kc", intent: "discuss", comments: [comment], captures: [{ id: "cap", revision: 1, png_base64: "AAAA", annotated_png_base64: "AAAA", taken_at: "2026-10-05T00:00:00Z" }] } as never);
    expect(reply.outcome).toBe("talk");
  });

  test("an unknown option id, an id in both lists, and leaning on a decision are rejected", () => {
    const { store, caseId } = seed();
    expect(() =>
      store.submitReply(caseId, { idempotency_key: "k1", intent: "discuss", leaning: ["zzz"], comments: [], captures: [] }),
    ).toThrow();
    expect(() =>
      store.submitReply(caseId, { idempotency_key: "k2", intent: "discuss", leaning: ["a"], ruled_out: ["a"], comments: [], captures: [] }),
    ).toThrow();
    expect(() =>
      store.submitReply(caseId, { idempotency_key: "k3", choice: "a", leaning: ["a"], comments: [], captures: [] }),
    ).toThrow();
  });

  test("a queued discuss reply can be replaced with new leans", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, {
      idempotency_key: "k1",
      intent: "discuss",
      leaning: ["a"],
      comments: [],
      captures: [],
    });
    const replaced = store.replaceReply(reply.id, { leaning: ["b"], ruled_out: ["a"].filter(() => false), message: "why?", comments: [], captures: [] })!;
    expect(replaced.intent).toBe("discuss");
    expect(replaced.leaning).toEqual(["b"]);
    expect(replaced.ruled_out).toBeUndefined();
  });

  test("a queued discuss reply that is changed to a choice becomes a decision", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, {
      idempotency_key: "k1",
      intent: "discuss",
      leaning: ["a"],
      comments: [],
      captures: [],
    });
    const replaced = store.replaceReply(reply.id, { choice: "b", comments: [], captures: [] })!;
    expect(replaced.intent).toBe("decision");
    expect(replaced.choice).toBe("b");
    expect(replaced.leaning).toBeUndefined();
    expect(text(store, reply.id)).toContain("Choice: b");
  });

  test("the ask stays open after a discuss reply is delivered, and a decision after it still works", () => {
    const { store, caseId } = seed();
    const discuss = store.submitReply(caseId, {
      idempotency_key: "k1",
      intent: "discuss",
      leaning: ["a"],
      ruled_out: ["c"],
      comments: [],
      captures: [],
    });
    store.markReplyDelivered(discuss.id);
    expect(store.getCase(caseId)!.case.status).not.toBe("resolved");
    // The agent drops the ruled-out option and revises with waggle_update.
    store.updateCase(caseId, {
      case_id: caseId,
      message: "Dropped Wizard. Which of these two?",
      options: ask.options!.slice(0, 2),
      recommendation: "a",
    });
    expect(store.getCase(caseId)!.case.status).toBe("needs_you");
    const decision = store.submitReply(caseId, { idempotency_key: "k2", choice: "a", comments: [], captures: [] });
    expect(decision.intent).toBe("decision");
    expect(text(store, decision.id)).toContain("Choice: a");
    expect(store.getCase(caseId)!.case.status).toBe("waiting_on_agent");
  });

  test("a discuss reply names options of the first set after the agent replaced them", () => {
    const { store, caseId } = seed();
    store.updateCase(caseId, {
      case_id: caseId,
      message: "New round",
      options: [{ id: "d", label: "Fourth layout", title: "Fourth" }],
      recommendation: "d",
    });
    const reply = store.submitReply(caseId, {
      idempotency_key: "k1",
      intent: "discuss",
      leaning: ["a"],
      comments: [],
      captures: [],
    });
    expect(text(store, reply.id)).toContain("Leaning: Compact");
  });

  test("a chat connector shows a discuss reply in its history", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, {
      idempotency_key: "k1",
      intent: "discuss",
      leaning: ["a"],
      comments: [],
      captures: [],
    });
    const c = store.getCase(caseId)!.case;
    expect(outcomeFor(c, reply)).toBe("Talking it over on your Mac");
  });
});

describe("migration 40 (discuss reply)", () => {
  test("keeps every reply, its links and indexes, and accepts discuss", () => {
    const db = new Database(":memory:");
    for (const m of MIGRATIONS.filter((m) => m.version <= 39)) {
      if (m.up) m.up(db);
      else db.exec(m.sql);
    }
    db.exec("PRAGMA user_version = 39");
    const at = "2026-01-01T00:00:00.000Z";
    db.query(`INSERT INTO tasks (id, name, project, created_at) VALUES ('t1', 'checkout', 'knock', ?)`).run(at);
    db.query(
      `INSERT INTO cases (id, task_id, kind, title, need, why, recommendation, recommendation_why, status, created_at, updated_at)
       VALUES ('c1', 't1', 'question', 'T', 'N', 'W', 'R', 'RW', 'waiting_on_agent', ?, ?)`,
    ).run(at, at);
    const insert = db.query(
      `INSERT INTO replies (id, case_id, idempotency_key, choice, choices_json, message, state, created_at, intent, format, source, plan_round, delivered_at, nudge_count, applied_at)
       VALUES (?, 'c1', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    );
    insert.run("r1", "k1", "a", null, "note", "queued", at, "decision", null, "mac", null, null, 0, null);
    insert.run("r2", "k2", null, null, "why?", "delivered", at, "more_detail", "eli5", "telegram", null, at, 2, at);
    insert.run("r3", "k3", null, '["a","b"]', null, "failed", at, "decision", null, "slack", 3, null, 1, null);
    db.query(`INSERT INTO reply_option_sets (reply_id, seq) VALUES ('r1', 1)`).run();
    db.query(
      `INSERT INTO captures (id, case_id, revision, reply_id, png_base64, annotated_png_base64, taken_at)
       VALUES ('cap1', 'c1', 1, 'r1', 'AA==', 'AA==', ?)`,
    ).run(at);
    db.query(`INSERT INTO comments (id, case_id, reply_id, n, text) VALUES ('cm1', 'c1', 'r1', 1, 'hi')`).run();
    const before = db.query(`SELECT * FROM replies ORDER BY id`).all() as Record<string, unknown>[];

    migrate(db);

    // db.query caches the old column list, so read the rebuilt table with a fresh statement.
    const after = db.prepare(`SELECT * FROM replies ORDER BY id`).all() as Record<string, unknown>[];
    expect(after).toHaveLength(3);
    for (let i = 0; i < before.length; i++) {
      for (const [key, value] of Object.entries(before[i]!)) expect(after[i]![key]).toEqual(value);
      expect(after[i]!.leaning_json).toBeNull();
      expect(after[i]!.ruled_out_json).toBeNull();
    }
    expect((db.query(`SELECT reply_id FROM captures WHERE id = 'cap1'`).get() as { reply_id: string }).reply_id).toBe("r1");
    expect((db.query(`SELECT reply_id FROM comments WHERE id = 'cm1'`).get() as { reply_id: string }).reply_id).toBe("r1");
    expect((db.query(`SELECT seq FROM reply_option_sets WHERE reply_id = 'r1'`).get() as { seq: number }).seq).toBe(1);
    expect(
      db.query(`SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_replies_case'`).all(),
    ).toHaveLength(1);

    expect(() =>
      db
        .query(
          `INSERT INTO replies (id, case_id, idempotency_key, state, created_at, intent, leaning_json, ruled_out_json)
           VALUES ('r4', 'c1', 'k4', 'queued', ?, 'discuss', '["a"]', '["b"]')`,
        )
        .run(at),
    ).not.toThrow();
    expect(() =>
      db
        .query(`INSERT INTO replies (id, case_id, idempotency_key, state, created_at, intent) VALUES ('r5', 'c1', 'k5', 'queued', ?, 'bogus')`)
        .run(at),
    ).toThrow();
    db.close();
  });
});

// WAG-313: the outcome of a discuss reply, and lean ids on a request of several items (spec 2.5).
describe("discuss reply and the three blocks", () => {
  test("a discuss reply is talk and never answers a plan round", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, { idempotency_key: "d1", intent: "discuss", leaning: ["a"], comments: [], captures: [] });
    expect(reply.outcome).toBe("talk");
    expect(store.getCase(caseId)!.rounds![0]).toMatchObject({ answer: null, talk_count: 1 });
  });

  test("on several items an id is <item id>/<option id>; a plain option id is refused", () => {
    const db = new Database(":memory:");
    const store = new Store(db, "/tmp/knock-test", new EventBus());
    const task = store.createTask({ name: "checkout", project: "knock" });
    const caseId = store.createCase(task.id, {
      title: "Two decisions", need: "Decide both.", why: "One screen.",
      items: [
        { id: "layout", question: "Which layout?", options: ask.options!, recommendation: "a", recommendation_why: "Default." },
        { id: "areas", question: "Which areas?", options: [{ id: "x", label: "Cart" }, { id: "y", label: "Search" }], recommendation: "x", recommendation_why: "Used." },
      ],
    } as KnockAskInput).id;
    const reply = store.submitReply(caseId, { idempotency_key: "d2", intent: "discuss", leaning: ["layout/a"], ruled_out: ["areas/y"], comments: [], captures: [] });
    expect(reply).toMatchObject({ leaning: ["layout/a"], ruled_out: ["areas/y"], outcome: "talk" });
    const body = store.buildReplyPayload(reply.id)!.content[0]!;
    expect(body.type === "text" && body.text).toContain("Leaning: Which layout?: Compact");
    expect(body.type === "text" && body.text).toContain("Ruled out: Which areas?: Search");
    expect(() => store.submitReply(caseId, { idempotency_key: "d3", intent: "discuss", leaning: ["a"], comments: [], captures: [] })).toThrow(/not an option/);
  });

  test("WAG-330: a note with the answers given so far is Keep talking, and the agent reads both", () => {
    const db = new Database(":memory:");
    const store = new Store(db, "/tmp/knock-test", new EventBus());
    const task = store.createTask({ name: "checkout", project: "knock" });
    const caseId = store.createCase(task.id, {
      title: "Three decisions", need: "Decide all three.", why: "One screen.",
      items: [
        { id: "layout", question: "Which layout?", options: ask.options!, recommendation: "a", recommendation_why: "Default." },
        { id: "areas", question: "Which areas?", options: [{ id: "x", label: "Cart" }, { id: "y", label: "Search" }], recommendation: "x", recommendation_why: "Used." },
        { id: "name", question: "What name?", options: [{ id: "p", label: "Flagged" }, { id: "q", label: "Starred" }], recommendation: "p", recommendation_why: "Short." },
      ],
    } as KnockAskInput).id;
    const reply = store.submitReply(caseId, {
      idempotency_key: "d4", intent: "discuss", message: "Is the second item a must?",
      item_answers: [{ item_id: "layout", choice: "b" }], comments: [], captures: [],
    });
    expect(reply).toMatchObject({ intent: "discuss", outcome: "talk", message: "Is the second item a must?" });
    const body = store.buildReplyPayload(reply.id)!.content[0]!;
    const out = body.type === "text" ? body.text : "";
    expect(out).toContain("The human has not decided");
    expect(out).toContain("Item 1 (Which layout?): b (Detailed)");
    expect(out).toContain("Is the second item a must?");
    if (process.env.WAG330_EVIDENCE_FILE) require("node:fs").writeFileSync(process.env.WAG330_EVIDENCE_FILE, out + "\n");
  });
});
