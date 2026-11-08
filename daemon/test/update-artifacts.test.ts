import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { KnockAskInput, KnockUpdateInput } from "../src/protocol";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

// waggle_update takes artifacts like waggle_ask, and an unknown field is an error. An agent sent
// "artifacts" before update took it, got "ok", and its pictures never arrived.

const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from("png")]);
const homes: string[] = [];

afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

function write(path: string, data: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
}

function setup(): { store: Store; caseId: string; home: string; cwd: string } {
  const home = tmpHome();
  homes.push(home);
  const cwd = join(home, "work");
  write(join(cwd, "a.png"), PNG);
  write(join(cwd, "b.png"), PNG);
  const store = new Store(new Database(":memory:"), home, new EventBus());
  const taskId = store.createTask({ name: "update artifacts", project: "app" }).id;
  const { id } = store.createCase(
    taskId,
    KnockAskInput.parse({
      title: "Footnote?",
      need: "Show the footnote?",
      why: "It changes what members see.",
      options: [
        { id: "no", title: "No footnote", label: "No footnote" },
        { id: "yes", title: "Footnote", label: "Show the footnote" },
      ],
      recommendation: "no",
      recommendation_why: "The card says enough.",
    }),
  );
  return { store, caseId: id, home, cwd };
}

describe("waggle_update artifacts", () => {
  test("two named screenshots become two revisions, in order", () => {
    const { store, caseId, home, cwd } = setup();
    const input = KnockUpdateInput.parse({
      case_id: caseId,
      message: "Without and with the footnote.",
      artifacts: [
        { ...stageIncoming(home, cwd, { type: "screenshot", path: "a.png" }), name: "A: no footnote" },
        { ...stageIncoming(home, cwd, { type: "screenshot", path: "b.png" }), name: "B: footnote" },
      ],
    });
    store.updateCase(caseId, input);
    const rows = store.db
      .query(`SELECT n, kind, artifact_name FROM revisions WHERE case_id = ? ORDER BY n`)
      .all(caseId);
    expect(rows).toEqual([
      { n: 1, kind: "screenshot", artifact_name: "A: no footnote" },
      { n: 2, kind: "screenshot", artifact_name: "B: footnote" },
    ]);
    expect(store.artifactPath(caseId, 2)?.kind).toBe("screenshot");
  });

  test("an unknown field is an error that names it", () => {
    const r = KnockUpdateInput.safeParse({ case_id: "c", message: "Pictures.", attachments: [] });
    expect(r.success).toBe(false);
    expect(r.error!.issues[0]!.message).toContain('no field "attachments"');
  });

  test("artifacts sent as a JSON string is an error, not dropped", () => {
    const r = KnockUpdateInput.safeParse({
      case_id: "c",
      message: "Pictures.",
      artifacts: '[{"type":"screenshot","path":"a.png"}]',
    });
    expect(r.success).toBe(false);
    expect(r.error!.issues[0]!.path).toEqual(["artifacts"]);
  });

  test("artifact and artifacts together, or two with one name, are errors", () => {
    const shot = { type: "screenshot", path: "a.png", name: "Same" };
    expect(
      KnockUpdateInput.safeParse({ case_id: "c", message: "m", artifact: shot, artifacts: [shot] }).success,
    ).toBe(false);
    expect(KnockUpdateInput.safeParse({ case_id: "c", message: "m", artifacts: [shot, shot] }).success).toBe(false);
  });

  test("a working note cannot carry artifacts", () => {
    const r = KnockUpdateInput.safeParse({
      case_id: "c",
      message: "Still on it.",
      working: true,
      artifacts: [{ type: "screenshot", path: "a.png" }],
    });
    expect(r.success).toBe(false);
  });
});
