import { existsSync } from "node:fs";
import { dirname } from "node:path";
import { addRule, refreshRule, removeRule, RULE_AGENTS, RULE_LINES, rulePath, ruleState, type RuleAgent } from "../agent-rule";

// `waggle rule <status|add|remove> [claude] [codex]` (WAG-265). The app runs it to show, add and
// remove the optional Waggle rule in ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md. One line of JSON:
//   {"lines":[...],"agents":{"claude":{"path":"...","present":true,"state":"added|missing|damaged"}, ...}}
// `present` is true when the agent's config folder exists, which is how the app knows the agent is set up here.
// `status` also brings an added block up to date in place, so the app shows and keeps the current text.
// With no agent named, it covers both. It never runs on its own: only the user's Add or Remove does.
const USAGE = "Usage: waggle rule <status|add|remove> [claude] [codex]\n";

export function runRule(argv: string[]): number {
  const [verb, ...names] = argv;
  if (verb !== "status" && verb !== "add" && verb !== "remove") {
    process.stderr.write(USAGE);
    return 2;
  }
  const agents = names.length === 0 ? [...RULE_AGENTS] : names;
  if (!agents.every((a): a is RuleAgent => (RULE_AGENTS as readonly string[]).includes(a))) {
    process.stderr.write(USAGE);
    return 2;
  }
  const out: Record<string, { path: string; present: boolean; state: string }> = {};
  let failed = false;
  for (const agent of agents as RuleAgent[]) {
    const path = rulePath(agent);
    try {
      const state = verb === "add" ? addRule(path) : verb === "remove" ? removeRule(path) : refreshRule(path);
      out[agent] = { path, present: existsSync(dirname(path)), state };
    } catch (error) {
      failed = true;
      process.stderr.write(`waggle rule: ${path}: ${(error as Error).message}\n`);
    }
  }
  process.stdout.write(`${JSON.stringify({ lines: RULE_LINES, agents: out })}\n`);
  return failed ? 1 : 0;
}
