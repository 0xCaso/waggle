import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { MIGRATIONS, migrate } from "../src/schema";

// HAIL-144: migration 24 adds replies.source (existing replies read as "mac") and connector_messages.
test("migration 24 keeps old replies and marks them as from the Mac", () => {
  const db = new Database(":memory:");
  const upTo23 = MIGRATIONS.filter((m) => m.version <= 23);
  for (const m of upTo23) {
    if (m.recreatesReferencedTable) db.exec("PRAGMA foreign_keys = OFF");
    db.transaction(() => {
      if (m.up) m.up(db);
      else db.exec(m.sql);
      db.exec(`PRAGMA user_version = ${m.version}`);
    })();
  }
  db.exec(`INSERT INTO tasks (id, name, project, created_at) VALUES ('t1', 't', 'p', '2026-01-01')`);
  db.exec(`INSERT INTO cases (id, task_id, kind, title, need, why, recommendation, recommendation_why, options_json, status, created_at, updated_at)
           VALUES ('c1', 't1', 'question', 'T', 'N', 'W', 'a', 'R', '[]', 'needs_you', '2026-01-01', '2026-01-01')`);
  db.exec(`INSERT INTO replies (id, case_id, idempotency_key, state, created_at) VALUES ('r1', 'c1', 'k1', 'queued', '2026-01-01')`);

  migrate(db);

  expect(db.query(`SELECT source FROM replies WHERE id = 'r1'`).get()).toEqual({ source: "mac" });
  expect(() => db.exec(`UPDATE replies SET source = 'fax' WHERE id = 'r1'`)).toThrow();
  db.exec(`INSERT INTO connector_messages (connector, case_id, msg_key, ref_json, created_at) VALUES ('telegram', 'c1', '1:2', '{}', 'now')`);
  // Running it again changes nothing.
  migrate(db);
  expect(db.query(`SELECT COUNT(*) AS n FROM connector_messages`).get()).toEqual({ n: 1 });
});
