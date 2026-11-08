import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { EventBus } from "../src/events";
import { UsageEventType, UsageRecordParams } from "../src/protocol";
import { migrate } from "../src/schema";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import {
  replyOutcome,
  truncateToHour,
  UsageLogger,
  UsageValidationError,
} from "../src/usage";
import { formatReport } from "../src/usage/report";
import type { KnockAskInput } from "../src/protocol";
import { rpcConnect, rmrf, stageIncoming, tmpHome } from "./helpers";

const question: KnockAskInput = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact" },
    { id: "b", label: "Detailed" },
  ],
};

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const homes: string[] = [];

function newHome(): string {
  const h = tmpHome();
  homes.push(h);
  return h;
}

afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

function newLogger(home: string): { db: Database; logger: UsageLogger } {
  const db = new Database(join(home, "knock.db"));
  migrate(db);
  return { db, logger: new UsageLogger(db, home) };
}

function usageRows(db: Database): Record<string, unknown>[] {
  return db.query(`SELECT * FROM usage ORDER BY rowid`).all() as Record<string, unknown>[];
}

describe("usage schema (the single write path)", () => {
  test("rejects a title, a path and comment text through every event type", () => {
    const { logger } = newLogger(newHome());
    for (const event of UsageEventType.options) {
      expect(() => logger.record({ event, title: "Some title" })).toThrow(UsageValidationError);
      expect(() => logger.record({ event, path: "/tmp/secret" })).toThrow(UsageValidationError);
      expect(() => logger.record({ event, text: "comment text" })).toThrow(UsageValidationError);
    }
  });

  test("rejects any string that is not an enum member", () => {
    const { logger } = newLogger(newHome());
    expect(() => logger.record({ event: "not_an_event" })).toThrow(UsageValidationError);
    expect(() => logger.record({ event: "ask_created", kind: "bogus" })).toThrow(
      UsageValidationError,
    );
    expect(() => logger.record({ event: "ask_created", artifact_kind: "bogus" })).toThrow(
      UsageValidationError,
    );
    expect(() => logger.record({ event: "reply_submitted", outcome: "bogus" })).toThrow(
      UsageValidationError,
    );
    expect(() => logger.record({ event: "case_opened", source: "bogus" })).toThrow(
      UsageValidationError,
    );
  });

  test("rejects an invalid project_h", () => {
    const { logger } = newLogger(newHome());
    expect(() => logger.record({ event: "ask_created", project_h: "XYZ" })).toThrow(
      UsageValidationError,
    );
    expect(() => logger.record({ event: "ask_created", project_h: "a1b2c3d4e5" })).toThrow(
      UsageValidationError,
    );
    expect(() => logger.record({ event: "ask_created", project_h: "a1b2c3d4" })).not.toThrow();
  });

  test("a valid record writes exactly the closed columns, no content", () => {
    const { db, logger } = newLogger(newHome());
    logger.record({ event: "ask_created", kind: "question", project_h: "a1b2c3d4" });

    const rows = usageRows(db);
    expect(rows).toHaveLength(1);
    const row = rows[0];
    expect(Object.keys(row).sort()).toEqual([
      "after_s",
      "artifact_kind",
      "ask_h",
      "category",
      "duration_s",
      "event",
      "format",
      "hour",
      "intent",
      "kind",
      "n",
      "note",
      "outcome",
      "project_h",
      "rule_id",
      "source",
      "stage",
      "variant",
    ]);
    expect(row.event).toBe("ask_created");
    expect(row.kind).toBe("question");
    expect(row.artifact_kind).toBeNull();
    expect(row.hour).toBe(truncateToHour(new Date()));
    expect(row.project_h).toBe("a1b2c3d4");
    db.close();
  });
});

describe("project_h", () => {
  test("is HMAC-SHA256 of the name with a per-install salt, 8 hex chars", () => {
    const home = newHome();
    const { logger } = newLogger(home);
    const h = logger.projectHash("weekend-league");
    expect(h).toMatch(/^[0-9a-f]{8}$/);
    // Deterministic for the same salt.
    expect(logger.projectHash("weekend-league")).toBe(h);
    // Different names hash differently; the name itself is never stored.
    expect(logger.projectHash("omea-web")).not.toBe(h);
    expect(usageRows(new Database(join(home, "knock.db")))).toHaveLength(0);
  });

  test("a fresh logger on the same home reuses the stored salt", () => {
    const home = newHome();
    const first = newLogger(home).logger.projectHash("omea-web");
    const second = newLogger(home).logger.projectHash("omea-web");
    expect(second).toBe(first);
  });
});

describe("reply outcome", () => {
  test("took_recommendation when the choice matches the recommendation", () => {
    expect(replyOutcome({ choice: "a", recommendation: "a" })).toBe("took_recommendation");
  });

  test("other_option when the choice differs from the recommendation", () => {
    expect(replyOutcome({ choice: "b", recommendation: "a" })).toBe("other_option");
  });

  test("message_only when there is no choice", () => {
    expect(replyOutcome({ message: "Go with A.", recommendation: "a" })).toBe("message_only");
    expect(replyOutcome({ recommendation: "a" })).toBe("message_only");
  });
});

describe("Store usage recording", () => {
  function usageStore(home: string) {
    const db = new Database(join(home, "knock.db"));
    const logger = new UsageLogger(db, home);
    const store = new Store(db, home, undefined, logger);
    return { db, store };
  }

  function png(path: string): void {
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, Buffer.concat([PNG_SIG, Buffer.from("usage png")]));
  }

  test("ask_created carries kind and project_h, never the project name", () => {
    const home = newHome();
    const { db, store } = usageStore(home);
    const task = store.createTask({ name: "checkout", project: "weekend-league" });
    store.createCase(task.id, question);

    const rows = usageRows(db);
    expect(rows.map((r) => r.event)).toEqual(["ask_created"]);
    expect(rows[0].kind).toBe("question");
    expect(rows[0].artifact_kind).toBeNull();
    expect(rows[0].project_h).toMatch(/^[0-9a-f]{8}$/);
    expect(JSON.stringify(rows)).not.toContain("weekend-league");
    db.close();
  });

  test("ask_created carries artifact_kind and revision_added for a review with a staged artifact", () => {
    const home = newHome();
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });
    png(join(cwd, "shots", "a.png"));
    const { db, store } = usageStore(home);
    const task = store.createTask({ name: "checkout", project: "omea-web" });
    store.createCase(task.id, {
      kind: "review",
      title: "Layout",
      need: "Pick",
      why: "Can't",
      recommendation: "a",
      recommendation_why: "Default",
      options: [{ id: "a", label: "Compact" }],
      artifact: stageIncoming(home, cwd, { type: "screenshot", path: "./shots/a.png" }),
    });

    const rows = usageRows(db);
    expect(rows.map((r) => r.event)).toEqual(["ask_created", "revision_added"]);
    expect(rows[0].artifact_kind).toBe("screenshot");
    expect(rows[1].n).toBe(1);
    db.close();
  });

  test("reply_submitted records outcome, duration_s and comment count", () => {
    const home = newHome();
    const { db, store } = usageStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    store.createSession(task.id, { id: "s1", cwd: "/work", branch: null, pid: 4242 });
    const caseId = store.createCase(task.id, question).id;

    store.submitReply(caseId, {
      idempotency_key: "k1",
      choice: "a",
      message: "Go with A.",
      comments: [
        { id: "c1", capture_id: "cap1", n: 1, rect: { x: 0, y: 0, w: 0.1, h: 0.1 }, text: "x" },
        { id: "c2", capture_id: "cap1", n: 2, rect: { x: 0, y: 0, w: 0.1, h: 0.1 }, text: "y" },
      ],
      captures: [
        {
          id: "cap1",
          revision: 1,
          png_base64: "x",
          annotated_png_base64: "x",
          taken_at: "2026-09-26T00:00:00.000Z",
        },
      ],
    });

    const rows = usageRows(db);
    const submitted = rows.find((r) => r.event === "reply_submitted");
    expect(submitted).toBeDefined();
    expect(submitted?.outcome).toBe("took_recommendation");
    expect(submitted?.n).toBe(2);
    expect(submitted?.duration_s).toBeGreaterThanOrEqual(0);
    db.close();
  });

  test("reply_submitted records intent, source, the note length and ask_h, never the note text (WAG-366)", () => {
    const home = newHome();
    const { db, store } = usageStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    store.createSession(task.id, { id: "s1", cwd: "/work", branch: null, pid: 4242 });
    const caseId = store.createCase(task.id, question).id;
    store.submitReply(caseId, {
      idempotency_key: "k1",
      message: "Please explain the retry path again.",
      intent: "more_detail",
      format: "diagram",
      comments: [],
      captures: [],
    });

    const rows = usageRows(db);
    const created = rows.find((r) => r.event === "ask_created")!;
    const submitted = rows.find((r) => r.event === "reply_submitted")!;
    expect(created.ask_h).toMatch(/^[0-9a-f]{12}$/);
    expect(submitted.ask_h).toBe(created.ask_h);
    expect(submitted.intent).toBe("more_detail");
    expect(submitted.format).toBe("diagram");
    expect(submitted.source).toBe("mac");
    expect(submitted.note).toBe("21-100");
    expect(JSON.stringify(rows)).not.toContain("retry path");
    expect(JSON.stringify(rows)).not.toContain(caseId);
    db.close();
  });

  test("dismiss and restore are recorded once each with the ask's hash (WAG-366)", () => {
    const home = newHome();
    const { db, store } = usageStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    const caseId = store.createCase(task.id, question).id;
    store.dismissCase(caseId);
    store.dismissCase(caseId);
    store.restoreCase(caseId);

    const rows = usageRows(db);
    expect(rows.map((r) => r.event)).toEqual(["ask_created", "ask_dismissed", "ask_restored"]);
    expect(new Set(rows.map((r) => r.ask_h)).size).toBe(1);
    db.close();
  });

  test("the export holds note text only after the person turns the switch on (WAG-366)", () => {
    const home = newHome();
    const { db, store } = usageStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    store.createSession(task.id, { id: "s1", cwd: "/work", branch: null, pid: 4242 });
    const caseId = store.createCase(task.id, question).id;
    store.submitReply(caseId, { idempotency_key: "k1", choice: "a", message: "Ship the small one first.", comments: [], captures: [] });
    const log = store.toolLog!;
    const versions = { app: "9.9.9", plugin: null, macos: "15.0" };

    expect(log.control({}).export_text).toBe(false);
    const off = log.export(join(home, "out", "off"), versions);
    expect(off.notes).toBe(0);
    const offText = readFileSync(off.json_path, "utf8");
    expect(offText).not.toContain("Ship the small one");
    expect(JSON.parse(offText).includes_text).toBe(false);

    expect(log.control({ export_text: true }).export_text).toBe(true);
    const on = log.export(join(home, "out", "on"), versions);
    expect(on.notes).toBe(1);
    const body = JSON.parse(readFileSync(on.json_path, "utf8"));
    expect(body.includes_text).toBe(true);
    expect(body.notes[0].note).toBe("Ship the small one first.");
    expect(body.notes[0].intent).toBe("decision");
    expect(body.notes[0].ask_h).toMatch(/^[0-9a-f]{12}$/);
    expect(JSON.stringify(body.notes)).not.toContain(caseId);
    // The usage log itself still holds no text.
    expect(JSON.stringify(usageRows(db))).not.toContain("Ship the small one");

    expect(log.control({ export_text: false }).export_text).toBe(false);
    db.close();
  });

  test("reply_delivered and reply_failed are recorded; a retry that cannot work is not (HAIL-192)", () => {
    const home = newHome();
    const { db, store } = usageStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    store.createSession(task.id, { id: "s1", cwd: "/work", branch: null, pid: 4242 });
    const caseId = store.createCase(task.id, question).id;

    const reply = store.submitReply(caseId, {
      idempotency_key: "k1",
      choice: "a",
      comments: [],
      captures: [],
    });
    store.markReplyDelivered(reply.id);

    const second = store.createCase(task.id, question).id;
    const queued = store.submitReply(second, {
      idempotency_key: "k2",
      comments: [],
      captures: [],
    });
    store.setSessionState("s1", "ended"); // fails the queued reply
    const failed = store.getCase(second)!.replies[0];
    expect(failed.state).toBe("failed");

    const retried = store.retryReply(queued.id)!;
    expect(retried.state).toBe("failed"); // session still ended: nothing changes

    const events = usageRows(db).map((r) => r.event);
    expect(events).toContain("reply_delivered");
    expect(events).toContain("reply_failed");
    expect(events).not.toContain("reply_retried");
    db.close();
  });

  test("session_started records the live session count at that moment", () => {
    const home = newHome();
    const { db, store } = usageStore(home);
    const task = store.createTask({ name: "checkout", project: "knock" });
    store.createSession(task.id, { id: "s1", cwd: "/work", branch: null, pid: 1 });
    store.createSession(task.id, { id: "s2", cwd: "/work", branch: null, pid: 2 });

    const started = usageRows(db).filter((r) => r.event === "session_started");
    expect(started.map((r) => r.n)).toEqual([1, 2]);
    db.close();
  });

  test("a usage write failure never breaks an ask", () => {
    const home = newHome();
    const { db, store } = usageStore(home);
    db.exec("DROP TABLE usage"); // force the usage INSERT to fail

    const task = store.createTask({ name: "checkout", project: "knock" });
    const created = store.createCase(task.id, question);
    expect(store.getCase(created.id)).not.toBeNull();
    expect(existsSync(join(home, "logs", "usage.log"))).toBe(true);
    db.close();
  });
});

describe("retention and report", () => {
  function insert(db: Database, row: Record<string, unknown>): void {
    db.query(
      `INSERT INTO usage (event, hour, n, duration_s, kind, artifact_kind, outcome, source, project_h)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      row.event as string,
      row.hour as string,
      (row.n as number) ?? null,
      (row.duration_s as number) ?? null,
      (row.kind as string) ?? null,
      (row.artifact_kind as string) ?? null,
      (row.outcome as string) ?? null,
      (row.source as string) ?? null,
      (row.project_h as string) ?? null,
    );
  }

  test("deleteOlderThan removes rows strictly older than N days", () => {
    const home = newHome();
    const { db, logger } = newLogger(home);
    const old = truncateToHour(new Date(Date.now() - 40 * 86_400_000));
    const recent = truncateToHour(new Date());
    insert(db, { event: "ask_created", hour: old, project_h: "deadbeef" });
    insert(db, { event: "ask_created", hour: recent, project_h: "cafebabe" });

    const deleted = logger.deleteOlderThan(30);
    expect(deleted).toBe(1);
    const left = usageRows(db);
    expect(left).toHaveLength(1);
    expect(left[0].project_h).toBe("cafebabe");
    db.close();
  });

  test("formatReport prints the privacy header and the counts", () => {
    const home = newHome();
    const { db } = newLogger(home);
    const hour = truncateToHour(new Date());
    insert(db, { event: "ask_created", hour, kind: "question", project_h: "aaaa1111" });
    insert(db, { event: "ask_created", hour, kind: "review", artifact_kind: "screenshot", project_h: "bbbb2222" });
    insert(db, { event: "revision_added", hour, n: 2 });
    insert(db, {
      event: "reply_submitted",
      hour,
      duration_s: 40,
      outcome: "took_recommendation",
      n: 3,
    });
    insert(db, { event: "case_opened", hour, source: "notification" });
    insert(db, { event: "case_opened", hour, source: "queue" });
    insert(db, { event: "session_started", hour, n: 3 });
    insert(db, { event: "reply_failed", hour });

    const out = formatReport(db, 7);
    expect(out).toContain(
      "Nothing here leaves your Mac unless you paste it. Contains no titles, text, paths or project names.",
    );
    expect(out).toContain("total: 2");
    expect(out).toContain("question: 1");
    expect(out).toContain("review: 1");
    expect(out).toContain("screenshot: 1");
    expect(out).toContain(`hour ${new Date().getUTCHours()}: median 40s, p90 40s`);
    expect(out).toContain("Recommendation taken: 100% (1 of 1)");
    expect(out).toContain("Comments per review: 3.0");
    expect(out).toContain("Revisions per ask: 0.5");
    expect(out).toContain("Notification open share: 50% (1 of 2)");
    expect(out).toContain("Delivery failures: 1");
    expect(out).toContain("Peak live sessions: 3");
    expect(out).toContain("Distinct projects: 2");
    db.close();
  });

  test("formatReport counts diagrams, the note box and per-ask shares (WAG-366)", () => {
    const { db, logger } = newLogger(newHome());
    const a = "aaaaaaaaaaaa";
    const b = "bbbbbbbbbbbb";
    logger.record({ event: "ask_created", kind: "review", artifact_kind: "diagram", ask_h: a });
    logger.record({ event: "ask_created", kind: "question", ask_h: b });
    logger.record({ event: "case_opened", source: "queue", ask_h: a });
    logger.record({ event: "ask_more_detail_opened", ask_h: a });
    logger.record({ event: "detail_format_picked", format: "eli5", ask_h: a });
    logger.record({ event: "detail_format_picked", format: "none", variant: "numbers", n: 1, ask_h: a });
    logger.record({ event: "detail_format_picked", format: "none", variant: "screenshots", n: 1, ask_h: a });
    logger.record({ event: "ask_more_detail_opened", source: "button", ask_h: a });
    logger.record({ event: "reply_submitted", outcome: "message_only", intent: "more_detail", format: "eli5", source: "mac", note: "21-100", n: 0, artifact_kind: "diagram", ask_h: a });
    logger.record({ event: "reply_submitted", outcome: "took_recommendation", intent: "decision", source: "telegram", note: "none", n: 0, ask_h: b });
    logger.record({ event: "ask_dismissed", ask_h: b });
    logger.record({ event: "app_launched" });
    logger.record({ event: "app_active" });
    logger.record({ event: "settings_page_opened", variant: "phone" });

    const report = formatReport(db, 14);
    expect(report).toContain("  diagram: 1");
    expect(report).toContain("  Note box used: 50% (1 of 2)");
    expect(report).toContain("  decided: 1, kept talking: 0, asked for more detail: 1");
    expect(report).toContain("  from the Mac: 1, Telegram: 1, Slack: 0");
    expect(report).toContain("  Ask for more detail: opened 2, sent 1 (50% of replies)");
    expect(report).toContain("  Detail format picked: like I'm five 1, diagram 0, interactive page 0, no format 2");
    expect(report).toContain("  Quick ask picked: trade-offs 0, prototype 0, numbers 1, example 0, screenshots 1, something else 0");
    expect(report).toContain("  Sent from a pill of the row: 2 of 3");
    expect(report).toContain("  Row pills clicked: trade-offs 0, prototype 0, screenshots 1, numbers 1, example 0, diagram 0, three dots 1");
    expect(report).toContain("  asks: 2");
    expect(report).toContain("  opened in the app: 50% (1 of 2)");
    expect(report).toContain("  answered: 100% (2 of 2)");
    expect(report).toContain("  dismissed: 50% (1 of 2)");
    expect(report).toContain("  asks with a preview answered without opening it: 100% (1 of 1)");
    expect(report).toContain("  launches: 1");
    expect(report).toContain("  Settings: opened a page: 1 (phone 1)");
    db.close();
  });

  test("formatReport is safe on an empty table", () => {
    const home = newHome();
    const { db } = newLogger(home);
    const out = formatReport(db, 7);
    expect(out).toContain("no asks");
    expect(out).toContain("Distinct projects: 0");
    db.close();
  });
});

describe("truncateToHour", () => {
  test("zeroes minutes, seconds and millis", () => {
    expect(truncateToHour(new Date("2026-09-26T19:42:13.456Z"))).toBe("2026-09-26T19:00:00.000Z");
  });
});

describe("usage.record RPC", () => {
  test("the params schema accepts case_opened with a source and comment_mode_started alone", () => {
    expect(UsageRecordParams.safeParse({ event: "case_opened", source: "notification" }).success).toBe(true);
    expect(UsageRecordParams.safeParse({ event: "comment_mode_started" }).success).toBe(true);
    expect(UsageRecordParams.safeParse({ event: "case_opened" }).success).toBe(false);
    expect(UsageRecordParams.safeParse({ event: "comment_mode_started", source: "queue" }).success).toBe(false);
    expect(UsageRecordParams.safeParse({ event: "case_opened", source: "queue", title: "x" }).success).toBe(false);
  });

  test("records through the same write schema and rejects invalid params", async () => {
    const home = tmpHome();
    homes.push(home);
    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    const store = new Store(db, home, bus, new UsageLogger(db, home));
    const server = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0" });

    const client = await rpcConnect(join(home, "knock.sock"));
    const ok = await client.request("usage.record", { event: "case_opened", source: "queue" });
    expect(ok.result).toEqual({ ok: true });
    expect(ok.error).toBeUndefined();

    const bad = await client.request("usage.record", { event: "case_opened" });
    expect(bad.error?.code).toBe(-32602);

    const rows = usageRows(db);
    expect(rows).toHaveLength(1);
    expect(rows[0].event).toBe("case_opened");
    expect(rows[0].source).toBe("queue");

    client.close();
    server.stop();
    db.close();
  });
});
