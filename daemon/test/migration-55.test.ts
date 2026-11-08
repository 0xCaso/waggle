import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { migrate, MIGRATIONS } from "../src/schema";

// WAG-411 pass 2: migration 55 recreates usage to take the event quick_reply_picked and three variant words.
test("migration 55 keeps the usage rows and takes the quick reply words", () => {
  const db = new Database(":memory:");
  for (const m of MIGRATIONS.filter((x) => x.version <= 54)) {
    if (m.recreatesReferencedTable) db.exec("PRAGMA foreign_keys = OFF");
    db.transaction(() => {
      if (m.up) m.up(db);
      else db.exec(m.sql);
    })();
    if (m.recreatesReferencedTable) db.exec("PRAGMA foreign_keys = ON");
  }
  db.exec("PRAGMA user_version = 54");
  db.exec(
    `INSERT INTO usage (event, hour, n, variant, format) VALUES ('detail_format_picked', '2026-10-27T10:00:00.000Z', 1, 'how_it_works', 'none')`,
  );
  expect(() => db.exec(`INSERT INTO usage (event, hour, variant) VALUES ('quick_reply_picked', 'h', 'lets_discuss')`)).toThrow();
  const before = db.query(`SELECT * FROM usage ORDER BY hour`).all();
  migrate(db);
  expect(db.query(`SELECT * FROM usage ORDER BY hour`).all()).toEqual(before);
  for (const word of ["lets_discuss", "my_comments", "show_more"]) {
    db.exec(`INSERT INTO usage (event, hour, variant) VALUES ('quick_reply_picked', 'h', '${word}')`);
  }
  expect(() => db.exec(`INSERT INTO usage (event, hour, variant) VALUES ('quick_reply_picked', 'h', 'Go ahead')`)).toThrow();
  const indexes = (db.query(`SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'usage'`).all() as { name: string }[]).map((r) => r.name);
  expect(indexes.sort()).toEqual(["idx_usage_ask", "idx_usage_hour"]);
});
