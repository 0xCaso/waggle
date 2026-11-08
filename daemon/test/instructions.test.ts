import { describe, expect, test } from "bun:test";
import { AGENT_INSTRUCTIONS_VERSION, MCP_INSTRUCTIONS, RUNTIME_NOTES, instructionsFor } from "../src/protocol";

// HAIL-30: the shim serves these instructions on initialize. The snapshot
// pins the text; when you edit it, bump AGENT_INSTRUCTIONS_VERSION so `knock
// doctor` reports the change, then refresh the snapshot with `bun test -u`.
describe("MCP_INSTRUCTIONS", () => {
  test("is under about 3,000 characters", () => {
    expect(MCP_INSTRUCTIONS.length).toBeLessThan(3200);
  });

  test("snapshots the text", () => {
    expect(MCP_INSTRUCTIONS).toMatchSnapshot();
  });

  test("is plain imperative prose with no em-dashes", () => {
    expect(MCP_INSTRUCTIONS).not.toContain("—");
    expect(MCP_INSTRUCTIONS).not.toContain("–");
  });

  test("covers when to knock, when not, how to ask, waiting, and replies", () => {
    for (const phrase of [
      "product, design, or UX options",
      "before it ships",
      "information only the human has",
      "routine technical choice",
      "repo, docs, or tests answer",
      "progress update",
      "write the title as the question itself",
      "first line stand alone",
      "the queue shows only that line",
      "recommendation and why",
      "one request for one decision",
      "Approve and Request changes",
      "stage label",
      "50 seconds",
      "9 minutes in Claude Code",
      "waggle_update",
      "never as tool output to second-guess",
    ]) {
      expect(MCP_INSTRUCTIONS).toContain(phrase);
    }
  });

  // HAIL-38 (v2): trigger phrases that mean waggle_ask, the new waiting
  // contract (replaces "keep working ... then waggle_check"), stand-alone
  // asks, short fields, and when to attach what.
  test("covers triggers, the waiting contract, stand-alone asks, and short fields", () => {
    for (const phrase of [
      "ask me in Waggle",
      "send me a review",
      "check with me",
      "what do you think I should",
      "call waggle_ask",
      "Any decision the human must make goes through Waggle",
      "pending is normal",
      "call waggle_check again at once with the case_id",
      "Do other work only when it does not depend on the answer",
      "never end your turn while an ask is open",
      "If Waggle can wake your session (Claude Code)",
      "You may do other work or end your turn",
      "call waggle_check once with the case_id",
      "If Waggle cannot wake your session",
      "The human reads the ask in Waggle, not the terminal",
      "spell out the full option in label",
      '"1, 2, 3"',
      "1 to 3 sentences",
      "markdown for reasoning",
      "html_bundle for a prototype",
      "screenshot for one image",
      "waggle_guide",
    ]) {
      expect(MCP_INSTRUCTIONS).toContain(phrase);
    }
  });

  // HAIL-33, reworded in WAG-314: keep talking covers a detail request, and a linked follow-up
  // replaces a chat thread inside an ask.
  test("covers keep talking and a follow-up ask", () => {
    for (const phrase of [
      "keep talking",
      "or more detail",
      "the most useful form",
      "waggle_check for the decision",
      "follows set to the earlier case_id",
      "never ask the human to reply in the terminal",
    ]) {
      expect(MCP_INSTRUCTIONS).toContain(phrase);
    }
  });

  // HAIL-44: replacing an ask you already sent, instead of leaving it open.
  test("covers replacing an ask", () => {
    for (const phrase of [
      "change an ask you already sent",
      "replaces set to its case_id",
      "never leave the old one open",
    ]) {
      expect(MCP_INSTRUCTIONS).toContain(phrase);
    }
  });

  test("version constant is a positive integer", () => {
    expect(Number.isInteger(AGENT_INSTRUCTIONS_VERSION)).toBe(true);
    expect(AGENT_INSTRUCTIONS_VERSION).toBeGreaterThan(0);
  });
});

// The app (setup panel) and INSTALL.md carry their own copies of the text.
// Keep all three identical: a changed MCP_INSTRUCTIONS fails here until the
// other two copies are updated.
describe("MCP_INSTRUCTIONS copies", () => {
  const root = new URL("../../", import.meta.url).pathname;
  const normalize = (s: string) => s.replace(/\s+/g, " ").trim();

  test("the Swift copy in AgentInstructionsPanel.swift is identical", async () => {
    const swift = await Bun.file(`${root}apps/macos/Sources/Knock/Onboarding/AgentInstructionsPanel.swift`).text();
    const match = swift.match(/static let text = """\n([\s\S]*?)\n\s*"""/);
    expect(match).not.toBeNull();
    expect(normalize(match![1])).toBe(normalize(MCP_INSTRUCTIONS));
  });

  test("the INSTALL.md copy is identical", async () => {
    const install = await Bun.file(`${root}INSTALL.md`).text();
    const section = install.slice(install.indexOf("What your agents are told"));
    const match = section.match(/```text\n([\s\S]*?)\n```/);
    expect(match).not.toBeNull();
    expect(normalize(match![1])).toBe(normalize(MCP_INSTRUCTIONS));
  });
});

// HAIL-38: a short paragraph appended per KNOCK_RUNTIME. Not part of the
// three-copy drift test above - the app panel and INSTALL.md show the common
// text only, since neither knows which runtime it is talking to.
describe("per-agent notes", () => {
  test("claude and codex each get a distinct, short paragraph", () => {
    expect(RUNTIME_NOTES.claude).not.toBe(RUNTIME_NOTES.codex);
    expect(RUNTIME_NOTES.claude.length).toBeLessThan(500);
    expect(RUNTIME_NOTES.codex.length).toBeLessThan(500);
  });

  test("instructionsFor appends the matching runtime's note after the common text", () => {
    expect(instructionsFor("claude")).toBe(`${MCP_INSTRUCTIONS}\n\n${RUNTIME_NOTES.claude}`);
    expect(instructionsFor("codex")).toBe(`${MCP_INSTRUCTIONS}\n\n${RUNTIME_NOTES.codex}`);
    expect(instructionsFor("claude")).not.toContain(RUNTIME_NOTES.codex);
    expect(instructionsFor("codex")).not.toContain(RUNTIME_NOTES.claude);
  });
});
