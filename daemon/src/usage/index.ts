import { createHmac, randomBytes } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Database } from "bun:sqlite";
import { z } from "zod";
import { ToolCallLog } from "./tools";
import {
  AskCategory,
  UsageRuleId,
  UsageAfter,
  UsageArtifactKind,
  UsageEventType,
  UsageFormat,
  UsageIntent,
  UsageKind,
  UsageNote,
  UsageOutcome,
  UsageSource,
  UsageStage,
  UsageVariant,
} from "../protocol";

// The private usage log (KNOCK-19). One write path, `UsageLogger.record`, which
// validates every record with a strict Zod schema and never stores anything
// but closed enums, counts, durations and a hashed project tag. A failed write
// is logged to logs/usage.log and ignored: the log never blocks or fails an
// ask.

// The off switch is a marker file in KNOCK_HOME (presence = off), so `knock
// report --off` works even when the daemon is not running. Logging is on by
// default (no marker). The per-install salt lives beside it and never leaves
// the Mac.
export const USAGE_OFF_FILE = "usage-off";
export const USAGE_SALT_FILE = "usage-salt";
export const USAGE_LOG_FILE = "usage.log";

// The single write schema. `.strict` rejects any unknown key, so a title, a
// path or comment text can never be written. `hour` is derived, not accepted:
// only this module computes the UTC hour.
export const UsageRecordInput = z.strictObject({
  event: UsageEventType,
  kind: UsageKind.optional(),
  artifact_kind: UsageArtifactKind.optional(),
  outcome: UsageOutcome.optional(),
  source: UsageSource.optional(),
  after_s: UsageAfter.optional(),
  variant: UsageVariant.optional(),
  n: z.number().int().nonnegative().optional(),
  duration_s: z.number().int().nonnegative().optional(),
  project_h: z.string().regex(/^[0-9a-f]{8}$/).optional(),
  // WAG-366: a salted hash of the ask, made by askHash. The id itself is never stored.
  ask_h: z.string().regex(/^[0-9a-f]{12}$/).optional(),
  intent: UsageIntent.optional(),
  format: UsageFormat.optional(),
  stage: UsageStage.optional(),
  note: UsageNote.optional(),
  // WAG-412: the category slug of an ask and the id of the rule that decided it. Coded values, never text.
  category: AskCategory.optional(),
  rule_id: UsageRuleId.optional(),
});
export type UsageRecordInput = z.infer<typeof UsageRecordInput>;

export class UsageValidationError extends Error {}

// The outcome of a reply (KNOCK-19): took_recommendation when the choice
// matches the case's recommendation, other_option when it differs, and
// message_only when the reply carries no choice at all.
// A multi-select reply (HAIL-123) took the recommendation when its ticks equal the recommended set.
export function replyOutcome(input: {
  choice?: string;
  choices?: string[];
  message?: string;
  recommendation: string;
  recommendations?: string[];
}): z.infer<typeof UsageOutcome> {
  if (input.choices !== undefined) {
    if (input.choices.length === 0) return "message_only";
    const rec = input.recommendations ?? [input.recommendation];
    const same = input.choices.length === rec.length && input.choices.every((id) => rec.includes(id));
    return same ? "took_recommendation" : "other_option";
  }
  if (input.choice === undefined) return "message_only";
  return input.choice === input.recommendation ? "took_recommendation" : "other_option";
}

// The length of a reply's note as a bucket (WAG-366). The text itself never reaches the usage log.
export function noteBucket(message: string | null | undefined): UsageNote {
  const length = (message ?? "").trim().length;
  if (length === 0) return "none";
  if (length <= 20) return "1-20";
  if (length <= 100) return "21-100";
  if (length <= 400) return "101-400";
  return "400+";
}

// The UTC hour a timestamp falls in, truncated to the hour, as an ISO string.
export function truncateToHour(date: Date): string {
  return new Date(date.getTime() - (date.getTime() % 3_600_000)).toISOString();
}

export class UsageLogger {
  // The tool-call log (HAIL-195). It shares this logger's database and its off switch.
  readonly tools: ToolCallLog;

  constructor(
    private readonly db: Database,
    private readonly dataRoot: string,
  ) {
    this.tools = new ToolCallLog(db, dataRoot, (caseId) => this.askHash(caseId));
  }

  // Logging is on unless the marker file exists.
  get enabled(): boolean {
    return !existsSync(join(this.dataRoot, USAGE_OFF_FILE));
  }

  // The one write path. Throws UsageValidationError for an invalid record
  // (a caller bug; the daemon builds valid records and the RPC pre-validates).
  // Never throws for a DB write failure: it logs to logs/ and ignores it, so
  // the log never blocks or fails an ask.
  record(input: unknown): void {
    const parsed = UsageRecordInput.safeParse(input);
    if (!parsed.success) {
      throw new UsageValidationError(formatIssues(parsed.error));
    }
    if (!this.enabled) return;
    this.writeRow(parsed.data);
  }

  // HMAC-SHA256 of the project name with the per-install salt, truncated to 8
  // hex chars. The name itself is never stored.
  projectHash(project: string): string {
    return createHmac("sha256", this.readOrCreateSalt()).update(project).digest("hex").slice(0, 8);
  }

  // HMAC-SHA256 of the case id with the per-install salt, truncated to 12 hex chars (WAG-366). It lets
  // the report count per ask. The id itself is never stored in the usage table.
  askHash(caseId: string): string {
    return createHmac("sha256", this.readOrCreateSalt()).update(`ask:${caseId}`).digest("hex").slice(0, 12);
  }

  // A record from the app (usage.record): the optional case_id becomes ask_h, then the one write path.
  recordFromApp(input: unknown): void {
    if (typeof input !== "object" || input === null || !("case_id" in input)) return this.record(input);
    const { case_id, ...rest } = input as { case_id?: unknown } & Record<string, unknown>;
    this.record(typeof case_id === "string" ? { ...rest, ask_h: this.askHash(case_id) } : rest);
  }

  // Turns logging on or off. `off` deletes rows separately in the CLI, so a
  // mark + delete is never torn across a crash.
  setEnabled(on: boolean): void {
    const path = join(this.dataRoot, USAGE_OFF_FILE);
    if (on) {
      try {
        rmSync(path, { force: true });
      } catch {
        // Already gone.
      }
      return;
    }
    try {
      mkdirSync(this.dataRoot, { recursive: true, mode: 0o700 });
      writeFileSync(path, "", { mode: 0o600 });
    } catch (err) {
      this.logWriteError(err);
    }
  }

  // Deletes rows whose hour is strictly older than `days` days. Returns the
  // number of rows deleted.
  deleteOlderThan(days: number): number {
    const cutoff = truncateToHour(new Date(Date.now() - days * 86_400_000));
    try {
      return this.db.query(`DELETE FROM usage WHERE hour < ?`).run(cutoff).changes;
    } catch (err) {
      this.logWriteError(err);
      return 0;
    }
  }

  private writeRow(row: UsageRecordInput): void {
    const hour = truncateToHour(new Date());
    try {
      this.db
        .query(
          `INSERT INTO usage
            (event, hour, n, duration_s, kind, artifact_kind, outcome, source, project_h, after_s, variant,
             ask_h, intent, format, stage, note, category, rule_id)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          row.event,
          hour,
          row.n ?? null,
          row.duration_s ?? null,
          row.kind ?? null,
          row.artifact_kind ?? null,
          row.outcome ?? null,
          row.source ?? null,
          row.project_h ?? null,
          row.after_s ?? null,
          row.variant ?? null,
          row.ask_h ?? null,
          row.intent ?? null,
          row.format ?? null,
          row.stage ?? null,
          row.note ?? null,
          row.category ?? null,
          row.rule_id ?? null,
        );
    } catch (err) {
      this.logWriteError(err);
    }
  }

  private readOrCreateSalt(): string {
    const path = join(this.dataRoot, USAGE_SALT_FILE);
    try {
      const existing = readFileSync(path, "utf8").trim();
      if (/^[0-9a-f]{32}$/.test(existing)) return existing;
    } catch {
      // No salt yet: create one below.
    }
    const salt = randomBytes(16).toString("hex");
    try {
      mkdirSync(this.dataRoot, { recursive: true, mode: 0o700 });
      writeFileSync(path, salt, { mode: 0o600 });
    } catch (err) {
      // Could not persist; use an ephemeral salt so this process still works.
      this.logWriteError(err);
    }
    return salt;
  }

  private logWriteError(err: unknown): void {
    try {
      mkdirSync(join(this.dataRoot, "logs"), { recursive: true, mode: 0o700 });
      appendFileSync(
        join(this.dataRoot, "logs", USAGE_LOG_FILE),
        `${new Date().toISOString()} usage write failed: ${String(err)}\n`,
      );
    } catch {
      // Nothing left to do.
    }
  }
}

function formatIssues(error: { issues: { path: PropertyKey[]; message: string }[] }): string {
  return error.issues.map((issue) => `${issue.path.join(".")}: ${issue.message}`).join("; ");
}
