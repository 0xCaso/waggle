import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RULE_BLOCK, RULE_END, RULE_LINES, RULE_START, addRule, refreshRule, removeRule, rulePath, ruleState } from "../src/agent-rule";
import { runRule } from "../src/cli/rule";

// WAG-265: the optional Waggle rule in CLAUDE.md and AGENTS.md. Everything runs under a temp HOME.

const dirs: string[] = [];
const saved = { HOME: process.env.HOME, CLAUDE_CONFIG_DIR: process.env.CLAUDE_CONFIG_DIR, CODEX_HOME: process.env.CODEX_HOME };
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
  for (const [k, v] of Object.entries(saved)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
});

function tmp(): string {
  const dir = mkdtempSync(join(tmpdir(), "knock-rule-"));
  dirs.push(dir);
  return dir;
}

describe("the Waggle rule block", () => {
  test("is three lines between the markers, in plain words", () => {
    expect(RULE_LINES).toEqual([
      "Ask the human through Waggle (waggle_ask), not in the terminal, for the requests set in Waggle > Settings > Requests.",
      "Call waggle_settings if you do not know them.",
      "Give options and a recommendation, then wait for the reply.",
    ]);
    expect(RULE_BLOCK).toBe(`${RULE_START}\n${RULE_LINES.join("\n")}\n${RULE_END}`);
    expect(RULE_BLOCK).not.toContain("—");
  });

  test("add creates the file and its folder when none exist", () => {
    const path = join(tmp(), ".claude", "CLAUDE.md");
    expect(ruleState(path)).toBe("missing");
    expect(addRule(path)).toBe("added");
    expect(readFileSync(path, "utf8")).toBe(`${RULE_BLOCK}\n`);
    expect(ruleState(path)).toBe("added");
  });

  test("add appends and keeps the other text; a second add changes nothing", () => {
    const path = join(tmp(), "AGENTS.md");
    const mine = "# My rules\n\nUse tabs.\n";
    writeFileSync(path, mine);
    addRule(path);
    const once = readFileSync(path, "utf8");
    expect(once).toBe(`${mine}\n${RULE_BLOCK}\n`);
    addRule(path);
    expect(readFileSync(path, "utf8")).toBe(once);
  });

  test("add to a file with no final newline still starts on its own line", () => {
    const path = join(tmp(), "CLAUDE.md");
    writeFileSync(path, "Use tabs.");
    addRule(path);
    expect(readFileSync(path, "utf8").startsWith("Use tabs.\n\n<!-- waggle:start -->")).toBe(true);
  });

  test("remove deletes exactly the block and leaves text before and after", () => {
    const path = join(tmp(), "CLAUDE.md");
    writeFileSync(path, "Before.\n");
    addRule(path);
    writeFileSync(path, `${readFileSync(path, "utf8")}\nAfter.\n`);
    expect(removeRule(path)).toBe("missing");
    expect(readFileSync(path, "utf8")).toBe("Before.\n\nAfter.\n");
    expect(ruleState(path)).toBe("missing");
  });

  test("add then remove gives back the original text", () => {
    const path = join(tmp(), "CLAUDE.md");
    const original = "# Notes\n\n- one\n- two\n";
    writeFileSync(path, original);
    addRule(path);
    removeRule(path);
    expect(readFileSync(path, "utf8")).toBe(original);
  });

  test("remove deletes a file that held only the block, and does nothing when there is none", () => {
    const path = join(tmp(), "CLAUDE.md");
    addRule(path);
    removeRule(path);
    expect(existsSync(path)).toBe(false);
    expect(removeRule(path)).toBe("missing");
    writeFileSync(path, "Mine.\n");
    expect(removeRule(path)).toBe("missing");
    expect(readFileSync(path, "utf8")).toBe("Mine.\n");
  });

  test("broken markers are left alone", () => {
    const path = join(tmp(), "CLAUDE.md");
    const broken = `Mine.\n${RULE_START}\nhalf a block\n`;
    writeFileSync(path, broken);
    expect(ruleState(path)).toBe("damaged");
    expect(addRule(path)).toBe("damaged");
    expect(removeRule(path)).toBe("damaged");
    expect(readFileSync(path, "utf8")).toBe(broken);
  });

  test("paths follow HOME, with CLAUDE_CONFIG_DIR and CODEX_HOME as overrides", () => {
    const home = tmp();
    process.env.HOME = home;
    delete process.env.CLAUDE_CONFIG_DIR;
    delete process.env.CODEX_HOME;
    expect(rulePath("claude")).toBe(join(home, ".claude", "CLAUDE.md"));
    expect(rulePath("codex")).toBe(join(home, ".codex", "AGENTS.md"));
    expect(rulePath("claude", { CLAUDE_CONFIG_DIR: "/x/c" })).toBe("/x/c/CLAUDE.md");
    expect(rulePath("codex", { CODEX_HOME: "/x/o" })).toBe("/x/o/AGENTS.md");
  });
});

describe("waggle rule", () => {
  test("adds and removes for the named agent only, under a temp HOME", () => {
    const home = tmp();
    process.env.HOME = home;
    delete process.env.CLAUDE_CONFIG_DIR;
    delete process.env.CODEX_HOME;
    mkdirSync(join(home, ".claude"));
    mkdirSync(join(home, ".codex"));
    // Never reach the real folders: stop here if a path is not under the temp HOME.
    expect(rulePath("claude").startsWith(home)).toBe(true);
    expect(rulePath("codex").startsWith(home)).toBe(true);
    const write = process.stdout.write.bind(process.stdout);
    let out = "";
    process.stdout.write = ((chunk: string) => ((out += chunk), true)) as typeof process.stdout.write;
    try {
      expect(runRule(["add", "claude"])).toBe(0);
      const added = JSON.parse(out.trim());
      expect(added.agents.claude).toEqual({ path: join(home, ".claude", "CLAUDE.md"), present: true, state: "added" });
      expect(added.agents.codex).toBeUndefined();
      expect(existsSync(join(home, ".codex", "AGENTS.md"))).toBe(false);
      out = "";
      expect(runRule(["status"])).toBe(0);
      expect(JSON.parse(out.trim()).agents.codex.state).toBe("missing");
      expect(runRule(["remove", "claude"])).toBe(0);
      expect(existsSync(join(home, ".claude", "CLAUDE.md"))).toBe(false);
      expect(runRule(["nope"])).toBe(2);
      expect(runRule(["add", "gemini"])).toBe(2);
    } finally {
      process.stdout.write = write;
    }
  });
});

describe("an older rule block", () => {
  const OLD = `${RULE_START}\nAsk the human every question, decision and review through Waggle (waggle_ask).\nDo not ask in the terminal.\n${RULE_END}`;

  test("refresh rewrites only the marked block, and a second refresh changes nothing", () => {
    const path = join(tmp(), "CLAUDE.md");
    writeFileSync(path, `Use tabs.\n\n${OLD}\n\nKeep it short.\n`);
    expect(refreshRule(path)).toBe("added");
    const once = readFileSync(path, "utf8");
    expect(once).toBe(`Use tabs.\n\n${RULE_BLOCK}\n\nKeep it short.\n`);
    refreshRule(path);
    expect(readFileSync(path, "utf8")).toBe(once);
  });

  test("refresh leaves a file alone when the user never added the block", () => {
    const path = join(tmp(), "CLAUDE.md");
    writeFileSync(path, "Use tabs.\n");
    expect(refreshRule(path)).toBe("missing");
    expect(readFileSync(path, "utf8")).toBe("Use tabs.\n");
    expect(refreshRule(join(tmp(), "none.md"))).toBe("missing");
  });

  test("refresh leaves a damaged pair of markers alone", () => {
    const path = join(tmp(), "CLAUDE.md");
    writeFileSync(path, `${RULE_START}\nold text\n`);
    expect(refreshRule(path)).toBe("damaged");
    expect(readFileSync(path, "utf8")).toBe(`${RULE_START}\nold text\n`);
  });

  test("`waggle rule status` updates an added block in place and reports the new lines", () => {
    const home = tmp();
    process.env.HOME = home;
    delete process.env.CLAUDE_CONFIG_DIR;
    delete process.env.CODEX_HOME;
    const path = rulePath("claude");
    mkdirSync(join(home, ".claude"), { recursive: true });
    writeFileSync(path, `${OLD}\n`);
    expect(runRule(["status", "claude"])).toBe(0);
    expect(readFileSync(path, "utf8")).toBe(`${RULE_BLOCK}\n`);
  });
});
