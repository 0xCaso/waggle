// The check for sources on a request (WAG-354): "Agent cites, Waggle checks". For each cited source the
// daemon looks for the matching call in the session's Claude Code transcript, made before the ask.
// It reads at most the tail the Context card reads, with the same defensive reading, and keeps only the
// result (`state`, `seen_at`). It never stores transcript content, never throws and makes no network call.
import { statSync } from "node:fs";
import { clampExcerpt, type Source, type SourceInput, type SourceKind } from "../protocol";
import { findTranscript, humanRaw, parseLines, plain, readSlice, TAIL_BYTES } from "./context";

type Json = Record<string, any>;

interface Call {
  at: string | null;
  name: string;
  input: Json;
}

interface Said {
  at: string | null;
  text: string;
}

export interface TranscriptCalls {
  calls: Call[];
  said: Said[];
}

export interface CheckEnv {
  sessionId: string;
  cwd: string;
  // False when a switch forbids reading the transcript (the usage switches). Every source is then stated.
  transcriptAllowed: boolean;
  // The ISO time of the ask: only calls made before it count.
  askedAt: string;
  // The time a case got a reply, or null when it has none or does not exist (kind decision).
  decisionRepliedAt: (caseId: string) => string | null;
  root?: string;
}

const WAGGLE_TOOL = /^mcp__(?:plugin_(?:waggle_waggle|knock_knock)|waggle|knock)__/;
const SHELL_SEARCH = /(?:^|[\s;&|(])(?:grep|egrep|rg)\s/;

// The calls and user messages of a transcript, newest last. Sidechain records (a helper's own work)
// are left out, as the Context card leaves them out.
export function callsOf(records: Json[], askedAt: string): TranscriptCalls {
  const calls: Call[] = [];
  const said: Said[] = [];
  for (const r of records) {
    if (r.isSidechain) continue;
    const at = typeof r.timestamp === "string" ? r.timestamp : null;
    if (at !== null && at > askedAt) continue;
    if (r.type === "assistant") {
      const blocks = r.message?.content;
      if (!Array.isArray(blocks)) continue;
      for (const b of blocks) {
        if (b?.type !== "tool_use" || typeof b.name !== "string" || WAGGLE_TOOL.test(b.name)) continue;
        calls.push({ at, name: b.name, input: b.input && typeof b.input === "object" ? b.input : {} });
      }
    } else if (r.type === "user") {
      const raw = humanRaw(r);
      if (raw !== null) said.push({ at, text: raw });
    }
  }
  return { calls, said };
}

// The tail of the transcript, parsed, or null. The same slice the Context card reads.
function readTail(path: string): Json[] | null {
  try {
    const { size } = statSync(path);
    return size <= TAIL_BYTES
      ? parseLines(readSlice(path, 0, size), false, false)
      : parseLines(readSlice(path, size - TAIL_BYTES, TAIL_BYTES), true, false);
  } catch {
    return null;
  }
}

const strings = (input: Json): string => Object.values(input).filter((v): v is string => typeof v === "string").join("\n");
const command = (c: Call): string => (typeof c.input.command === "string" ? c.input.command : "");
const collapse = (s: string): string => s.replace(/\s+/g, " ").trim().toLowerCase();
const present = (s: string | undefined): s is string => typeof s === "string" && s.trim() !== "";

// The last matching time, "" when it matches without a time, or null for no match.
function newest<T extends { at: string | null }>(items: T[], test: (t: T) => boolean): string | null {
  let found: string | null = null;
  for (const item of items) {
    if (!test(item)) continue;
    found = item.at ?? found ?? "";
  }
  return found;
}

function matchKind(src: SourceInput, seen: TranscriptCalls): string | null {
  const ref = src.ref ?? {};
  const isShell = (c: Call): boolean => c.name === "Bash";
  switch (src.kind as SourceKind) {
    case "file":
    case "document":
    case "image":
    case "rule": {
      if (!present(ref.path)) return null;
      const want = ref.path.replace(/^\.\//, "");
      return newest(seen.calls, (c) => c.name === "Read" && typeof c.input.file_path === "string" && c.input.file_path.endsWith(want));
    }
    case "search": {
      if (!present(ref.command)) return null;
      return newest(
        seen.calls,
        (c) =>
          ((c.name === "Grep" || c.name === "Glob") && strings(c.input).includes(ref.command!)) ||
          (isShell(c) && SHELL_SEARCH.test(command(c)) && command(c).includes(ref.command!)),
      );
    }
    case "history":
    case "test":
    case "database":
    case "api": {
      const needles = [ref.command, src.kind === "api" ? ref.url : undefined].filter(present);
      if (needles.length === 0) return null;
      return newest(seen.calls, (c) => isShell(c) && needles.some((n) => command(c).includes(n)));
    }
    case "tool":
    case "design": {
      if (!present(ref.tool)) return null;
      const want = ref.tool.toLowerCase();
      return newest(seen.calls, (c) => c.name.toLowerCase().includes(want));
    }
    case "web": {
      if (!present(ref.url)) return null;
      return newest(seen.calls, (c) => (c.name === "WebFetch" || c.name === "WebSearch") && strings(c.input).includes(ref.url!));
    }
    case "agent": {
      const wants = [ref.tool, src.label].filter(present).map((w) => w.toLowerCase());
      return newest(seen.calls, (c) => {
        if (c.name !== "Agent" && c.name !== "Task") return false;
        const text = [c.input.subagent_type, c.input.description].filter((v) => typeof v === "string").join(" ").toLowerCase();
        return wants.some((w) => text.includes(w));
      });
    }
    case "you_said": {
      if (!present(src.excerpt)) return null;
      const want = collapse(src.excerpt).slice(0, 80);
      if (want === "") return null;
      return newest(seen.said, (m) => collapse(plain(m.text)).includes(want) || collapse(m.text).includes(want));
    }
    default:
      return null;
  }
}

// The result for each source, in the order given. Never throws: a failure gives `stated`.
export function checkSources(sources: SourceInput[], env: CheckEnv): Source[] {
  let seen: TranscriptCalls | null = null;
  try {
    if (env.transcriptAllowed) {
      const found = findTranscript(env.sessionId, env.cwd, env.root);
      const records = found ? readTail(found.path) : null;
      if (records) seen = callsOf(records, env.askedAt);
    }
  } catch {
    seen = null;
  }
  return sources.map((src): Source => {
    const base: SourceInput = { ...src, ...(src.excerpt !== undefined ? { excerpt: clampExcerpt(src.excerpt) } : {}) };
    try {
      if (src.kind === "none") return { ...base, state: "assumption" };
      let at: string | null = null;
      if (src.kind === "decision") {
        at = present(src.ref?.case_id) ? env.decisionRepliedAt(src.ref!.case_id!) : null;
      } else if (seen !== null) {
        at = matchKind(src, seen);
      }
      if (at === null) return { ...base, state: "stated" };
      return at === "" ? { ...base, state: "seen" } : { ...base, state: "seen", seen_at: at };
    } catch {
      return { ...base, state: "stated" };
    }
  });
}
