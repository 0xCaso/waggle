import { describe, expect, test } from "bun:test";
import { NOT_STAGED_BY_SHIM } from "../src/artifacts";
import { translateDaemonError } from "../src/mcp/errors";
import { DaemonConnectionError, DaemonRpcError } from "../src/mcp/client";
import { DAEMON_UNREACHABLE_ERROR, SHIM_OUTDATED_ERROR, USER_ACTIONABLE_PREFIX } from "../src/protocol";

// HAIL-38, docs/protocol-mvp.md "Errors that say what to tell the user": a
// connection failure or a stale-shim rejection becomes a sentence the agent
// can relay to the human verbatim, not the raw technical error. Unit-level,
// since faithfully reproducing an unreachable daemon end to end needs the 3s
// on-demand retry (see test/mcp-unreachable.test.ts for that one, slower,
// real-process check).
describe("translateDaemonError", () => {
  test("a connection failure becomes the daemon-unreachable sentence", () => {
    const translated = translateDaemonError(new DaemonConnectionError("waggle daemon connection closed"));
    expect(translated.message).toBe(DAEMON_UNREACHABLE_ERROR);
    expect(translated.message).toStartWith(USER_ACTIONABLE_PREFIX);
    // The sentence to relay verbatim (first line) names no technical detail;
    // the guidance after it may name what NOT to say.
    const [relaySentence] = translated.message.split("\n");
    expect(relaySentence).toContain("Waggle isn't running");
    expect(relaySentence).not.toContain("socket");
    expect(relaySentence).not.toContain(".sock");
    expect(relaySentence).not.toContain("port");
  });

  test("a stale-shim artifact rejection becomes the restart-session sentence", () => {
    const translated = translateDaemonError(new DaemonRpcError(-32004, NOT_STAGED_BY_SHIM));
    expect(translated.message).toBe(SHIM_OUTDATED_ERROR);
    expect(translated.message).toStartWith(USER_ACTIONABLE_PREFIX);
    const [relaySentence] = translated.message.split("\n");
    expect(relaySentence).not.toContain("shim");
    expect(relaySentence).not.toContain("incoming/");
  });

  test("a validation or ownership error passes through unchanged", () => {
    const original = new DaemonRpcError(-32602, "why is 501 characters; the maximum is 500.");
    expect(translateDaemonError(original)).toBe(original);

    const notYours = new Error("not your case");
    expect(translateDaemonError(notYours)).toBe(notYours);
  });
});
