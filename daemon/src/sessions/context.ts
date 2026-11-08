// What a live Claude Code session is working on (HAIL-72). Read from the
// Claude Code transcript (a .jsonl file) and from git, nothing else. Local
// only: no network. The transcript format is not documented, so every read is
// defensive: unknown records are ignored, and a failure gives `null`, never an
// error (`sessions.list` must always answer).
import { closeSync, existsSync, openSync, readdirSync, readSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { canonicalToolName, stripSourceMarkers, type LiveState, type SessionChanges, type SessionContext } from "../protocol";

const HEAD_BYTES = 256 * 1024; // holds the first real prompt
export const TAIL_BYTES = 2 * 1024 * 1024; // holds the last plan, actions and title
const GROWING_MS = 120_000; // a transcript written in the last 2 minutes is "still growing"
const CACHE_MAX = 64;

type Json = Record<string, any>;

// ---------- finding the transcript ----------

// Claude Code names a project folder after the cwd, every non-alphanumeric
// character replaced by "-".
export function cwdSlug(cwd: string): string {
  return cwd.replace(/[^A-Za-z0-9]/g, "-");
}

// `KNOCK_CLAUDE_PROJECTS` overrides the folder. Tests set it, so no test reads
// the real ~/.claude.
export function projectsRoot(): string {
  return process.env.KNOCK_CLAUDE_PROJECTS || join(process.env.HOME || homedir(), ".claude", "projects");
}

export interface FoundTranscript {
  path: string;
  how: "session-id" | "cwd-newest";
}

// The shim's session id IS the Claude Code session id when the environment
// variable CLAUDE_CODE_SESSION_ID is set, so `<id>.jsonl` is the exact file.
// Otherwise (a shim that had to make up a UUID) fall back to the newest file
// in the cwd's folder that is still growing.
export function findTranscript(
  sessionId: string,
  cwd: string,
  root: string = projectsRoot(),
  now: number = Date.now(),
): FoundTranscript | null {
  if (!cwd) return null;
  const dir = join(root, cwdSlug(cwd));
  try {
    if (/^[A-Za-z0-9_-]+$/.test(sessionId)) {
      const exact = join(dir, `${sessionId}.jsonl`);
      if (existsSync(exact)) return { path: exact, how: "session-id" };
    }
    let best: { path: string; mtimeMs: number } | null = null;
    for (const name of readdirSync(dir)) {
      if (!name.endsWith(".jsonl")) continue;
      const path = join(dir, name);
      const st = statSync(path);
      if (st.size === 0 || now - st.mtimeMs > GROWING_MS) continue;
      if (!best || st.mtimeMs > best.mtimeMs) best = { path, mtimeMs: st.mtimeMs };
    }
    return best ? { path: best.path, how: "cwd-newest" } : null;
  } catch {
    return null;
  }
}

// ---------- reading ----------

export function readSlice(path: string, start: number, len: number): string {
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.alloc(len);
    const n = readSync(fd, buf, 0, len, start);
    return buf.subarray(0, n).toString("utf8");
  } finally {
    closeSync(fd);
  }
}

// A cut edge or an unknown format gives a line that is not JSON: skip it.
export function parseLines(text: string, dropFirst: boolean, dropLast: boolean): Json[] {
  const lines = text.split("\n");
  if (dropFirst) lines.shift();
  if (dropLast) lines.pop();
  const out: Json[] = [];
  for (const line of lines) {
    if (!line) continue;
    try {
      const rec = JSON.parse(line);
      if (rec && typeof rec === "object") out.push(rec);
    } catch {
      // partial line or unknown format
    }
  }
  return out;
}

// ---------- cleaning ----------

// Agent text is shown as plain text: markers stripped, one line.
export function plain(s: string): string {
  return stripSourceMarkers(s)
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, " ")
    .replace(/<(command-[a-z]+|local-command-[a-z]+)>[\s\S]*?<\/\1>/g, " ")
    .replace(/\[Image #\d+\]/g, " ")
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/^\s*(?:[-*+]|\d+[.)])\s+/gm, "")
    .replace(/^\s*#{1,6}\s+/gm, "")
    .replace(/[`*_#>]+/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

export function clamp(s: string, n: number): string {
  return s.length <= n ? s : s.slice(0, n - 1).replace(/\s+\S*$/, "") + "…";
}

export function firstSentence(s: string, max = 140): string {
  const m = s.match(/^.*?[.!?](?=\s|$)/);
  return clamp(m ? m[0] : s, max);
}

// The raw text of a real human prompt, or null (tool results, hooks, notices).
export function humanRaw(r: Json): string | null {
  if (r.type !== "user" || r.isMeta || r.isSidechain) return null;
  // "human" is typed in the terminal, "sdk" is sent by a host app.
  if (r.turnOrigin && r.turnOrigin !== "human" && r.turnOrigin !== "sdk") return null;
  const c = r.message?.content;
  let text = "";
  if (typeof c === "string") text = c;
  else if (Array.isArray(c)) {
    if (c.some((b: Json) => b?.type === "tool_result")) return null;
    text = c
      .filter((b: Json) => b?.type === "text" && typeof b.text === "string")
      .map((b: Json) => b.text)
      .join("\n");
  }
  const args = text.match(/<command-args>([\s\S]*?)<\/command-args>/)?.[1];
  const name = text.match(/<command-name>([\s\S]*?)<\/command-name>/)?.[1];
  if (args !== undefined) text = `${name ?? ""} ${args}`;
  if (/^\s*<(task-notification|local-command|system-reminder)/.test(text)) return null;
  const t = plain(text);
  if (t.length < 4) return null;
  if (/^(\[?request interrupted|caveat:)/i.test(t)) return null;
  return text;
}

// What a prompt is about (HAIL-124). A headless session (a fleet brief) has no
// `ai-title` and its prompt starts with headings and fences. An `Objective:`
// line wins; else the prompt with headings, fenced code and empty lines left out.
export function goalOf(raw: string): string | null {
  const cleaned = raw
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "\n")
    .replace(/<(command-[a-z]+|local-command-[a-z]+)>[\s\S]*?<\/\1>/g, "\n");
  const objective = cleaned.match(/^[ \t>*_-]*Objective\s*:\**[ \t]*(\S.*)$/im)?.[1];
  const fromObjective = objective ? plain(objective) : "";
  if (fromObjective.length >= 4) return fromObjective;
  const kept: string[] = [];
  let fenced = false;
  for (const line of cleaned.split("\n")) {
    if (/^\s*(```|~~~)/.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (fenced || !line.trim() || /^\s*#{1,6}(\s|$)/.test(line)) continue;
    kept.push(line);
  }
  const t = plain(kept.join("\n"));
  return t.length >= 4 ? t : null;
}

// ---------- the action trail, in plain words ----------

const base = (p?: unknown) => (typeof p === "string" && p ? p.split("/").pop()! : "a file");

// "fleet board 2>&1 | grep -E ..." -> "Ran fleet board". Drops pipes,
// redirects, flags, paths and quoted text.
// "perl -e 'alarm 1200; exec @ARGV' swift test", "env A=1 x", "timeout 30 x" and
// "bash -c 'x'" run another command. Peel the wrapper so the real command shows.
const QUOTED = `(?:'([^']*)'|"([^"]*)")`;
export function unwrapCommand(input: string): string {
  let cmd = input.trim();
  for (let i = 0; i < 8; i++) {
    const before = cmd;
    cmd = cmd.replace(/^(?:cd\s+\S+|export\s+\S+)\s*(?:&&|;)\s*/, "");
    cmd = cmd.replace(/^(?:\S*\/)?env\s+(?:-[uCS]\s+\S+\s+|-\S+\s+|\w+=\S*\s+)*/, "");
    cmd = cmd.replace(/^(?:\S*\/)?timeout\s+(?:-\S+\s+)*\d+[smhd]?\s+/, "");
    cmd = cmd.replace(new RegExp(`^(?:\\S*/)?perl\\s+-e\\s+${QUOTED}\\s*`), "");
    const sh = cmd.match(new RegExp(`^(?:\\S*/)?(?:ba|z)?sh\\s+(?:-\\w*c\\w*)\\s+${QUOTED}`));
    if (sh) cmd = (sh[1] ?? sh[2] ?? "").trim();
    cmd = cmd.replace(/^exec\s+/, "").trim();
    if (cmd === before) break;
  }
  return cmd;
}

export function humanizeCommand(raw: string): string {
  const cmd = unwrapCommand(raw);
  if (/<<\s*['"]?\w+/.test(cmd) || /^\s*python3?\s+-/.test(cmd)) return "Ran a small script";
  const segment =
    cmd
      .split(/\s*(?:&&|\|\||\||;|\n)\s*/)
      .map((s) => s.trim())
      .filter((s) => s && !/^(cd|export|set|sleep|source|true|:)\b/.test(s))[0] ?? "";
  // Words up to the first flag: a flag's value ("--filter Foo") is not a subcommand.
  const words: string[] = [];
  for (const w of segment.replace(/\d*>&?\s*\S+/g, " ").replace(/["'].*$/, " ").split(/\s+/)) {
    if (w.startsWith("-")) break;
    if (w && !w.includes("=") && !w.startsWith("<") && !w.startsWith("$")) words.push(w);
  }
  if (!words.length) return "Ran a command";
  const program = basename(words[0]);
  const rest = words.slice(1).filter((w) => /^[A-Za-z][\w.:]*$/.test(w));
  return `Ran ${[program, ...rest.slice(0, 2)].join(" ")}`;
}

export function humanizeTool(name: string, input: Json): string | null {
  switch (name) {
    case "Edit":
    case "MultiEdit":
      return `Edited ${base(input.file_path)}`;
    case "Write":
      return `Wrote ${base(input.file_path)}`;
    case "Read":
      return `Read ${base(input.file_path)}`;
    case "NotebookEdit":
      return `Edited ${base(input.notebook_path)}`;
    case "Grep":
      return `Searched for "${clamp(String(input.pattern ?? ""), 28)}"`;
    case "Glob":
      return `Looked for ${clamp(String(input.pattern ?? "files"), 30)}`;
    case "WebFetch":
    case "WebSearch":
      return "Looked something up on the web";
    case "Agent":
    case "Task":
      return `Started a helper: ${clamp(String(input.description ?? "subtask"), 40)}`;
    case "Skill":
      return `Used the ${input.skill ?? "a"} skill`;
    case "TodoWrite":
    case "TaskCreate":
    case "TaskUpdate":
    case "ToolSearch":
    case "SendMessage":
    case "TaskStop":
      return null; // bookkeeping, not an action
    case "Bash": {
      const why = plain(String(input.description ?? ""));
      if (why) return clamp(why, 56);
      return clamp(humanizeCommand(String(input.command ?? "")), 56);
    }
    default:
      // The plugin's server is named plugin:waggle:waggle, so its tools read mcp__plugin_waggle_waggle__*
      // (HAIL-134). While the legacy aliases are on, the old plugin:knock:knock names and the old
      // knock_* tool names read the same (HAIL-176).
      name = name.replace(/^mcp__plugin_(?:waggle_waggle|knock_knock)__/, "mcp__waggle__").replace(/^mcp__knock__/, "mcp__waggle__");
      const tool = name.replace(/^mcp__waggle__/, "");
      const canonical = name === tool ? null : canonicalToolName(tool);
      if (canonical === "waggle_ask") return `Needs your decision: ${clamp(String(input.title ?? ""), 44)}`;
      if (canonical === "waggle_check") return "Waited for your answer";
      if (canonical === "waggle_update") return "Sent you an update";
      if (name.startsWith("mcp__")) return `Used ${name.split("__").slice(1).join(" / ")}`;
      return `Used ${name}`;
  }
}

// ---------- the plan ----------

type Todo = { text: string; status: "done" | "doing" | "todo" };

function foldPlan(records: Json[]): SessionContext["plan"] {
  let todos: Todo[] | null = null;
  const tasks = new Map<string, Todo>();
  for (const r of records) {
    if (r.type !== "assistant") continue;
    const blocks = r.message?.content;
    if (!Array.isArray(blocks)) continue;
    for (const b of blocks) {
      if (b?.type !== "tool_use") continue;
      if (b.name === "TodoWrite" && Array.isArray(b.input?.todos)) {
        todos = b.input.todos.map((t: Json) => ({
          text: String(t.status === "in_progress" && t.activeForm ? t.activeForm : t.content),
          status: t.status === "completed" ? "done" : t.status === "in_progress" ? "doing" : "todo",
        }));
      } else if (b.name === "TaskCreate") {
        tasks.set(String(b.id), { text: String(b.input?.subject ?? b.input?.title ?? "task"), status: "todo" });
      } else if (b.name === "TaskUpdate") {
        const t = tasks.get(String(b.input?.taskId ?? b.input?.id));
        if (t && b.input?.status) {
          t.status = b.input.status === "completed" ? "done" : b.input.status === "in_progress" ? "doing" : "todo";
        }
      }
    }
  }
  if (tasks.size) todos = [...tasks.values()];
  if (!todos || !todos.length) return null;
  const current = todos.find((t) => t.status === "doing") ?? todos.find((t) => t.status === "todo");
  return {
    done: todos.filter((t) => t.status === "done").length,
    total: todos.length,
    current: current ? clamp(plain(current.text), 60) : null,
  };
}

// ---------- one transcript ----------

export type TranscriptFacts = Omit<SessionContext, "changes">;

export function parseTranscriptText(head: Json[], tail: Json[]): TranscriptFacts {
  const titleOf = (recs: Json[]) =>
    recs
      .filter((r) => r.type === "ai-title" && typeof r.aiTitle === "string" && r.aiTitle.trim())
      .map((r) => plain(r.aiTitle as string))
      .at(-1) ?? null;
  const title = titleOf(tail) ?? titleOf(head);
  const goalText =
    head
      .map((r) => {
        const raw = humanRaw(r);
        return raw === null ? null : goalOf(raw);
      })
      .find((p) => p) ?? null;

  const actions: { at: string | null; text: string }[] = [];
  let said: string | null = null;
  for (const r of tail) {
    if (r.type !== "assistant" || r.isSidechain) continue;
    const blocks = r.message?.content;
    if (!Array.isArray(blocks)) continue;
    for (const b of blocks) {
      if (b?.type === "tool_use" && typeof b.name === "string") {
        const v = humanizeTool(b.name, b.input && typeof b.input === "object" ? b.input : {});
        if (v && actions.at(-1)?.text !== v) actions.push({ at: typeof r.timestamp === "string" ? r.timestamp : null, text: v });
      } else if (b?.type === "text" && typeof b.text === "string") {
        const t = plain(b.text);
        if (t.length >= 8) said = t;
      }
    }
  }
  const recent = actions.slice(-3).map((a) => a.text);
  const last = actions.at(-1) ?? null;
  const facts: TranscriptFacts = {
    title: title ? clamp(title, 90) : null,
    goal: goalText ? clamp(goalText, 110) : null,
    said: said ? firstSentence(said) : null,
    last_action: last?.text ?? null,
    last_action_at: last?.at ?? null,
    recent,
    plan: foldPlan(tail),
  };
  return facts;
}

const transcriptCache = new Map<string, { size: number; mtimeMs: number; facts: TranscriptFacts }>();

export function readTranscript(path: string): TranscriptFacts | null {
  try {
    const st = statSync(path);
    const hit = transcriptCache.get(path);
    if (hit && hit.size === st.size && hit.mtimeMs === st.mtimeMs) return hit.facts;
    const { size } = st;
    const head = parseLines(readSlice(path, 0, Math.min(HEAD_BYTES, size)), false, size > HEAD_BYTES);
    const tail =
      size <= TAIL_BYTES
        ? size <= HEAD_BYTES
          ? head
          : parseLines(readSlice(path, 0, size), false, false)
        : parseLines(readSlice(path, size - TAIL_BYTES, TAIL_BYTES), true, false);
    const facts = parseTranscriptText(head, tail);
    if (transcriptCache.size >= CACHE_MAX) transcriptCache.delete(transcriptCache.keys().next().value!);
    transcriptCache.set(path, { size, mtimeMs: st.mtimeMs, facts });
    return facts;
  } catch {
    return null;
  }
}

// ---------- the entry point ----------

// "Still growing" (HAIL-124): the transcript was written in the last GROWING_MS,
// or the last action is under 2 minutes old. A session with no open ask that
// is growing is busy, not idle.
export function isGrowing(path: string, lastActionAt: string | null, now: number): boolean {
  try {
    if (now - statSync(path).mtimeMs <= GROWING_MS) return true;
  } catch {
    // fall through to the action time
  }
  const at = lastActionAt ? Date.parse(lastActionAt) : NaN;
  return Number.isFinite(at) && now - at <= GROWING_MS;
}

export interface ContextInput {
  id: string;
  cwd: string;
  runtime: string;
  state: string;
}

// The context of one session, or null: not a live Claude Code session, no
// transcript found and no live state, or nothing worth showing. Never throws.
//
// HAIL-134: `opts.live` is what the session's mod reported, passed only while
// it is fresh. It wins over the transcript for busy or idle (`growing`) and fills
// the last action when the transcript has none. Without it, or when it is stale,
// the transcript reading stands as before.
export async function sessionContext(
  s: ContextInput,
  opts: { root?: string; now?: number; live?: LiveState | null; changes?: SessionChanges | null } = {},
): Promise<SessionContext | null> {
  try {
    // HAIL-137: a Codex session has no transcript reading, only what its hooks reported.
    const live = opts.live ?? null;
    if (s.state !== "live" || (s.runtime !== "claude" && !live)) return null;
    const found = s.runtime === "claude" ? findTranscript(s.id, s.cwd, opts.root, opts.now) : null;
    const facts = found ? readTranscript(found.path) : null;
    if (!facts && !live) return null;
    // HAIL-222: the git footprint comes from the shim (session.hello). The daemon never runs git on the cwd.
    const changes = opts.changes ?? null;
    const now = opts.now ?? Date.now();
    const base: TranscriptFacts = facts ?? {
      title: null,
      goal: null,
      said: null,
      last_action: null,
      last_action_at: null,
      recent: [],
      plan: null,
    };
    const ctx: SessionContext = {
      ...base,
      changes,
      growing: live ? live.phase === "working" : found ? isGrowing(found.path, base.last_action_at, now) : false,
    };
    if (live) {
      ctx.live = live;
      if (!ctx.last_action && live.last_tool) {
        const said = humanizeTool(live.last_tool, {});
        if (said) {
          ctx.last_action = said;
          ctx.last_action_at = live.last_tool_at;
          ctx.recent = [said];
        }
      }
    }
    const empty = !ctx.title && !ctx.goal && !ctx.said && !ctx.last_action && !ctx.plan && !ctx.changes && !ctx.live;
    return empty ? null : ctx;
  } catch {
    return null;
  }
}
