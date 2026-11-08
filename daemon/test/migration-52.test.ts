import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { migrate, MIGRATIONS } from "../src/schema";

// WAG-394 review R6: migration 52 gives an old share the signature of its last reply, so a past decision is not
// published after the upgrade. Only an answer made later has a new signature.
test("migration 52 sets outcome_sig of old shares to the signature of their last reply", () => {
  const db = new Database(":memory:");
  for (const m of MIGRATIONS.filter((x) => x.version <= 51)) {
    if (m.recreatesReferencedTable) db.exec("PRAGMA foreign_keys = OFF");
    db.transaction(() => {
      if (m.up) m.up(db);
      else db.exec(m.sql);
    })();
    if (m.recreatesReferencedTable) db.exec("PRAGMA foreign_keys = ON");
  }
  db.exec("PRAGMA user_version = 51");
  db.exec("PRAGMA foreign_keys = OFF");
  const share = (id: string, sig: string | null) =>
    db.query(`INSERT INTO relay_shares (case_id, relay_id, url, mode, created_at, outcome_sig) VALUES (?, 'r', 'u', 'link', 't', ?)`).run(id, sig);
  const reply = (id: string, caseId: string, at: string, replaced: string | null) =>
    db
      .query(`INSERT INTO replies (id, case_id, idempotency_key, state, created_at, replaced_at) VALUES (?, ?, ?, 'delivered', ?, ?)`)
      .run(id, caseId, "k" + id, at, replaced);
  share("c1", null);
  reply("r1", "c1", "2026-10-01T10:00:00.000Z", null);
  reply("r2", "c1", "2026-10-02T10:00:00.000Z", "2026-10-03T10:00:00.000Z");
  share("c2", null); // never answered
  share("c3", "kept:"); // already has a signature
  reply("r3", "c3", "2026-10-01T10:00:00.000Z", null);
  migrate(db);
  const sig = (id: string) => (db.query(`SELECT outcome_sig AS s FROM relay_shares WHERE case_id = ?`).get(id) as { s: string | null }).s;
  expect(sig("c1")).toBe("r2:2026-10-03T10:00:00.000Z");
  expect(sig("c2")).toBeNull();
  expect(sig("c3")).toBe("kept:");
  migrate(db);
  expect(sig("c1")).toBe("r2:2026-10-03T10:00:00.000Z");
});
