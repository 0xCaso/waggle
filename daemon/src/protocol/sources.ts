// Sources on a request (WAG-354). An agent cites where a claim comes from; the daemon checks the
// session and marks each source seen, stated or an assumption. This module holds the wire shapes and
// the pure text helpers (markers). The check itself lives in sessions/sources-check.ts.
import { z } from "zod";

export const SOURCES_MAX = 24;
export const SOURCE_MARKERS_MAX = 8;
export const SOURCE_LABEL_MAX = 60;
export const SOURCE_NOTE_MAX = 300;
export const SOURCE_EXCERPT_MAX = 600;
const SOURCE_REF_MAX = 1000;

export const SOURCE_KINDS = [
  "file",
  "document",
  "image",
  "search",
  "history",
  "test",
  "database",
  "api",
  "tool",
  "design",
  "web",
  "agent",
  "you_said",
  "decision",
  "rule",
  "none",
] as const;
export const SourceKind = z.enum(SOURCE_KINDS);
export type SourceKind = z.infer<typeof SourceKind>;

const RefString = z.string().max(SOURCE_REF_MAX);

// What the daemon matches against the session. All fields optional; the kind says which one counts.
export const SourceRef = z.object({
  path: RefString.optional().describe("file, document, image, rule: the path you read. The end of the path is enough."),
  line: RefString.optional().describe("A line number or range, for the pill. Not checked."),
  command: RefString.optional().describe(
    "search, history, test, database, api: a part of the command or query you ran, as it was typed.",
  ),
  url: RefString.optional().describe("web, api: the address you fetched."),
  tool: RefString.optional().describe("tool, design, agent: a part of the tool name, or the helper's name."),
  case_id: RefString.optional().describe("decision: the Waggle case that holds the answer."),
});
export type SourceRef = z.infer<typeof SourceRef>;

export const SourceId = z
  .string()
  .min(1)
  .max(24)
  .regex(/^[a-z0-9_-]+$/, "a source id uses a to z, 0 to 9, - and _");

// One source as the agent sends it (waggle_ask and waggle_update `sources`).
export const SourceInput = z.object({
  id: SourceId.describe("A short id, unique in this ask. Cite it in a text as [[s:id]]."),
  kind: SourceKind.describe(
    "file, document, image, search, history, test, database, api, tool, design, web, agent, you_said, decision, rule, " +
      "or none for a guess or an assumption.",
  ),
  label: z
    .string()
    .trim()
    .min(1)
    .max(SOURCE_LABEL_MAX)
    .regex(/^[^\r\n]+$/, "a label is one line")
    .describe("The pill words, one line, 60 characters or less. Example: store.ts:412"),
  note: z.string().trim().min(1).max(SOURCE_NOTE_MAX).optional().describe("One or two plain sentences on what the source shows."),
  excerpt: z
    .string()
    .min(1)
    .optional()
    .describe("The quoted lines, query or command. 600 characters; Waggle cuts a longer one."),
  ref: SourceRef.optional().describe("What Waggle uses to find your call in the session."),
});
export type SourceInput = z.infer<typeof SourceInput>;

export const SourcesField = z
  .array(SourceInput)
  .min(1)
  .max(SOURCES_MAX)
  .superRefine((sources, ctx) => {
    const seen = new Set<string>();
    sources.forEach((s, i) => {
      if (seen.has(s.id)) ctx.addIssue({ code: "custom", message: `source id ${s.id} is used twice`, path: [i, "id"] });
      seen.add(s.id);
    });
  })
  .describe(
    "Optional. Up to 24 sources: what you read, ran or were told. Cite one in a text with [[s:id]] after a sentence. " +
      "Cite what you read; use kind none for a guess. Waggle checks the session and marks each source seen or stated. " +
      "Call waggle_guide({ topic: \"writing-an-ask\" }) for the kinds.",
  );

// seen: Waggle found the matching call. stated: the agent says so, no call found. assumption: kind none.
export const SourceState = z.enum(["seen", "stated", "assumption"]);
export type SourceState = z.infer<typeof SourceState>;

// A source as stored and served: the input plus the check result. Nothing from the transcript.
export const Source = SourceInput.extend({
  state: SourceState,
  seen_at: z.string().optional(),
});
export type Source = z.infer<typeof Source>;

// ---------- markers ----------

const MARKER = /\[\[s:([^\]\n]*)\]\]/g;

// Every `[[s:ID]]` or `[[s:ID,ID2]]` in a text, with its ids.
function markerIds(raw: string): string[] {
  return raw
    .split(",")
    .map((id) => id.trim())
    .filter((id) => id !== "");
}

// A one-line place (queue row, chat message, Context card) shows plain words: the markers go, and the
// space in front of one goes with it.
export function stripSourceMarkers(text: string): string {
  if (!text.includes("[[s:")) return text;
  return text.replace(/[ \t]*\[\[s:[^\]\n]*\]\]/g, "");
}

export interface MarkerReport {
  // Every marker found, known or not.
  count: number;
  // Ids a marker named that no source has.
  unknown: string[];
  // Ids that a kept marker cites (WAG-359).
  cited: string[];
}

// Removes the markers that name an unknown id (or no id) and keeps the rest. A marker with known and
// unknown ids keeps only the known ones.
export function dropUnknownMarkers(text: string, known: ReadonlySet<string>, report: MarkerReport): string {
  if (!text.includes("[[s:")) return text;
  return text.replace(/([ \t]*)\[\[s:([^\]\n]*)\]\]/g, (_all, space: string, raw: string) => {
    report.count += 1;
    const ids = markerIds(raw);
    const kept = ids.filter((id) => known.has(id));
    for (const id of ids) if (!known.has(id) && !report.unknown.includes(id)) report.unknown.push(id);
    if (ids.length === 0 && !report.unknown.includes("")) report.unknown.push("");
    for (const id of kept) if (!report.cited.includes(id)) report.cited.push(id);
    return kept.length === 0 ? "" : `${space}[[s:${kept.join(",")}]]`;
  });
}

// The one warning line for a whole ask or update, or null.
export function markerWarning(report: MarkerReport): string | null {
  const parts: string[] = [];
  const unknown = report.unknown.filter((id) => id !== "");
  if (unknown.length > 0 || report.unknown.includes("")) {
    parts.push(
      unknown.length > 0
        ? `Waggle removed source markers with an unknown id (${unknown.join(", ")}). Send each cited source in sources.`
        : "Waggle removed an empty source marker.",
    );
  }
  if (report.count > SOURCE_MARKERS_MAX) {
    parts.push(`This ask has ${report.count} source markers. Use at most ${SOURCE_MARKERS_MAX}.`);
  }
  return parts.length > 0 ? parts.join(" ") : null;
}

// WAG-359: a source that no text cites shows only at the end of the why text. One warning line, or null.
export function uncitedWarning(sourceIds: readonly string[], report: MarkerReport): string | null {
  const ids = sourceIds.filter((id) => !report.cited.includes(id));
  if (ids.length === 0) return null;
  const list = ids.join(", ");
  return ids.length === 1
    ? `Source ${list} is in sources but no text cites it. Put [[s:id]] after the sentence it supports.`
    : `Sources ${list} are in sources but no text cites them. Put [[s:id]] after the sentence each one supports.`;
}

// The excerpt is cut at 600 characters, never refused.
export function clampExcerpt(excerpt: string): string {
  return excerpt.length > SOURCE_EXCERPT_MAX ? `${excerpt.slice(0, SOURCE_EXCERPT_MAX - 1)}…` : excerpt;
}

// Text fields of an ask or update that may carry markers.
export function mapMarkedText<T extends object>(input: T, fn: (text: string) => string): T {
  const out: any = { ...input };
  const text = (v: unknown): any => (typeof v === "string" ? fn(v) : v);
  // A pro or con is a string or { gist, detail } (option card "Gist and facts"); both texts may carry markers.
  const point = (p: any): any =>
    p !== null && typeof p === "object" ? { ...p, gist: text(p.gist), detail: text(p.detail) } : text(p);
  const option = (o: any): any => ({
    ...o,
    label: text(o.label),
    ...(o.pros !== undefined ? { pros: o.pros.map(point) } : {}),
    ...(o.cons !== undefined ? { cons: o.cons.map(point) } : {}),
    ...(o.effects !== undefined ? { effects: o.effects.map(text) } : {}),
  });
  for (const key of ["need", "why", "recommendation_why", "message"]) if (key in out) out[key] = text(out[key]);
  if (Array.isArray(out.options)) out.options = out.options.map(option);
  if (Array.isArray(out.items)) {
    out.items = out.items.map((item: any) => ({
      ...item,
      ...(item.question !== undefined ? { question: text(item.question) } : {}),
      ...(item.recommendation_why !== undefined ? { recommendation_why: text(item.recommendation_why) } : {}),
      ...(Array.isArray(item.options) ? { options: item.options.map(option) } : {}),
    }));
  }
  return out;
}
