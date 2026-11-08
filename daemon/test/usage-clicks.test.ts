import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { EventBus } from "../src/events";
import { UsageRecordParams } from "../src/protocol";
import { migrate } from "../src/schema";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { truncateToHour, UsageLogger, UsageValidationError } from "../src/usage";
import { formatReport } from "../src/usage/report";
import { rmrf, rpcConnect, stageIncoming, tmpHome } from "./helpers";

// HAIL-83: the "what you click" usage events and their report section.

const homes: string[] = [];
afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

function newHome(): string {
  const h = tmpHome();
  homes.push(h);
  return h;
}

function newLogger(home: string): { db: Database; logger: UsageLogger } {
  const db = new Database(join(home, "knock.db"));
  migrate(db);
  return { db, logger: new UsageLogger(db, home) };
}

// One valid record per new app event, exactly as the app sends it.
const VALID: Record<string, unknown>[] = [
  { event: "case_opened", source: "sessions_panel" },
  { event: "case_opened", source: "auto_advance" },
  { event: "case_opened", source: "keyboard" },
  { event: "artifact_opened_full", artifact_kind: "screenshot", after_s: "0-2" },
  { event: "review_opened", artifact_kind: "html_bundle", after_s: "3-10" },
  { event: "preview_interacted", artifact_kind: "markdown" },
  { event: "option_picked", source: "click" },
  { event: "option_picked", source: "number_key" },
  { event: "recommendation_accepted", source: "button" },
  { event: "recommendation_accepted", source: "shortcut" },
  { event: "reply_typed" },
  { event: "ask_more_detail_opened" },
  { event: "change_answer_started" },
  { event: "go_back_clicked" },
  { event: "sessions_panel_opened" },
  { event: "session_detail_opened" },
  { event: "screenshot_zoom_changed", variant: "fit" },
  { event: "screenshot_zoom_changed", variant: "100" },
  { event: "screenshot_zoom_changed", variant: "zoom" },
  { event: "screenshot_set_view_opened" },
  { event: "comment_added", variant: "point" },
  { event: "comment_added", variant: "region" },
  { event: "nudge_clicked" },
  { event: "copy_prompt_clicked" },
  // WAG-366: app use and the screens added after HAIL-83.
  { event: "app_launched" },
  { event: "app_active" },
  { event: "onboarding_started" },
  { event: "onboarding_agent_connected", variant: "claude" },
  { event: "onboarding_continued" },
  { event: "first_job_started" },
  { event: "first_job_finished" },
  { event: "onboarding_prompt_copied" },
  { event: "tour_started" },
  { event: "tour_finished" },
  { event: "tour_skipped" },
  { event: "getting_started_line_opened", variant: "design_kit" },
  { event: "getting_started_hidden" },
  { event: "settings_page_opened", variant: "phone" },
  { event: "usage_exported" },
  { event: "new_idea_opened" },
  { event: "new_idea_started", variant: "claudeTerminal", n: 2 },
  { event: "launch_target_chosen", variant: "codexT3" },
  { event: "project_page_opened" },
  { event: "update_prompt_shown" },
  { event: "update_install_clicked" },
  { event: "update_later_clicked" },
  { event: "update_skipped" },
  { event: "update_restart_clicked" },
  { event: "whats_new_opened" },
  { event: "split_fold_toggled", variant: "both" },
  { event: "sources_list_opened" },
  { event: "source_opened" },
  { event: "artifact_variant_selected" },
  { event: "detail_format_picked", format: "diagram" },
  { event: "detail_format_picked", format: "none", variant: "tradeoffs" },
  { event: "quick_reply_picked", variant: "lets_discuss" },
  { event: "quick_reply_picked", variant: "my_comments" },
  { event: "quick_reply_picked", variant: "show_more" },
  { event: "compare_toggled", variant: "on" },
  { event: "compare_toggled", variant: "off" },
  { event: "comment_added", variant: "region", artifact_kind: "screenshot" },
];

// The events that are about no ask: they never take a case_id.
const NO_ASK = ["sessions_panel_opened", "session_detail_opened", "copy_prompt_clicked", "app_launched", "settings_page_opened"];

describe("usage.record params for the click events", () => {
  test("accepts every valid record", () => {
    for (const record of VALID) {
      expect(UsageRecordParams.safeParse(record).success).toBe(true);
    }
  });

  test("rejects an unknown key and a free string on every event", () => {
    for (const record of VALID) {
      expect(UsageRecordParams.safeParse({ ...record, title: "Some title" }).success).toBe(false);
      expect(UsageRecordParams.safeParse({ ...record, path: "/tmp/x" }).success).toBe(false);
      expect(UsageRecordParams.safeParse({ ...record, ask_h: "0123456789ab" }).success).toBe(false);
      if (NO_ASK.includes(record.event as string)) {
        expect(UsageRecordParams.safeParse({ ...record, case_id: "abc" }).success).toBe(false);
      }
      for (const key of ["source", "artifact_kind", "after_s", "variant", "format"]) {
        if (key in record) {
          expect(UsageRecordParams.safeParse({ ...record, [key]: "free text" }).success).toBe(false);
        }
      }
    }
  });

  test("rejects a missing required field and a field the event does not take", () => {
    const parse = (r: unknown) => UsageRecordParams.safeParse(r).success;
    expect(parse({ event: "artifact_opened_full", artifact_kind: "screenshot" })).toBe(false);
    expect(parse({ event: "artifact_opened_full", after_s: "0-2" })).toBe(false);
    expect(parse({ event: "review_opened", artifact_kind: "screenshot", after_s: "5" })).toBe(false);
    expect(parse({ event: "preview_interacted", artifact_kind: "screenshot", after_s: "0-2" })).toBe(false);
    expect(parse({ event: "option_picked" })).toBe(false);
    expect(parse({ event: "option_picked", source: "button" })).toBe(false);
    expect(parse({ event: "recommendation_accepted", source: "click" })).toBe(false);
    expect(parse({ event: "case_opened", source: "click" })).toBe(false);
    expect(parse({ event: "screenshot_zoom_changed", variant: "point" })).toBe(false);
    expect(parse({ event: "comment_added", variant: "fit" })).toBe(false);
    expect(parse({ event: "reply_typed", source: "click" })).toBe(false);
    expect(parse({ event: "settings_page_opened", variant: "claude" })).toBe(false);
    expect(parse({ event: "split_fold_toggled" })).toBe(false);
    expect(parse({ event: "detail_format_picked", format: "long" })).toBe(false);
    expect(parse({ event: "detail_format_picked", format: "none", variant: "Explain the trade-offs" })).toBe(false);
    expect(parse({ event: "quick_reply_picked", variant: "Let's discuss" })).toBe(false);
    expect(parse({ event: "quick_reply_picked" })).toBe(false);
    expect(parse({ event: "compare_toggled" })).toBe(false);
    expect(parse({ event: "compare_toggled", variant: "slider" })).toBe(false);
    expect(parse({ event: "comment_added", variant: "region", artifact_kind: "my note" })).toBe(false);
  });
});

describe("ask_h (WAG-366)", () => {
  test("a case_id from the app is stored as a salted hash, never as the id", () => {
    const { db, logger } = newLogger(newHome());
    logger.recordFromApp({ event: "case_opened", source: "queue", case_id: "c_secret-case-id" });
    logger.recordFromApp({ event: "reply_typed", case_id: "c_secret-case-id" });
    logger.recordFromApp({ event: "reply_typed", case_id: "c_other" });
    logger.recordFromApp({ event: "app_launched" });
    const rows = db.query(`SELECT * FROM usage ORDER BY rowid`).all() as Record<string, unknown>[];
    expect(rows).toHaveLength(4);
    expect(rows[0].ask_h).toMatch(/^[0-9a-f]{12}$/);
    expect(rows[1].ask_h).toBe(rows[0].ask_h);
    expect(rows[2].ask_h).not.toBe(rows[0].ask_h);
    expect(rows[3].ask_h).toBeNull();
    expect(JSON.stringify(rows)).not.toContain("secret-case-id");
    db.close();
  });
});

describe("usage log write path for the click events", () => {
  test("stores every valid record and only closed columns", () => {
    const { db, logger } = newLogger(newHome());
    for (const record of VALID) logger.record(record);
    const rows = db.query(`SELECT * FROM usage`).all() as Record<string, unknown>[];
    expect(rows).toHaveLength(VALID.length);
    const zoom = rows.find((r) => r.event === "artifact_opened_full")!;
    expect(zoom.after_s).toBe("0-2");
    expect(zoom.artifact_kind).toBe("screenshot");
    db.close();
  });

  test("rejects an unknown key or a free string in the write schema", () => {
    const { logger } = newLogger(newHome());
    expect(() => logger.record({ event: "reply_typed", text: "hello" })).toThrow(UsageValidationError);
    expect(() => logger.record({ event: "comment_added", variant: "my note" })).toThrow(
      UsageValidationError,
    );
    expect(() => logger.record({ event: "review_opened", after_s: "12s" })).toThrow(
      UsageValidationError,
    );
  });

  test("the off switch stops app events too", () => {
    const { db, logger } = newLogger(newHome());
    logger.setEnabled(false);
    for (const record of VALID) logger.record(record);
    expect(db.query(`SELECT COUNT(*) AS n FROM usage`).get()).toEqual({ n: 0 });
    db.close();
  });
});

describe("usage.record RPC for the click events", () => {
  test("records a new event and rejects a bad one without writing", async () => {
    const home = newHome();
    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    const store = new Store(db, home, bus, new UsageLogger(db, home));
    const server = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0" });
    const client = await rpcConnect(join(home, "knock.sock"));

    const ok = await client.request("usage.record", {
      event: "artifact_opened_full",
      artifact_kind: "screenshot",
      after_s: "11-60",
    });
    expect(ok.result).toEqual({ ok: true });
    const bad = await client.request("usage.record", { event: "reply_typed", text: "hi" });
    expect(bad.error?.code).toBe(-32602);

    const rows = db.query(`SELECT event, after_s FROM usage`).all();
    expect(rows).toEqual([{ event: "artifact_opened_full", after_s: "11-60" }]);
    client.close();
    server.stop();
    db.close();
  });
});

describe("migration 18", () => {
  test("keeps existing usage rows and widens the enums", () => {
    const home = newHome();
    const db = new Database(join(home, "knock.db"));
    migrate(db);
    db.exec("PRAGMA user_version = 17");
    db.query(
      `INSERT INTO usage (event, hour, source) VALUES ('case_opened', '2026-01-01T00:00:00.000Z', 'queue')`,
    ).run();
    migrate(db);
    expect(db.query(`SELECT event, source, after_s, variant FROM usage`).all()).toEqual([
      { event: "case_opened", source: "queue", after_s: null, variant: null },
    ]);
    expect(() =>
      db.exec(
        `INSERT INTO usage (event, hour, source) VALUES ('option_picked', '2026-01-01T00:00:00.000Z', 'number_key')`,
      ),
    ).not.toThrow();
    db.close();
  });
});

describe("report: What you click", () => {
  function insert(db: Database, row: Record<string, string | number>): void {
    const hour = truncateToHour(new Date());
    const cols = ["hour", ...Object.keys(row)];
    db.query(`INSERT INTO usage (${cols.join(", ")}) VALUES (${cols.map(() => "?").join(", ")})`).run(
      hour,
      ...Object.values(row),
    );
  }

  test("counts each event and derives the four lines from a fixture", () => {
    const { db } = newLogger(newHome());
    // 4 asks with a preview, 1 ask without.
    for (let i = 0; i < 4; i++) insert(db, { event: "ask_created", kind: "question", artifact_kind: "screenshot" });
    insert(db, { event: "ask_created", kind: "question" });
    // 4 answers to asks with a preview, 1 without.
    for (let i = 0; i < 4; i++) insert(db, { event: "reply_submitted", artifact_kind: "screenshot" });
    insert(db, { event: "reply_submitted" });
    // 3 full-size opens (median bucket 3-10), 1 review open.
    insert(db, { event: "artifact_opened_full", artifact_kind: "screenshot", after_s: "0-2" });
    insert(db, { event: "artifact_opened_full", artifact_kind: "screenshot", after_s: "3-10" });
    insert(db, { event: "artifact_opened_full", artifact_kind: "screenshot", after_s: "60+" });
    insert(db, { event: "review_opened", artifact_kind: "screenshot", after_s: "3-10" });
    // 3 recommendation accepts, 1 by shortcut.
    insert(db, { event: "recommendation_accepted", source: "shortcut" });
    insert(db, { event: "recommendation_accepted", source: "button" });
    insert(db, { event: "recommendation_accepted", source: "button" });
    insert(db, { event: "option_picked", source: "number_key" });
    insert(db, { event: "sessions_panel_opened" });

    const report = formatReport(db, 7);
    expect(report).toContain("What you click (last 7 days)");
    expect(report).toContain("  opened the preview full size: 3");
    expect(report).toContain("  opened the review: 1");
    expect(report).toContain("  picked an option: 1");
    expect(report).toContain("  opened the sessions panel: 1");
    expect(report).toContain("  clicked nudge: 0");
    expect(report).toContain("Asks with a preview: opened full size 75% (median after 3-10 s)");
    expect(report).toContain("Asks with a preview: opened review 25%");
    // 4 answers with a preview, 4 opens counted: none unopened.
    expect(report).toContain("Answered without opening the preview: 0%");
    expect(report).toContain("Recommendation accepted by shortcut: 33%");
    expect(report).not.toContain("—");
    db.close();
  });

  test("an empty log prints dashes, never NaN", () => {
    const { db } = newLogger(newHome());
    const report = formatReport(db, 7);
    expect(report).toContain("Asks with a preview: opened full size -");
    expect(report).toContain("Answered without opening the preview: -");
    expect(report).toContain("Recommendation accepted by shortcut: -");
    expect(report).not.toContain("NaN");
    db.close();
  });

  test("existing report lines are unchanged", () => {
    const { db } = newLogger(newHome());
    insert(db, { event: "ask_created", kind: "question" });
    const report = formatReport(db, 7);
    expect(report).toContain("Asks per day");
    expect(report).toContain("  total: 1");
    expect(report).toContain("Recommendation taken: -");
    expect(report).toContain("Distinct projects: 0");
    db.close();
  });

  test("reply_submitted records the artifact kind of the ask, or none without one", () => {
    const home = newHome();
    const { db } = newLogger(home);
    const store = new Store(db, home, undefined, new UsageLogger(db, home));
    const task = store.createTask({ name: "checkout", project: "knock" });
    store.createSession(task.id, { id: "s1", cwd: "/work", branch: null, pid: 4242 });
    const ask = {
      kind: "question" as const,
      title: "Pick",
      need: "Pick",
      why: "Cannot",
      recommendation: "a",
      recommendation_why: "Default",
      options: [{ id: "a", label: "A" }],
    };
    const plain = store.createCase(task.id, ask).id;
    store.submitReply(plain, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    const rows = db.query(`SELECT artifact_kind FROM usage WHERE event = 'reply_submitted'`).all();
    expect(rows).toEqual([{ artifact_kind: null }]);
    db.close();
  });

  test("reply_submitted carries the kind of an ask with a screenshot", () => {
    const home = newHome();
    const { db } = newLogger(home);
    const store = new Store(db, home, undefined, new UsageLogger(db, home));
    const cwd = join(home, "work");
    mkdirSync(join(cwd, "shots"), { recursive: true });
    writeFileSync(
      join(cwd, "shots", "a.png"),
      Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from("x")]),
    );
    const task = store.createTask({ name: "checkout", project: "knock" });
    store.createSession(task.id, { id: "s1", cwd: "/work", branch: null, pid: 4242 });
    const id = store.createCase(task.id, {
      kind: "review",
      title: "Look",
      need: "Look",
      why: "Cannot",
      recommendation: "a",
      recommendation_why: "Default",
      options: [{ id: "a", label: "A" }],
      artifact: stageIncoming(home, cwd, { type: "screenshot", path: "./shots/a.png" }),
    }).id;
    store.submitReply(id, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    expect(db.query(`SELECT artifact_kind FROM usage WHERE event = 'reply_submitted'`).all()).toEqual([
      { artifact_kind: "screenshot" },
    ]);
    db.close();
  });
});
