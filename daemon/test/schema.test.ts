import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { migrate, MIGRATIONS } from "../src/schema";

function openDb(path = ":memory:"): Database {
  return new Database(path);
}

function userVersion(db: Database): number {
  return Number((db.query("PRAGMA user_version").get() as { user_version: number }).user_version);
}

function tableNames(db: Database): string[] {
  return (
    db
      .query(
        `SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name`,
      )
      .all() as { name: string }[]
  ).map((r) => r.name);
}

describe("schema migrations", () => {
  test("migration 1 creates every required table and sets the version", () => {
    const db = openDb();
    migrate(db);

    const tables = tableNames(db);
    for (const required of [
      "tasks",
      "sessions",
      "cases",
      "revisions",
      "captures",
      "comments",
      "replies",
      "events",
    ]) {
      expect(tables).toContain(required);
    }
    expect(userVersion(db)).toBe(MIGRATIONS[MIGRATIONS.length - 1].version);
    db.close();
  });

  test("a second run is a no-op and keeps the version", () => {
    const db = openDb();
    migrate(db);
    const firstVersion = userVersion(db);
    migrate(db);
    expect(userVersion(db)).toBe(firstVersion);
    db.close();
  });

  test("migration 6 adds runtime to sessions and cases, defaulting to claude (KNOCK-20)", () => {
    const db = openDb();
    migrate(db);
    db.query(
      `INSERT INTO tasks (id, name, project, created_at) VALUES ('t1', 'checkout', 'knock', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO sessions (id, task_id, cwd, pid, state, connected_at)
       VALUES ('s1', 't1', '/work', 1, 'live', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO cases
        (id, task_id, kind, title, need, why, recommendation, recommendation_why, status, created_at, updated_at)
       VALUES ('c1', 't1', 'question', 'T', 'N', 'W', 'R', 'RW', 'needs_you', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')`,
    ).run();

    const session = db.query(`SELECT runtime FROM sessions WHERE id = 's1'`).get() as { runtime: string };
    const knockCase = db.query(`SELECT runtime FROM cases WHERE id = 'c1'`).get() as { runtime: string };
    expect(session.runtime).toBe("claude");
    expect(knockCase.runtime).toBe("claude");
    db.close();
  });

  // HAIL-33: migrations 9-11 widen revisions.kind and usage.artifact_kind to
  // accept "markdown" (a table recreation, since SQLite cannot alter a CHECK
  // constraint in place), add replies.intent, and add cases.follows_case_id.
  // A database that already had rows before those migrations must keep them,
  // unmoved (AC: "Existing databases migrate forward without data loss").
  test("migrations 9-11 preserve existing rows and widen the artifact kind CHECK", () => {
    const db = openDb();
    for (const m of MIGRATIONS.filter((m) => m.version <= 8)) {
      db.exec(m.sql);
    }
    db.exec("PRAGMA user_version = 8");

    db.query(
      `INSERT INTO tasks (id, name, project, created_at) VALUES ('t1', 'checkout', 'knock', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO cases
        (id, task_id, kind, title, need, why, recommendation, recommendation_why, status, created_at, updated_at)
       VALUES ('c1', 't1', 'question', 'T', 'N', 'W', 'R', 'RW', 'needs_you', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO revisions (id, case_id, n, created_at, kind, sha256, ext)
       VALUES ('r1', 'c1', 1, '2026-01-01T00:00:00.000Z', 'screenshot', 'abc123', 'png')`,
    ).run();
    db.query(
      `INSERT INTO replies (id, case_id, idempotency_key, choice, state, created_at)
       VALUES ('reply1', 'c1', 'key1', 'a', 'queued', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO usage (event, hour, kind, artifact_kind) VALUES ('ask_created', '2026-01-01T00:00:00.000Z', 'question', 'screenshot')`,
    ).run();

    migrate(db);

    expect(userVersion(db)).toBe(MIGRATIONS[MIGRATIONS.length - 1].version);

    const revision = db.query(`SELECT kind, sha256, ext FROM revisions WHERE id = 'r1'`).get() as {
      kind: string;
      sha256: string;
      ext: string;
    };
    expect(revision).toEqual({ kind: "screenshot", sha256: "abc123", ext: "png" });

    const usageRow = db.query(`SELECT kind, artifact_kind FROM usage`).get() as {
      kind: string;
      artifact_kind: string;
    };
    expect(usageRow).toEqual({ kind: "question", artifact_kind: "screenshot" });

    // Pre-existing rows get the new columns' defaults.
    const reply = db.query(`SELECT intent, replaced_at FROM replies WHERE id = 'reply1'`).get() as {
      intent: string;
      replaced_at: string | null;
    };
    expect(reply.intent).toBe("decision");
    expect(reply.replaced_at).toBeNull();
    const knockCase = db.query(`SELECT follows_case_id FROM cases WHERE id = 'c1'`).get() as {
      follows_case_id: string | null;
    };
    expect(knockCase.follows_case_id).toBeNull();

    // The widened CHECK constraints now accept "markdown".
    expect(() =>
      db
        .query(
          `INSERT INTO revisions (id, case_id, n, created_at, kind, sha256, ext)
           VALUES ('r2', 'c1', 2, '2026-01-01T00:00:00.000Z', 'markdown', 'def456', 'md')`,
        )
        .run(),
    ).not.toThrow();
    expect(() =>
      db
        .query(
          `INSERT INTO usage (event, hour, kind, artifact_kind) VALUES ('ask_created', '2026-01-01T00:00:00.000Z', 'question', 'markdown')`,
        )
        .run(),
    ).not.toThrow();
    expect(() =>
      db
        .query(`INSERT INTO replies (id, case_id, idempotency_key, intent, state, created_at)
                 VALUES ('reply2', 'c1', 'key2', 'more_detail', 'queued', '2026-01-01T00:00:00.000Z')`)
        .run(),
    ).not.toThrow();
    expect(() =>
      db.query(`UPDATE cases SET follows_case_id = 'c1' WHERE id = 'c1'`).run(),
    ).not.toThrow();

    db.close();
  });

  // HAIL-40: migration 12 widens revisions.kind and usage.artifact_kind to
  // accept "screenshots" and adds revisions.items_json, the same table-
  // recreation shape migration 9 used for "markdown". Existing rows (from
  // before migration 12) must survive untouched.
  test("migration 12 preserves existing rows and widens the artifact kind CHECK to screenshots", () => {
    const db = openDb();
    for (const m of MIGRATIONS.filter((m) => m.version <= 11)) {
      db.exec(m.sql);
    }
    db.exec("PRAGMA user_version = 11");

    db.query(
      `INSERT INTO tasks (id, name, project, created_at) VALUES ('t1', 'checkout', 'knock', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO cases
        (id, task_id, kind, title, need, why, recommendation, recommendation_why, status, created_at, updated_at)
       VALUES ('c1', 't1', 'question', 'T', 'N', 'W', 'R', 'RW', 'needs_you', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO revisions (id, case_id, n, created_at, kind, sha256, ext)
       VALUES ('r1', 'c1', 1, '2026-01-01T00:00:00.000Z', 'screenshot', 'abc123', 'png')`,
    ).run();
    db.query(
      `INSERT INTO usage (event, hour, kind, artifact_kind) VALUES ('ask_created', '2026-01-01T00:00:00.000Z', 'question', 'markdown')`,
    ).run();

    migrate(db);

    expect(userVersion(db)).toBe(MIGRATIONS[MIGRATIONS.length - 1].version);

    const revision = db.query(`SELECT kind, sha256, ext, items_json FROM revisions WHERE id = 'r1'`).get() as {
      kind: string;
      sha256: string;
      ext: string;
      items_json: string | null;
    };
    expect(revision).toEqual({ kind: "screenshot", sha256: "abc123", ext: "png", items_json: null });

    const usageRow = db.query(`SELECT kind, artifact_kind FROM usage`).get() as {
      kind: string;
      artifact_kind: string;
    };
    expect(usageRow).toEqual({ kind: "question", artifact_kind: "markdown" });

    expect(() =>
      db
        .query(
          `INSERT INTO revisions (id, case_id, n, created_at, kind, items_json)
           VALUES ('r2', 'c1', 2, '2026-01-01T00:00:00.000Z', 'screenshots', '[{"sha256":"x","ext":"png"}]')`,
        )
        .run(),
    ).not.toThrow();
    expect(() =>
      db
        .query(
          `INSERT INTO usage (event, hour, kind, artifact_kind) VALUES ('ask_created', '2026-01-01T00:00:00.000Z', 'review', 'screenshots')`,
        )
        .run(),
    ).not.toThrow();

    db.close();
  });

  // HAIL-44: migration 13 adds cases.replaces_case_id/withdrawn_at and widens
  // replies.state to accept "superseded" - the first widening that recreates
  // a table another table's FK still points at (captures.reply_id), so this
  // also proves that link survives the DROP+RENAME with foreign_keys off.
  test("migration 13 preserves existing rows, keeps captures linked, and widens replies.state", () => {
    const db = openDb();
    for (const m of MIGRATIONS.filter((m) => m.version <= 12)) {
      db.exec(m.sql);
    }
    db.exec("PRAGMA user_version = 12");

    db.query(
      `INSERT INTO tasks (id, name, project, created_at) VALUES ('t1', 'checkout', 'knock', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO cases
        (id, task_id, kind, title, need, why, recommendation, recommendation_why, status, created_at, updated_at)
       VALUES ('c1', 't1', 'question', 'T', 'N', 'W', 'R', 'RW', 'needs_you', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO replies (id, case_id, idempotency_key, choice, state, created_at)
       VALUES ('reply1', 'c1', 'key1', 'a', 'queued', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO captures (id, case_id, revision, reply_id, png_base64, annotated_png_base64, taken_at)
       VALUES ('cap1', 'c1', 1, 'reply1', 'AA==', 'AA==', '2026-01-01T00:00:00.000Z')`,
    ).run();

    migrate(db);

    expect(userVersion(db)).toBe(MIGRATIONS[MIGRATIONS.length - 1].version);

    const reply = db.query(`SELECT choice, state, intent FROM replies WHERE id = 'reply1'`).get() as {
      choice: string;
      state: string;
      intent: string;
    };
    expect(reply).toEqual({ choice: "a", state: "queued", intent: "decision" });

    // captures.reply_id still points at the recreated replies row.
    const capture = db.query(`SELECT reply_id FROM captures WHERE id = 'cap1'`).get() as {
      reply_id: string;
    };
    expect(capture.reply_id).toBe("reply1");

    const knockCase = db
      .query(`SELECT replaces_case_id, withdrawn_at FROM cases WHERE id = 'c1'`)
      .get() as { replaces_case_id: string | null; withdrawn_at: string | null };
    expect(knockCase).toEqual({ replaces_case_id: null, withdrawn_at: null });

    // The widened CHECK constraint now accepts "superseded".
    expect(() =>
      db
        .query(
          `UPDATE replies SET state = 'superseded' WHERE id = 'reply1'`,
        )
        .run(),
    ).not.toThrow();
    expect(() =>
      db.query(`UPDATE cases SET replaces_case_id = 'c1', withdrawn_at = '2026-01-02T00:00:00.000Z' WHERE id = 'c1'`).run(),
    ).not.toThrow();

    // foreign_keys is back on after the migration: an insert with a bad FK
    // still fails.
    db.exec("PRAGMA foreign_keys = ON");
    expect(() =>
      db
        .query(
          `INSERT INTO replies (id, case_id, idempotency_key, state, created_at)
           VALUES ('reply2', 'missing-case', 'key2', 'queued', '2026-01-01T00:00:00.000Z')`,
        )
        .run(),
    ).toThrow();

    db.close();
  });

  // HAIL-46: sessions.list and `waggle doctor` need last_seen_at. A session
  // row that existed before migration 14 has none yet, so the migration
  // backfills it from connected_at rather than leaving it null.
  test("migration 14 backfills last_seen_at from connected_at for existing sessions", () => {
    const db = openDb();
    for (const m of MIGRATIONS.filter((m) => m.version <= 12)) {
      db.exec(m.sql);
    }
    db.exec("PRAGMA user_version = 12");

    db.query(
      `INSERT INTO tasks (id, name, project, created_at) VALUES ('t1', 'knock', 'knock', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO sessions (id, task_id, cwd, branch, pid, state, connected_at)
       VALUES ('s1', 't1', '/tmp/knock', 'main', 123, 'live', '2026-01-01T00:00:00.000Z')`,
    ).run();

    migrate(db);

    expect(userVersion(db)).toBe(MIGRATIONS[MIGRATIONS.length - 1].version);
    const row = db.query(`SELECT last_seen_at FROM sessions WHERE id = 's1'`).get() as {
      last_seen_at: string;
    };
    expect(row.last_seen_at).toBe("2026-01-01T00:00:00.000Z");
    db.close();
  });


  // HAIL-64: a reply delivered before migration 16 gets its pickup time from
  // the event log, else from created_at; a queued reply stays NULL.
  test("migration 16 backfills replies.delivered_at from the event log", () => {
    const db = openDb();
    for (const m of MIGRATIONS.filter((m) => m.version <= 15)) {
      db.exec(m.sql);
    }
    db.exec("PRAGMA user_version = 15");
    db.query(
      `INSERT INTO tasks (id, name, project, created_at) VALUES ('t1', 'knock', 'knock', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO cases (id, task_id, kind, title, need, why, recommendation, recommendation_why, options_json, status, created_at, updated_at)
       VALUES ('c1', 't1', 'question', 'T', 'N', 'W', 'R', 'RW', '[]', 'waiting_on_agent', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')`,
    ).run();
    for (const [id, state] of [["r1", "delivered"], ["r2", "delivered"], ["r3", "queued"]]) {
      db.query(
        `INSERT INTO replies (id, case_id, idempotency_key, state, created_at)
         VALUES (?, 'c1', ?, ?, '2026-01-01T00:01:00.000Z')`,
      ).run(id, `k-${id}`, state);
    }
    db.query(
      `INSERT INTO events (type, case_id, reply_id, at) VALUES ('reply.state_changed', 'c1', 'r1', '2026-01-01T00:05:00.000Z')`,
    ).run();

    migrate(db);

    const at = (id: string) =>
      (db.query(`SELECT delivered_at FROM replies WHERE id = ?`).get(id) as { delivered_at: string | null }).delivered_at;
    expect(at("r1")).toBe("2026-01-01T00:05:00.000Z");
    expect(at("r2")).toBe("2026-01-01T00:01:00.000Z");
    expect(at("r3")).toBeNull();
    db.close();
  });

  // HAIL-139: migration 22 adds replies.format, CHECKed to the three values.
  test("migration 22 adds replies.format with the three-value CHECK", () => {
    const db = openDb();
    migrate(db);
    db.query(
      `INSERT INTO tasks (id, name, project, created_at) VALUES ('t1', 'knock', 'knock', '2026-01-01T00:00:00.000Z')`,
    ).run();
    db.query(
      `INSERT INTO cases (id, task_id, kind, title, need, why, recommendation, recommendation_why, options_json, status, created_at, updated_at)
       VALUES ('c1', 't1', 'question', 'T', 'N', 'W', 'R', 'RW', '[]', 'needs_you', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')`,
    ).run();

    for (const format of ["eli5", "diagram", "page"]) {
      expect(() =>
        db
          .query(
            `INSERT INTO replies (id, case_id, idempotency_key, intent, format, state, created_at)
             VALUES (?, 'c1', ?, 'more_detail', ?, 'queued', '2026-01-01T00:00:00.000Z')`,
          )
          .run(`reply-${format}`, `key-${format}`, format),
      ).not.toThrow();
    }
    expect(() =>
      db
        .query(
          `INSERT INTO replies (id, case_id, idempotency_key, format, state, created_at)
           VALUES ('reply-ste', 'c1', 'key-ste', 'ste', 'queued', '2026-01-01T00:00:00.000Z')`,
        )
        .run(),
    ).toThrow();

    const row = db.query(`SELECT format FROM replies WHERE id = 'reply-diagram'`).get() as { format: string };
    expect(row.format).toBe("diagram");
    db.close();
  });

  test("events.seq is AUTOINCREMENT and monotonic", () => {
    const db = openDb();
    migrate(db);
    db.query(
      `INSERT INTO events (type, at) VALUES ('case.created', ?), ('case.created', ?)`,
    ).run("2026-01-01T00:00:00.000Z", "2026-01-01T00:00:01.000Z");
    const rows = db.query("SELECT seq FROM events ORDER BY seq").all() as { seq: number }[];
    expect(rows.map((r) => r.seq)).toEqual([1, 2]);
    db.close();
  });

  test("migration 25 keeps old comments and lets a comment have a text anchor (HAIL-150)", () => {
    const db = openDb();
    for (const m of MIGRATIONS.filter((x) => x.version <= 24)) {
      if (m.up) m.up(db);
      else db.exec(m.sql);
      db.exec(`PRAGMA user_version = ${m.version}`);
    }
    db.exec(`PRAGMA foreign_keys = OFF`);
    db.exec(`INSERT INTO captures (id, case_id, revision, reply_id, png_base64, annotated_png_base64, taken_at)
             VALUES ('cap', 'c1', 1, 'r1', 'a', 'b', 't')`);
    db.exec(`INSERT INTO comments (id, case_id, capture_id, n, rect_json, text)
             VALUES ('cm1', 'c1', 'cap', 1, '{"x":0,"y":0,"w":1,"h":1}', 'old')`);
    db.exec(`PRAGMA foreign_keys = ON`);
    migrate(db);
    expect(userVersion(db)).toBe(MIGRATIONS[MIGRATIONS.length - 1].version);
    const old = db.query(`SELECT * FROM comments WHERE id = 'cm1'`).get() as Record<string, unknown>;
    expect(old).toMatchObject({ capture_id: "cap", reply_id: "r1", text: "old", anchor_json: null });
    db.exec(`PRAGMA foreign_keys = OFF`);
    db.exec(`INSERT INTO comments (id, case_id, capture_id, reply_id, n, rect_json, anchor_json, text)
             VALUES ('cm2', 'c1', NULL, 'r1', 2, NULL, '{"kind":"text"}', 'new')`);
    expect((db.query(`SELECT count(*) AS n FROM comments`).get() as { n: number }).n).toBe(2);
    db.close();
  });
});
