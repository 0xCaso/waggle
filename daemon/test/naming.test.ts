import { describe, expect, test } from "bun:test";
import { agentLabel, workLine, workName } from "../src/connectors/naming";

// HAIL-231: the same cases the Mac app tests (NotificationBuilderTests, ClaudeCheckTests).
describe("workName", () => {
  test("a hashed worktree folder reads as words", () => {
    expect(workName("fragrant-hospital-fc8f1973")).toBe("Fragrant hospital");
    expect(workName("brawny-fiction-86b69062")).toBe("Brawny fiction");
  });
  test("a fleet worktree reads as its id, with no branch", () => {
    expect(workName("HAIL-224")).toBe("HAIL 224");
  });
  test("a topic shows as written", () => {
    expect(workName("Syllotips launch email")).toBe("Syllotips launch email");
  });
  test("a full path keeps only the folder", () => {
    expect(workName("/work/fragrant-hospital-fc8f1973")).toBe("Fragrant hospital");
    expect(workName("my_cool_app")).toBe("My cool app");
    expect(workName("waggleApp")).toBe("waggleApp");
    expect(workName("")).toBe("");
  });
});

describe("agentLabel", () => {
  test("names the runtime in words", () => {
    expect(agentLabel("claude", "local-agent-mode-waggle", false)).toBe("Cowork");
    expect(agentLabel("claude", "claude-ai", false)).toBe("Claude app");
    expect(agentLabel("claude", "claude-code", false)).toBe("Claude Code");
    expect(agentLabel("claude", "claude-ai", true)).toBe("Claude Code");
    expect(agentLabel("claude", null, null)).toBe("Claude Code");
    expect(agentLabel("codex", "codex-mcp-client", false)).toBe("Codex");
  });
});

describe("workLine", () => {
  test("joins the work and the agent", () => {
    const c = { project: "fragrant-hospital-fc8f1973", runtime: "claude", session_can_nudge: true, session_client_name: "claude-code" } as const;
    expect(workLine(c)).toBe("Fragrant hospital · Claude Code");
  });
});
