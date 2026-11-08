import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { migrate, MIGRATIONS } from "../src/schema";

// WAG-413: migration 57 recreates usage to take the event compare_toggled and the variant words on and off.
test("migration 57 keeps the usage rows and takes the Compare words", () => {
  const db = new Database(":memory:");
  for (const m of MIGRATIONS.filter((x) => x.version <= 56)) {
    if (m.recreatesReferencedTable) db.exec("PRAGMA foreign_keys = OFF");
    db.transaction(() => {
      if (m.up) m.up(db);
      else db.exec(m.sql);
    })();
    if (m.recreatesReferencedTable) db.exec("PRAGMA foreign_keys = ON");
  }
  db.exec("PRAGMA user_version = 56");
  db.exec(`INSERT INTO usage (event, hour, n, variant) VALUES ('quick_reply_picked', '2026-10-27T10:00:00.000Z', 1, 'show_more')`);
  expect(() => db.exec(`INSERT INTO usage (event, hour, variant) VALUES ('compare_toggled', 'h', 'on')`)).toThrow();
  const before = db.query(`SELECT * FROM usage ORDER BY hour`).all();
  migrate(db);
  expect(db.query(`SELECT * FROM usage ORDER BY hour`).all()).toEqual(before);
  for (const word of ["on", "off"]) {
    db.exec(`INSERT INTO usage (event, hour, variant) VALUES ('compare_toggled', 'h', '${word}')`);
  }
  expect(() => db.exec(`INSERT INTO usage (event, hour, variant) VALUES ('compare_toggled', 'h', 'slider')`)).toThrow();
  db.exec(`INSERT INTO usage (event, hour, variant, artifact_kind) VALUES ('comment_added', 'h', 'region', 'screenshot')`);
  const indexes = (db.query(`SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'usage'`).all() as { name: string }[]).map((r) => r.name);
  expect(indexes.sort()).toEqual(["idx_usage_ask", "idx_usage_hour"]);
});
