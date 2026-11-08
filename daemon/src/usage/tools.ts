import { randomBytes } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { Database } from "bun:sqlite";
import {
  UsageToolCallParams,
  type UsageContextParams,
  type UsageControlParams,
  type UsageControlResult,
  type UsageSummaryResult,
} from "../protocol";
import { USAGE_LOG_FILE, USAGE_OFF_FILE } from "./index";

// The tool-call log (HAIL-195): one content-free row per MCP tool call, the token estimate, the usage
// view and the export. Money is for the operator only (HAIL-199): the app, the summary RPC and the
// export carry tokens, never dollars. `waggle report --tools --cost` is the one place that shows cost. The daemon is the only writer. Nothing here reads or stores the text of an
// ask, a reply, an artifact or a path.

// The one documented token heuristic. A tool call's request is what the agent wrote, its response is
// what the agent received. Text is about 4 bytes per token; one image in a response is a fixed
// estimate. Both are estimates, not measurements.
export const BYTES_PER_TOKEN = 4;
export const TOKENS_PER_IMAGE = 1600;

// Estimated cost at API list prices, in US dollars per million tokens. One reference set (a Sonnet
// class model), not the price of the model the person actually runs. Edit these to change every
// cost `waggle report --tools --cost` shows.
export const PRICES = {
  input_per_mtok: 3,
  output_per_mtok: 15,
  cache_read_per_mtok: 0.3,
  cache_write_per_mtok: 3.75,
};

// Rows older than this are deleted at start and once a day (the hourly usage events too).
export const USAGE_RETENTION_DAYS = 90;
export const USAGE_TRANSCRIPT_OFF_FILE = "usage-transcript-off";
export const INSTALL_ID_FILE = "install-id";
// WAG-366: "Include my notes and comments in the export". Presence = on, so it is off until the person
// turns it on. The usage tables never hold text: the export reads it from the replies at export time.
export const USAGE_EXPORT_TEXT_FILE = "usage-export-text";
// A context reading from the hook waits this long for the shim's row of the same call.
const CONTEXT_TTL_MS = 15 * 60_000;
// The tool that waits for the person, so its cost is "time spent waiting".
export const WAIT_TOOL = "waggle_check";

export function estimateTokens(bytes: number): number {
  return Math.ceil(bytes / BYTES_PER_TOKEN);
}

// One reply's text in an export the person agreed to (WAG-366).
export interface ExportedNote {
  hour: string;
  ask_h?: string;
  intent: string;
  format: string | null;
  source: string;
  note: string;
  comments: string[];
}

export interface ToolCallRow {
  id: number;
  at: string;
  tool: string;
  duration_ms: number;
  wait_ms: number;
  result: string;
  session_id: string | null;
  client_name: string | null;
  case_id: string | null;
  artifact_kind: string | null;
  // WAG-409: why a failed call failed. A stable code, never the error text. NULL for a call that did not fail.
  error_code: string | null;
  request_bytes: number;
  response_bytes: number;
  images: number;
  tokens_written: number;
  tokens_received: number;
  ctx_input: number | null;
  ctx_cache_read: number | null;
  ctx_cache_creation: number | null;
  ctx_output: number | null;
}

type CostFields = Pick<
  ToolCallRow,
  "tokens_written" | "tokens_received" | "ctx_input" | "ctx_cache_read" | "ctx_cache_creation"
>;

// The estimated cost of one call: what the agent wrote at the output price, what it received at the
// input price, and (when measured) the context it re-read at the input, cache read and cache write
// prices. ctx_output is not priced: it is the agent's whole message, and the request already counts
// the part that is this call.
export function callCostUsd(row: CostFields, prices = PRICES): number {
  return (
    (row.tokens_written * prices.output_per_mtok +
      row.tokens_received * prices.input_per_mtok +
      (row.ctx_input ?? 0) * prices.input_per_mtok +
      (row.ctx_cache_read ?? 0) * prices.cache_read_per_mtok +
      (row.ctx_cache_creation ?? 0) * prices.cache_write_per_mtok) /
    1_000_000
  );
}

const contextTokens = (row: CostFields): number =>
  (row.ctx_input ?? 0) + (row.ctx_cache_read ?? 0) + (row.ctx_cache_creation ?? 0);

// All the tokens one call cost: written, received and re-read context.
const callTokens = (row: CostFields): number => row.tokens_written + row.tokens_received + contextTokens(row);

// The operator's cost view for `waggle report --tools --cost`. Never sent to the app or the export.
export interface CostView {
  total: number;
  wait: number;
  by_tool: Map<string, number>;
  by_session: Map<string, number>;
  prices: typeof PRICES;
}

export class ToolCallLog {
  // Context readings from the hooks, waiting for the shim's row of the same call.
  private readonly pending = new Map<string, { tool: string; ctx: UsageContextParams; at: number }>();

  constructor(
    private readonly db: Database,
    private readonly dataRoot: string,
    // The usage logger's salted hash of a case id, so an exported note carries ask_h and never the id.
    private readonly askHash?: (caseId: string) => string,
  ) {}

  get recordEnabled(): boolean {
    return !existsSync(join(this.dataRoot, USAGE_OFF_FILE));
  }

  // Reading the transcript needs both switches on.
  get transcriptEnabled(): boolean {
    return this.recordEnabled && !existsSync(join(this.dataRoot, USAGE_TRANSCRIPT_OFF_FILE));
  }

  // Writes one row. Throws only for an invalid record (a caller bug); a failed write is logged and
  // ignored, so the log never fails a tool call.
  record(input: unknown): void {
    const call = UsageToolCallParams.parse(input);
    if (!this.recordEnabled) return;
    const ctx = this.takeContext(call.session_id, call.tool);
    try {
      this.db
        .query(
          `INSERT INTO tool_calls
            (at, tool, duration_ms, wait_ms, result, session_id, client_name, case_id, artifact_kind,
             request_bytes, response_bytes, images, tokens_written, tokens_received,
             ctx_input, ctx_cache_read, ctx_cache_creation, ctx_output, error_code)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          new Date().toISOString(),
          call.tool,
          call.duration_ms,
          call.wait_ms,
          call.result,
          call.session_id ?? null,
          call.client_name ?? null,
          call.case_id ?? null,
          call.artifact_kind ?? null,
          call.request_bytes,
          call.response_bytes,
          call.images,
          estimateTokens(call.request_bytes),
          estimateTokens(call.response_bytes) + call.images * TOKENS_PER_IMAGE,
          ctx?.input ?? null,
          ctx?.cache_read ?? null,
          ctx?.cache_creation ?? null,
          ctx?.output ?? null,
          call.error_code ?? null,
        );
    } catch (err) {
      this.logWriteError(err);
    }
  }

  // The hook's reading for the call that is about to run. Kept in memory until the row arrives.
  noteContext(ctx: UsageContextParams): void {
    if (!this.transcriptEnabled) return;
    const now = Date.now();
    for (const [key, value] of this.pending) if (now - value.at > CONTEXT_TTL_MS) this.pending.delete(key);
    this.pending.set(ctx.session_id, { tool: ctx.tool, ctx, at: now });
  }

  private takeContext(sessionId: string | undefined, tool: string): UsageContextParams | null {
    if (sessionId === undefined || !this.transcriptEnabled) return null;
    const held = this.pending.get(sessionId);
    if (!held || held.tool !== tool || Date.now() - held.at > CONTEXT_TTL_MS) return null;
    this.pending.delete(sessionId);
    return held.ctx;
  }

  rows(sinceIso?: string): ToolCallRow[] {
    return (
      sinceIso === undefined
        ? this.db.query(`SELECT * FROM tool_calls ORDER BY id`).all()
        : this.db.query(`SELECT * FROM tool_calls WHERE at >= ? ORDER BY id`).all(sinceIso)
    ) as ToolCallRow[];
  }

  count(): { tool_calls: number; usage_events: number } {
    const n = (table: string) => (this.db.query(`SELECT COUNT(*) AS n FROM ${table}`).get() as { n: number }).n;
    return { tool_calls: n("tool_calls"), usage_events: n("usage") };
  }

  deleteAll(): number {
    try {
      const calls = this.db.query(`DELETE FROM tool_calls`).run().changes;
      const events = this.db.query(`DELETE FROM usage`).run().changes;
      return calls + events;
    } catch (err) {
      this.logWriteError(err);
      return 0;
    }
  }

  deleteOlderThan(days: number): number {
    try {
      const cutoff = new Date(Date.now() - days * 86_400_000).toISOString();
      return this.db.query(`DELETE FROM tool_calls WHERE at < ?`).run(cutoff).changes;
    } catch (err) {
      this.logWriteError(err);
      return 0;
    }
  }

  // The switches and the delete button. Turning "record" off deletes nothing; "delete" does.
  control(params: UsageControlParams): UsageControlResult {
    if (params.record !== undefined) setMarker(this.dataRoot, USAGE_OFF_FILE, !params.record);
    if (params.transcript !== undefined) setMarker(this.dataRoot, USAGE_TRANSCRIPT_OFF_FILE, !params.transcript);
    if (params.export_text !== undefined) setMarker(this.dataRoot, USAGE_EXPORT_TEXT_FILE, params.export_text);
    const deleted = params.delete === true ? this.deleteAll() : 0;
    if (params.delete === true) this.pending.clear();
    return {
      record: this.recordEnabled,
      transcript: !existsSync(join(this.dataRoot, USAGE_TRANSCRIPT_OFF_FILE)),
      export_text: this.exportTextEnabled,
      retention_days: USAGE_RETENTION_DAYS,
      ...this.count(),
      deleted,
    };
  }

  summary(days: number): UsageSummaryResult {
    const since = new Date(Date.now() - days * 86_400_000).toISOString();
    const rows = this.rows(since);
    const byTool = new Map<string, UsageSummaryResult["tools"][number]>();
    const bySession = new Map<string, UsageSummaryResult["top_sessions"][number]>();
    let total = 0;
    let waitTokens = 0;
    let waitCalls = 0;
    let waited = 0;
    let measured = 0;
    let written = 0;
    let received = 0;
    let context = 0;
    const byError = new Map<string, { result: string; error_code: string; calls: number }>();
    for (const row of rows) {
      if (row.error_code !== null) {
        const key = `${row.result}\t${row.error_code}`;
        const e = byError.get(key) ?? { result: row.result, error_code: row.error_code, calls: 0 };
        e.calls += 1;
        byError.set(key, e);
      }
      const n = callTokens(row);
      total += n;
      written += row.tokens_written;
      received += row.tokens_received;
      context += contextTokens(row);
      if (row.ctx_input !== null) measured += 1;
      waited += row.wait_ms / 1000;
      if (row.tool === WAIT_TOOL) {
        waitTokens += n;
        waitCalls += 1;
      }
      const t = byTool.get(row.tool) ?? {
        tool: row.tool,
        calls: 0,
        tokens_written: 0,
        tokens_received: 0,
        context_tokens: 0,
        waited_s: 0,
      };
      t.calls += 1;
      t.tokens_written += row.tokens_written;
      t.tokens_received += row.tokens_received;
      t.context_tokens += contextTokens(row);
      t.waited_s += row.wait_ms / 1000;
      byTool.set(row.tool, t);
      if (row.session_id) {
        const s = bySession.get(row.session_id) ?? {
          session_id: row.session_id,
          client_name: row.client_name,
          calls: 0,
          tokens: 0,
        };
        s.calls += 1;
        s.tokens += n;
        bySession.set(row.session_id, s);
      }
    }
    const toolTokens = (t: UsageSummaryResult["tools"][number]): number =>
      t.tokens_written + t.tokens_received + t.context_tokens;
    return {
      days,
      record: this.recordEnabled,
      transcript: !existsSync(join(this.dataRoot, USAGE_TRANSCRIPT_OFF_FILE)),
      export_text: this.exportTextEnabled,
      retention_days: USAGE_RETENTION_DAYS,
      calls: rows.length,
      tokens_written: written,
      tokens_received: received,
      context_tokens: context,
      context_measured_calls: measured,
      tools: [...byTool.values()].sort((a, b) => toolTokens(b) - toolTokens(a) || b.calls - a.calls),
      wait_calls: waitCalls,
      wait_share: total > 0 ? waitTokens / total : null,
      waited_s: Math.round(waited),
      top_sessions: [...bySession.values()].sort((a, b) => b.tokens - a.tokens).slice(0, 5),
      errors: [...byError.values()].sort((a, b) => b.calls - a.calls || a.error_code.localeCompare(b.error_code)),
      tokens_per_image: TOKENS_PER_IMAGE,
      bytes_per_token: BYTES_PER_TOKEN,
    };
  }

  // Estimated dollars for the same window. Only `waggle report --tools --cost` reads this.
  costView(days: number): CostView {
    const since = new Date(Date.now() - days * 86_400_000).toISOString();
    const view: CostView = { total: 0, wait: 0, by_tool: new Map(), by_session: new Map(), prices: PRICES };
    for (const row of this.rows(since)) {
      const c = callCostUsd(row);
      view.total += c;
      if (row.tool === WAIT_TOOL) view.wait += c;
      view.by_tool.set(row.tool, (view.by_tool.get(row.tool) ?? 0) + c);
      if (row.session_id) view.by_session.set(row.session_id, (view.by_session.get(row.session_id) ?? 0) + c);
    }
    return view;
  }

  get exportTextEnabled(): boolean {
    return existsSync(join(this.dataRoot, USAGE_EXPORT_TEXT_FILE));
  }

  // The text the person agreed to share (WAG-366): one entry per reply of the retention window that
  // has a note or comments. Read from the replies at export time; nothing here is kept in the usage log.
  private notes(): ExportedNote[] {
    const since = new Date(Date.now() - USAGE_RETENTION_DAYS * 86_400_000).toISOString();
    const replies = this.db
      .query(
        `SELECT id, case_id, created_at, intent, format, source, message FROM replies
         WHERE created_at >= ? AND state != 'superseded' ORDER BY created_at`,
      )
      .all(since) as {
      id: string;
      case_id: string;
      created_at: string;
      intent: string | null;
      format: string | null;
      source: string | null;
      message: string | null;
    }[];
    const commentsOf = this.db.query(
      `SELECT c.text FROM comments c JOIN captures p ON p.id = c.capture_id WHERE p.reply_id = ? ORDER BY c.n`,
    );
    const notes: ExportedNote[] = [];
    for (const r of replies) {
      const comments = (commentsOf.all(r.id) as { text: string }[]).map((c) => c.text).filter((t) => t.trim() !== "");
      const note = (r.message ?? "").trim();
      if (note === "" && comments.length === 0) continue;
      notes.push({
        hour: `${r.created_at.slice(0, 13)}:00:00.000Z`,
        ...(this.askHash ? { ask_h: this.askHash(r.case_id) } : {}),
        intent: r.intent ?? "decision",
        format: r.format,
        source: r.source ?? "mac",
        note,
        comments,
      });
    }
    return notes;
  }

  // A random id made once per install. Not derived from the user, the Mac or a path.
  installId(): string {
    const path = join(this.dataRoot, INSTALL_ID_FILE);
    try {
      const existing = readFileSync(path, "utf8").trim();
      if (/^[0-9a-f]{32}$/.test(existing)) return existing;
    } catch {
      // No id yet: make one below.
    }
    const id = randomBytes(16).toString("hex");
    try {
      mkdirSync(this.dataRoot, { recursive: true, mode: 0o700 });
      writeFileSync(path, id, { mode: 0o600 });
    } catch (err) {
      this.logWriteError(err);
    }
    return id;
  }

  // The export: one JSON file at `path` (".json" is added when missing) and a CSV of the tool-call
  // rows beside it. Holds the rows, the hourly events, versions, the macOS version and the install
  // id. No user name, no path, no content.
  export(path: string, versions: { app: string; plugin: string | null; macos: string }): {
    json_path: string;
    csv_path: string;
    tool_calls: number;
    usage_events: number;
    notes: number;
  } {
    const jsonPath = path.endsWith(".json") ? path : `${path}.json`;
    const csvPath = jsonPath.replace(/\.json$/, ".csv");
    const calls = this.rows();
    const events = this.db
      .query(
        `SELECT event, hour, n, duration_s, kind, artifact_kind, outcome, source, project_h, after_s, variant,
                ask_h, intent, format, stage, note, category, rule_id
         FROM usage ORDER BY hour`,
      )
      .all();
    // The text is in the file only when the person turned the switch on.
    const includesText = this.exportTextEnabled;
    const notes = includesText ? this.notes() : [];
    const body = {
      format: "waggle-usage-export-1",
      exported_at: new Date().toISOString(),
      install_id: this.installId(),
      app_version: versions.app,
      plugin_version: versions.plugin,
      macos_version: versions.macos,
      token_estimate: { bytes_per_token: BYTES_PER_TOKEN, tokens_per_image: TOKENS_PER_IMAGE },
      tool_calls: calls,
      usage_events: events,
      includes_text: includesText,
      ...(includesText ? { notes } : {}),
    };
    mkdirSync(dirname(jsonPath), { recursive: true });
    writeFileSync(jsonPath, `${JSON.stringify(body, null, 2)}\n`, { mode: 0o600 });
    writeFileSync(csvPath, toCsv(calls), { mode: 0o600 });
    return {
      json_path: jsonPath,
      csv_path: csvPath,
      tool_calls: calls.length,
      usage_events: events.length,
      notes: notes.length,
    };
  }

  private logWriteError(err: unknown): void {
    try {
      mkdirSync(join(this.dataRoot, "logs"), { recursive: true, mode: 0o700 });
      appendFileSync(
        join(this.dataRoot, "logs", USAGE_LOG_FILE),
        `${new Date().toISOString()} tool call write failed: ${String(err)}\n`,
      );
    } catch {
      // Nothing left to do.
    }
  }
}

function setMarker(root: string, name: string, present: boolean): void {
  const path = join(root, name);
  if (!present) {
    rmSync(path, { force: true });
    return;
  }
  mkdirSync(root, { recursive: true, mode: 0o700 });
  writeFileSync(path, "", { mode: 0o600 });
}

const CSV_COLUMNS: (keyof ToolCallRow)[] = [
  "id",
  "at",
  "tool",
  "duration_ms",
  "wait_ms",
  "result",
  "session_id",
  "client_name",
  "case_id",
  "artifact_kind",
  "request_bytes",
  "response_bytes",
  "images",
  "tokens_written",
  "tokens_received",
  "ctx_input",
  "ctx_cache_read",
  "ctx_cache_creation",
  "ctx_output",
  "error_code",
];

function toCsv(rows: ToolCallRow[]): string {
  const cell = (v: unknown): string => (v === null || v === undefined ? "" : /[",\n]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
  return [CSV_COLUMNS.join(","), ...rows.map((r) => CSV_COLUMNS.map((c) => cell(r[c])).join(","))].join("\n") + "\n";
}

const usd = (v: number): string => `$${v.toFixed(v < 1 ? 3 : 2)}`;
const num = (v: number): string => v.toLocaleString("en-US");

// `waggle report --tools`: the same numbers the Usage section shows. With a cost view (`--cost`) it
// adds the dollar columns and the reference prices.
export function formatToolReport(s: UsageSummaryResult, cost?: CostView): string {
  const lines: string[] = [];
  lines.push("Nothing here leaves your Mac unless you send the exported file. Contains no text, titles or paths.");
  lines.push("");
  lines.push(`Tool calls, last ${s.days} ${s.days === 1 ? "day" : "days"}${s.record ? "" : " (recording is off)"}`);
  lines.push("");
  const dollars = (v: number | undefined): string => (cost === undefined ? "" : `, ${usd(v ?? 0)}`);
  if (s.calls === 0) {
    lines.push("  no tool calls");
  } else {
    lines.push(`Calls per tool (estimated tokens${cost ? ", estimated cost" : ""})`);
    for (const t of s.tools) {
      lines.push(
        `  ${t.tool}: ${t.calls} calls, ${num(t.tokens_written)} written, ${num(t.tokens_received)} received, ` +
          `${num(t.context_tokens)} context re-read${dollars(cost?.by_tool.get(t.tool))}`,
      );
    }
    lines.push("");
    lines.push(`Total: ${s.calls} calls${cost ? `, about ${usd(cost.total)}` : ""}`);
    lines.push(
      s.wait_share === null
        ? "Waiting (waggle_check): -"
        : `Waiting (waggle_check): ${s.wait_calls} calls${cost ? `, ${usd(cost.wait)}` : ""}, ${Math.round(s.wait_share * 100)}% of the tokens`,
    );
    lines.push(`Time spent waiting for you: ${Math.round(s.waited_s / 60)} min`);
    lines.push(`Calls with a measured context: ${s.context_measured_calls} of ${s.calls}`);
    lines.push("");
    lines.push("Failed calls by reason");
    if (!s.errors || s.errors.length === 0) lines.push("  none");
    for (const e of s.errors ?? []) lines.push(`  ${e.error_code} (${e.result}): ${e.calls} calls`);
    lines.push("");
    lines.push("Top sessions by tokens");
    for (const t of s.top_sessions) {
      lines.push(
        `  ${t.session_id.slice(0, 8)} (${t.client_name ?? "unknown"}): ${t.calls} calls, ${num(t.tokens)} tokens${dollars(cost?.by_session.get(t.session_id))}`,
      );
    }
  }
  lines.push("");
  let estimate = `Estimate: ${s.bytes_per_token} bytes per token, ${s.tokens_per_image} tokens per image.`;
  if (cost) {
    const p = cost.prices;
    estimate +=
      ` Prices per million tokens: input $${p.input_per_mtok}, output $${p.output_per_mtok}, ` +
      `cache read $${p.cache_read_per_mtok}, cache write $${p.cache_write_per_mtok}.`;
  }
  lines.push(estimate);
  return lines.join("\n") + "\n";
}
