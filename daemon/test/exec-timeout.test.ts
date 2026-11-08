import { describe, expect, test } from "bun:test";
import { runAsync } from "../src/cli/exec";

// Friend report 29 Sep: the Connect screen stayed on "Checking…". A CLI
// that starts a long-lived child (an MCP server for its health check) keeps
// the pipes open after the CLI itself is killed, so "close" never fired and
// runAsync never resolved. It must resolve at the timeout.
describe("runAsync timeout", () => {
  test("resolves at the timeout even when a grandchild holds the pipes open", async () => {
    const started = Date.now();
    const result = await runAsync("sh", ["-c", "sleep 4 & sleep 4"], 500);
    const elapsed = Date.now() - started;
    expect(result.error).toBe("timed out after 500ms");
    expect(elapsed).toBeLessThan(2500);
  });
});
