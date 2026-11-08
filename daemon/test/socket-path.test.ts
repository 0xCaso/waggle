import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rmrf } from "./helpers";

// The macOS unix socket path limit (KNOCK-17): `waggle daemon` and `waggle doctor`
// print a specific message instead of a generic listen failure when the socket
// path exceeds 103 bytes. The 160-char tail makes the length deterministic
// regardless of the tmpdir prefix.

const ENTRY = join(import.meta.dir, "..", "src", "index.ts");
const LONG_HOME = join(tmpdir(), "knock-long-" + "x".repeat(160));

interface RunResult {
  code: number;
  stdout: string;
  stderr: string;
}

async function runKnock(args: string[], env: Record<string, string>): Promise<RunResult> {
  const proc = Bun.spawn([process.execPath, ENTRY, ...args], {
    env,
    stdout: "pipe",
    stderr: "pipe",
    stdin: "pipe",
  });
  proc.stdin.end();
  const code = await proc.exited;
  const stdout = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();
  return { code, stdout, stderr };
}

function expectedMessage(): string {
  const socket = join(LONG_HOME, "knock.sock");
  return `KNOCK_HOME path is too long for a unix socket (${Buffer.byteLength(socket)} bytes, max 103)`;
}

describe("unix socket path limit", () => {
  test("waggle daemon prints the specific message and exits 3", async () => {
    const result = await runKnock(["daemon"], { ...process.env, KNOCK_HOME: LONG_HOME });

    expect(result.code).toBe(3);
    expect(result.stderr).toContain(expectedMessage());
  });

  test("waggle doctor prints the specific message and exits 1", async () => {
    // PATH is empty so no real claude/codex is ever probed.
    const emptyDir = mkdtempSync(join(tmpdir(), "knock-empty-"));
    try {
      const result = await runKnock(["doctor"], {
        ...process.env,
        KNOCK_HOME: LONG_HOME,
        PATH: emptyDir,
      });

      expect(result.code).toBe(1);
      expect(result.stdout).toContain("fail  service reachable, or startable on demand");
      expect(result.stdout).toContain(expectedMessage());
    } finally {
      rmrf(emptyDir);
    }
  });
});
