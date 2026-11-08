import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

// WAG-265: the optional Waggle rule in the user's global agent instructions. The block sits between
// two markers. Add appends it and never rewrites other text. Remove deletes exactly the marked
// block. Both are safe to repeat. Nothing here runs unless the user presses Add or Remove in the app.

export const RULE_START = "<!-- waggle:start -->";
export const RULE_END = "<!-- waggle:end -->";
export const RULE_LINES: readonly string[] = [
  "Ask the human through Waggle (waggle_ask), not in the terminal, for the requests set in Waggle > Settings > Requests.",
  "Call waggle_settings if you do not know them.",
  "Give options and a recommendation, then wait for the reply.",
];
export const RULE_BLOCK = [RULE_START, ...RULE_LINES, RULE_END].join("\n");

export type RuleAgent = "claude" | "codex";
export const RULE_AGENTS: readonly RuleAgent[] = ["claude", "codex"];
export type RuleState = "added" | "missing" | "damaged";

// Claude Code reads CLAUDE.md from CLAUDE_CONFIG_DIR, else ~/.claude. Codex reads AGENTS.md from CODEX_HOME, else ~/.codex.
// HOME comes first: Bun's os.homedir() does not follow a HOME set after start, and a test must reach a temp HOME.
export function rulePath(agent: RuleAgent, env: NodeJS.ProcessEnv = process.env): string {
  const home = env.HOME?.trim() || homedir();
  if (agent === "claude") return join(env.CLAUDE_CONFIG_DIR?.trim() || join(home, ".claude"), "CLAUDE.md");
  return join(env.CODEX_HOME?.trim() || join(home, ".codex"), "AGENTS.md");
}

function locate(text: string): { state: RuleState; start: number; end: number } {
  const start = text.indexOf(RULE_START);
  const end = text.indexOf(RULE_END);
  if (start === -1 && end === -1) return { state: "missing", start: -1, end: -1 };
  if (start === -1 || end === -1 || end < start || text.indexOf(RULE_START, start + 1) !== -1) {
    return { state: "damaged", start, end };
  }
  return { state: "added", start, end: end + RULE_END.length };
}

function read(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

export function ruleState(path: string): RuleState {
  return locate(read(path)).state;
}

// Appends the block. A file that already has it, or has a broken pair of markers, is left alone.
export function addRule(path: string): RuleState {
  const text = read(path);
  const found = locate(text);
  if (found.state !== "missing") return found.state;
  const gap = text === "" ? "" : text.endsWith("\n") ? "\n" : "\n\n";
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${text}${gap}${RULE_BLOCK}\n`);
  return "added";
}

// Rewrites a block the user added earlier when its text is out of date (an older release wrote other
// lines). Only a file that already holds exactly one pair of markers changes, and only between them.
export function refreshRule(path: string): RuleState {
  const text = read(path);
  const found = locate(text);
  if (found.state !== "added") return found.state;
  if (text.slice(found.start, found.end) !== RULE_BLOCK) {
    writeFileSync(path, text.slice(0, found.start) + RULE_BLOCK + text.slice(found.end));
  }
  return "added";
}

// Deletes the marked block, the newline after it and the one blank line Add put before it.
// A file left empty is deleted: it held only the block.
export function removeRule(path: string): RuleState {
  const text = read(path);
  const found = locate(text);
  if (found.state !== "added") return found.state === "damaged" ? "damaged" : "missing";
  let before = text.slice(0, found.start);
  let after = text.slice(found.end);
  if (after.startsWith("\r\n")) after = after.slice(2);
  else if (after.startsWith("\n")) after = after.slice(1);
  if (before.endsWith("\n\n")) before = before.slice(0, -1);
  const next = before + after;
  if (next === "") rmSync(path, { force: true });
  else writeFileSync(path, next);
  return "missing";
}
