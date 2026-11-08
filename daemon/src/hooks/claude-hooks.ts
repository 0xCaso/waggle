import { closeSync, existsSync, fstatSync, mkdirSync, openSync, readFileSync, readSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { AskFrequency, AskReach, AskTopics } from "../protocol/rpc";
import { endsWithQuestionMark, isQuickQuestion, looksLikeQuestion, saysBlocked } from "./question-detector";

// WAG-265: the two Claude Code hooks the Waggle plugin registers in hooks/hooks.json. They run
// through `waggle mod claude-hook <Stop|SessionStart>`. The plugin's module API cannot express
// either one (a `turn.complete` hook cannot block the stop, and `session.start` has no matcher
// or context result), so they are plain command hooks.

// The data-root marker the daemon writes when "Catch questions in the terminal" is off.
// The hook reads the file itself, so the switch works with no daemon running.
export const CATCH_QUESTIONS_OFF_FILE = "catch-questions-off";

// WAG-273: the operator's Settings > Requests choices, as a small file in the data root. The daemon
// rewrites it when one of them changes, so the hook follows them with no daemon running. A missing
// or broken file means "ask for everything", which is how the hook worked before.
export const ASK_PREFS_FILE = "ask-prefs.json";

export type HookAskPrefs = { reach: AskReach; topics: AskTopics; frequency: AskFrequency };

export function writeHookAskPrefs(home: string, prefs: HookAskPrefs): void {
  mkdirSync(home, { recursive: true, mode: 0o700 });
  writeFileSync(join(home, ASK_PREFS_FILE), JSON.stringify(prefs), { mode: 0o600 });
}

export function readHookAskPrefs(home: string): HookAskPrefs | undefined {
  try {
    const raw = JSON.parse(readFileSync(join(home, ASK_PREFS_FILE), "utf8"));
    const reach = AskReach.safeParse(raw?.reach);
    const topics = AskTopics.safeParse(raw?.topics);
    const frequency = AskFrequency.safeParse(raw?.frequency);
    if (!reach.success || !topics.success || !frequency.success) return undefined;
    return { reach: reach.data, topics: topics.data, frequency: frequency.data };
  } catch {
    return undefined;
  }
}

// Does this question belong in Waggle under the operator's Requests choices?
export function wantedInWaggle(message: string | undefined, prefs: HookAskPrefs | undefined): boolean {
  if (!prefs) return true;
  if (prefs.reach === "off") return false;
  if (prefs.frequency === "blocked" && !saysBlocked(message)) return false;
  const narrow = prefs.reach === "visual" || prefs.reach === "written" || prefs.topics.scope === "pick";
  if (narrow && isQuickQuestion(message)) return false;
  return true;
}

export const STOP_REASON =
  "If this is a new decision, send it with waggle_ask (options and a recommendation). If the person already answered in Waggle or asked for your opinion, just reply.";

export const RESUME_REMINDER =
  "Ask the human through waggle_ask, never in the terminal. Call waggle_guide if you need the details.";

// The SessionStart sources that get the reminder. A fresh start gets nothing: the MCP
// instructions already cover it.
export const REMINDER_SOURCES: readonly string[] = ["compact", "resume"];

export function catchQuestionsEnabled(home: string): boolean {
  return !existsSync(join(home, CATCH_QUESTIONS_OFF_FILE));
}

// The last lines of a transcript (JSONL), parsed. Reads only the tail of the file. Anything
// unreadable gives an empty list.
type TranscriptEntry = {
  type?: string;
  uuid?: string;
  timestamp?: string;
  isMeta?: boolean;
  message?: { role?: string; content?: unknown };
};

function transcriptTail(transcriptPath: string, maxBytes = 512 * 1024): TranscriptEntry[] {
  let fd: number | undefined;
  try {
    fd = openSync(transcriptPath, "r");
    const size = fstatSync(fd).size;
    const start = Math.max(0, size - maxBytes);
    const buffer = Buffer.alloc(size - start);
    readSync(fd, buffer, 0, buffer.length, start);
    const lines = buffer.toString("utf8").split("\n");
    if (start > 0) lines.shift(); // the first line may be cut
    const entries: TranscriptEntry[] = [];
    for (const raw of lines) {
      const line = raw.trim();
      if (!line) continue;
      try {
        const entry = JSON.parse(line);
        if (entry && typeof entry === "object") entries.push(entry);
      } catch {
        // a broken line is skipped
      }
    }
    return entries;
  } catch {
    return [];
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function blocks(entry: TranscriptEntry): { type?: string; text?: string; name?: string }[] {
  const content = entry.message?.content;
  return Array.isArray(content) ? content.filter((b) => b && typeof b === "object") : [];
}

function textOf(entry: TranscriptEntry): string {
  const content = entry.message?.content;
  if (typeof content === "string") return content;
  return blocks(entry)
    .filter((b) => b.type === "text" && typeof b.text === "string")
    .map((b) => b.text as string)
    .join("\n\n");
}

const isAssistant = (e: TranscriptEntry) => e.type === "assistant" || e.message?.role === "assistant";

// A real person prompt: a user entry with text, not a tool result and not a meta line.
const isPrompt = (e: TranscriptEntry) =>
  (e.type === "user" || e.message?.role === "user") && !e.isMeta && textOf(e).trim() !== "";

// The text of the last assistant message in a Claude Code transcript (JSONL). Anything
// unreadable gives undefined.
export function lastAssistantText(transcriptPath: string, maxBytes = 512 * 1024): string | undefined {
  const entries = transcriptTail(transcriptPath, maxBytes);
  for (let i = entries.length - 1; i >= 0; i--) {
    if (!isAssistant(entries[i])) continue;
    const text = textOf(entries[i]);
    if (text.trim() !== "") return text;
  }
  return undefined;
}

// WAG-332: the Waggle tools that mean the agent already handled the question in Waggle.
const WAGGLE_CALL = /(?:^|__)(?:waggle|knock)_(?:ask|update|check)$/;

export const RECENT_WAGGLE_MS = 5 * 60 * 1000;

export type TranscriptFacts = {
  promptId?: string; // the last person prompt: its uuid, else its timestamp, else its text
  promptText?: string;
  turnCalledWaggle: boolean; // a Waggle tool call after that prompt
  lastWaggleAt?: number; // ms of the newest Waggle tool call in the tail
};

export function transcriptFacts(transcriptPath: string): TranscriptFacts {
  const entries = transcriptTail(transcriptPath);
  let promptIndex = -1;
  for (let i = entries.length - 1; i >= 0; i--) {
    if (isPrompt(entries[i])) {
      promptIndex = i;
      break;
    }
  }
  const prompt = promptIndex >= 0 ? entries[promptIndex] : undefined;
  let turnCalledWaggle = false;
  let lastWaggleAt: number | undefined;
  entries.forEach((entry, i) => {
    if (!isAssistant(entry)) return;
    if (!blocks(entry).some((b) => b.type === "tool_use" && typeof b.name === "string" && WAGGLE_CALL.test(b.name))) return;
    if (i > promptIndex) turnCalledWaggle = true;
    const at = Date.parse(entry.timestamp ?? "");
    if (Number.isFinite(at) && (lastWaggleAt === undefined || at > lastWaggleAt)) lastWaggleAt = at;
  });
  const promptText = prompt ? textOf(prompt) : undefined;
  return { promptId: prompt ? (prompt.uuid ?? prompt.timestamp ?? promptText) : undefined, promptText, turnCalledWaggle, lastWaggleAt };
}

// Does the person's prompt ask a question or for an opinion? Deliberately simple.
const QUESTION_OPENERS = /^(?:what|which|how|why|when|where|who|should|can|could|would|do|does|did|is|are|any|thoughts)\b/i;
const OPINION_ASK = /\b(?:your (?:opinion|take|view|thoughts)|what do you think|do you think|thoughts\?|tell me)\b/i;

export function promptAsksQuestion(prompt: string | undefined): boolean {
  if (typeof prompt !== "string" || prompt.trim() === "") return false;
  const trimmed = prompt.trim();
  const lastLine = trimmed.split(/\n\s*\n/).pop() ?? trimmed;
  return endsWithQuestionMark(lastLine) || QUESTION_OPENERS.test(trimmed) || OPINION_ASK.test(trimmed);
}

// A direct question to the person: the message's last paragraph ends in a question mark and
// speaks to "you" or offers to act ("Should I...?").
export function endsWithDirectQuestion(message: string): boolean {
  const paragraphs = message.replace(/```[\s\S]*?(?:```|$)/g, "").split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
  const last = paragraphs[paragraphs.length - 1] ?? "";
  return endsWithQuestionMark(last) && /\b(?:you|your|you'd|you're|should i|shall i|want me|can i|may i)\b/i.test(last);
}

// WAG-332: the last prompt we blocked, per session, so one prompt gets one block even across
// separate stop chains.
export const STOP_BLOCKED_FILE = "stop-blocked.json";

function readBlocked(home: string): Record<string, string> {
  try {
    const raw = JSON.parse(readFileSync(join(home, STOP_BLOCKED_FILE), "utf8"));
    return raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  } catch {
    return {};
  }
}

function writeBlocked(home: string, session: string, promptId: string): void {
  try {
    const all = readBlocked(home);
    delete all[session];
    const keep = Object.entries(all).slice(-49); // newest 49 plus this one
    mkdirSync(home, { recursive: true, mode: 0o700 });
    writeFileSync(join(home, STOP_BLOCKED_FILE), JSON.stringify({ ...Object.fromEntries(keep), [session]: promptId }), {
      mode: 0o600,
    });
  } catch {
    // best effort: the block still goes out
  }
}

export type StopInput = {
  stop_hook_active?: unknown;
  last_assistant_message?: unknown;
  transcript_path?: unknown;
  session_id?: unknown;
};

// Block at most once per stop chain, only for a question, only with the switch on, and never
// while the session has an ask open. `hasOpenAsk` is asked last, so a status report costs no
// daemon call. A throw anywhere means "let it stop".
export async function stopDecision(opts: {
  input: StopInput;
  home: string;
  hasOpenAsk: () => Promise<boolean>;
  now?: number;
}): Promise<{ decision: "block"; reason: string } | null> {
  try {
    const { input, home } = opts;
    if (input.stop_hook_active === true) return null;
    if (!catchQuestionsEnabled(home)) return null;
    const message =
      typeof input.last_assistant_message === "string"
        ? input.last_assistant_message
        : typeof input.transcript_path === "string"
          ? lastAssistantText(input.transcript_path)
          : undefined;
    if (!looksLikeQuestion(message)) return null;
    if (!wantedInWaggle(message, readHookAskPrefs(home))) return null;
    // WAG-332: the transcript tells us if the agent already handled this in Waggle, or is
    // answering the person's own question.
    const path = typeof input.transcript_path === "string" ? input.transcript_path : undefined;
    const facts = path ? transcriptFacts(path) : undefined;
    if (facts) {
      if (facts.turnCalledWaggle) return null;
      if (facts.lastWaggleAt !== undefined && (opts.now ?? Date.now()) - facts.lastWaggleAt < RECENT_WAGGLE_MS) return null;
      if (promptAsksQuestion(facts.promptText) && message && !endsWithDirectQuestion(message)) return null;
    }
    const session = typeof input.session_id === "string" && input.session_id ? input.session_id : undefined;
    const promptId = facts?.promptId;
    if (session && promptId && readBlocked(home)[session] === promptId) return null;
    if (await opts.hasOpenAsk()) return null;
    if (session && promptId) writeBlocked(home, session, promptId);
    return { decision: "block", reason: STOP_REASON };
  } catch {
    return null;
  }
}

// WAG-268: with open asks, the reminder also names them, so the agent resumes them after a compaction.
export function sessionStartOutput(input: { source?: unknown }, openCaseIds: string[] = []): object | null {
  if (typeof input.source !== "string" || !REMINDER_SOURCES.includes(input.source)) return null;
  const open =
    openCaseIds.length > 0
      ? ` Your open ask${openCaseIds.length === 1 ? " is" : "s are"} ${openCaseIds.join(", ")}. Call waggle_check with each case_id to get the reply.`
      : "";
  return { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: `${RESUME_REMINDER}${open}` } };
}
