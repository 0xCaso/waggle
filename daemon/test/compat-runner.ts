import { Database } from "bun:sqlite";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// WAG-317: replays old agent payloads through a daemon build and returns what it stored and sent back.
// The modules are injected so the same runner can drive the 0.2.21 sources (to write the golden file)
// and the current ones (the test).

type Json = Record<string, any>;

export interface DaemonModules {
  Store: new (db: Database, home: string, bus: any) => any;
  EventBus: new () => any;
  KnockAskInput: { parse(input: unknown): any };
  KnockUpdateInput: { parse(input: unknown): any };
}

export interface StepOutcome {
  op: string;
  // The old columns, as stored. The item columns are new and left out.
  stored?: Json;
  detail?: Json;
  reply?: Json;
  check_text?: string[];
}

// The shim stages inline markdown into <home>/incoming before the daemon sees it. Do the same here.
function stagedArtifact(home: string, artifact: Json): Json {
  if (artifact.type !== "markdown" || artifact.content === undefined) return artifact;
  const dir = join(home, "incoming", crypto.randomUUID());
  mkdirSync(dir, { recursive: true });
  const path = join(dir, "artifact.md");
  writeFileSync(path, artifact.content);
  return { ...artifact, type: "markdown", content: undefined, path };
}

function staged(home: string, input: Json): Json {
  const out = { ...input };
  if (out.artifact) out.artifact = stagedArtifact(home, out.artifact);
  if (out.artifacts) out.artifacts = out.artifacts.map((a: Json) => stagedArtifact(home, a));
  return out;
}

export async function runScenario(mods: DaemonModules, steps: Json[]): Promise<StepOutcome[]> {
  const home = mkdtempSync(join(tmpdir(), "knock-compat-"));
  const store = new mods.Store(new Database(":memory:"), home, new mods.EventBus());
  // WAG-385: the 0.2.21 reply text has no "After you decide" line. The 0.2.21 sources have no such setting.
  (store as { setAskAfterDecide?: (v: "none") => unknown }).setAskAfterDecide?.("none");
  const task = store.createTask({ name: "compat", project: "app" });
  let caseId = "";
  const db = (store as any).db as Database;
  const stored = (): Json => ({
    case: db
      .query(
        `SELECT kind, status, options_json, select_mode, max_choices, recommendation, recommendation_why, recommendations_json, questions_json FROM cases WHERE id = ?`,
      )
      .get(caseId),
    option_sets: db.query(`SELECT seq, options_json, recommendation, recommendation_why FROM option_sets WHERE case_id = ? ORDER BY seq`).all(caseId),
    replies: db
      .query(`SELECT intent, choice, choices_json, message, state FROM replies WHERE case_id = ? ORDER BY created_at, rowid`)
      .all(caseId),
  });
  const out: StepOutcome[] = [];
  let n = 0;
  for (const step of steps) {
    // Timestamps have millisecond precision and the update counter compares them: keep each step apart.
    await Bun.sleep(3);
    if (step.op === "ask") {
      caseId = store.createCase(task.id, mods.KnockAskInput.parse(staged(home, step.input))).id;
      out.push({ op: "ask", stored: stored(), detail: store.getCase(caseId) });
    } else if (step.op === "update") {
      store.updateCase(caseId, mods.KnockUpdateInput.parse({ case_id: caseId, ...staged(home, step.input) }));
      out.push({ op: "update", stored: stored(), detail: store.getCase(caseId) });
    } else {
      const reply = store.submitReply(caseId, { idempotency_key: `k${++n}`, ...step.input });
      const payload = store.buildReplyPayload(reply.id);
      const texts = (payload?.content ?? []).filter((c: Json) => c.type === "text").map((c: Json) => c.text as string);
      out.push({ op: "reply", stored: stored(), reply, check_text: texts, detail: store.getCase(caseId) });
    }
  }
  return out;
}

// Replaces ids and timestamps with stable markers, so two runs compare equal.
export function scrub(value: unknown): unknown {
  const text = JSON.stringify(value)
    .replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z/g, "<ts>")
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, "<id>");
  return JSON.parse(text);
}
