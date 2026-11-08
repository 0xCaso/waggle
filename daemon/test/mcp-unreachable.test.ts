import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { DAEMON_UNREACHABLE_ERROR, instructionsFor } from "../src/protocol";
import { rmrf } from "./helpers";

// HAIL-38, docs/protocol-mvp.md "Errors that say what to tell the user": end
// to end, through the real `waggle mcp` binary, when the daemon can never
// become reachable. KNOCK_HOME's socket path is deliberately too long (the
// same trick test/socket-path.test.ts uses, KNOCK-17): every `waggle daemon`
// the shim spawns on demand exits immediately without binding, so the shim's
// 3s on-demand retry (ON_DEMAND_RETRY_MS) genuinely exhausts - this test
// really does take a few seconds. The folder holds only the `onboarded` marker
// (HAIL-193: the shim answers "not set up" without it). The too-long check runs
// before `waggle daemon` writes anything, so only that empty marker is left.
const LONG_HOME = join(tmpdir(), "knock-unreachable-" + "x".repeat(160));
mkdirSync(LONG_HOME, { recursive: true });
writeFileSync(join(LONG_HOME, "onboarded"), "");

interface ContentItem {
  type: string;
  text?: string;
}

describe("waggle_ask when the daemon can never become reachable", () => {
  test("the MCP error is the exact user-actionable sentence, not a raw connection error", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "knock-unreachable-cwd-"));
    const entry = join(import.meta.dir, "..", "src", "index.ts");
    const transport = new StdioClientTransport({
      command: process.execPath,
      args: [entry, "mcp"],
      env: { KNOCK_HOME: LONG_HOME, CLAUDE_CODE_SESSION_ID: "sess-unreachable" },
      cwd,
      stderr: "pipe",
    });
    const client = new Client({ name: "knock-test", version: "0.0.0" }, { capabilities: {} });
    await client.connect(transport);

    try {
      const result = await client.callTool({
        name: "waggle_ask",
        arguments: {
          kind: "question",
          title: "Pick a layout",
          need: "Pick a layout",
          why: "I cannot decide",
          recommendation: "a",
          recommendation_why: "It is the default",
        },
      });
      expect(result.isError).toBe(true);
      const text = ("content" in result ? (result.content as ContentItem[]) : [])
        .filter((c) => c.type === "text")
        .map((c) => c.text ?? "")
        .join("\n");
      expect(text).toContain(DAEMON_UNREACHABLE_ERROR);
      expect(text).not.toContain(".sock");
      expect(text).not.toContain(LONG_HOME);
    } finally {
      await transport.close();
      await client.close();
      rmrf(cwd);
    }
  }, 30000);
});

// HAIL-101: initialize waits only briefly for the operator's ask preferences.
describe("initialize when the daemon can never become reachable", () => {
  test("serves the plain instructions, without the preferences section", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "knock-unreachable-cwd-"));
    const entry = join(import.meta.dir, "..", "src", "index.ts");
    const transport = new StdioClientTransport({
      command: process.execPath,
      args: [entry, "mcp"],
      env: {
        KNOCK_HOME: LONG_HOME,
        CLAUDE_CODE_SESSION_ID: "sess-unreachable-init",
        KNOCK_SHIM_INSTRUCTIONS_WAIT_MS: "500",
      },
      cwd,
      stderr: "pipe",
    });
    const client = new Client({ name: "knock-test", version: "0.0.0" }, { capabilities: {} });
    try {
      await client.connect(transport);
      expect(client.getInstructions()).toBe(instructionsFor("claude"));
      expect(client.getInstructions()).not.toContain("Operator preferences");
    } finally {
      await transport.close();
      await client.close();
      rmrf(cwd);
    }
  }, 30000);
});
