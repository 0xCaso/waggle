import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import type { Subprocess } from "bun";
import { rpcConnect, rmrf, startDaemon, stopDaemonByHome, tmpHome, type RpcClient } from "../helpers";

// On-demand start and shim reconnect (KNOCK-18). Runs the real daemon and the
// real `waggle mcp` shim, then proves:
//   1. Two shims starting at once with no daemon still connect to exactly one
//      daemon (the single-instance rule holds under parallel starts).
//   2. A shim whose daemon dies mid-wait restarts it on demand, reconnects with
//      the same session id, and still receives the reply once.
//
// Run with: bun test test/e2e

const ENTRY = join(import.meta.dir, "..", "..", "src", "index.ts");

interface Shim {
  client: Client;
  transport: StdioClientTransport;
}

interface ContentItem {
  type: string;
  text?: string;
}

type ToolResult = Awaited<ReturnType<Client["callTool"]>>;

const homes: string[] = [];
const procs: Subprocess[] = [];
const shims: Shim[] = [];

afterEach(async () => {
  for (const shim of shims.splice(0)) {
    try {
      await shim.transport.close();
    } catch {
      // Already closed.
    }
    try {
      await shim.client.close();
    } catch {
      // Already closed.
    }
  }
  for (const proc of procs.splice(0)) {
    try {
      proc.kill();
      await proc.exited;
    } catch {
      // Already gone.
    }
  }
  for (const home of homes.splice(0)) {
    await stopDaemonByHome(home);
    rmrf(home);
  }
});

function questionInput(title: string): Record<string, unknown> {
  return {
    kind: "question",
    title,
    need: "Pick one.",
    why: "I cannot decide.",
    recommendation: "a",
    recommendation_why: "It is the default.",
    options: [
      { id: "a", label: "A" },
      { id: "b", label: "B" },
    ],
  };
}

async function startShim(
  home: string,
  sessionId: string,
  cwd: string,
  extraEnv: Record<string, string> = {},
): Promise<Shim> {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [ENTRY, "mcp"],
    env: {
      KNOCK_HOME: home,
      CLAUDE_CODE_SESSION_ID: sessionId,
      KNOCK_ASK_WAIT_MS: "300",
      // The daemon the shim starts inherits this, so it self-cleans after the
      // test closes the shim. It is far longer than the 3s reconnect window.
      KNOCK_IDLE_EXIT_MIN: "0.2",
      ...extraEnv,
    },
    cwd,
    stderr: "pipe",
  });
  const client = new Client({ name: "knock-e2e", version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);
  shims.push({ client, transport });
  return { client, transport };
}

function textOf(result: ToolResult): string {
  if (!("content" in result)) return "";
  return (result.content as ContentItem[])
    .filter((c) => c.type === "text")
    .map((c) => c.text ?? "")
    .join("\n");
}

function extractCaseId(text: string): string {
  const match = text.match(/case_id":"(c_[^"]+)"/);
  if (!match) throw new Error(`no case id in pending text: ${text}`);
  return match[1];
}

async function askAndGetCaseId(shim: Shim, input: Record<string, unknown>): Promise<string> {
  const result = await shim.client.callTool({ name: "waggle_ask", arguments: input });
  if (result.isError) throw new Error(`waggle_ask errored: ${textOf(result)}`);
  return extractCaseId(textOf(result));
}

async function submitReply(
  app: RpcClient,
  caseId: string,
  idempotencyKey: string,
  message: string,
): Promise<void> {
  const res = await app.request("reply.submit", {
    case_id: caseId,
    idempotency_key: idempotencyKey,
    message,
    comments: [],
    captures: [],
  });
  if (res.error) throw new Error(`reply.submit errored: ${JSON.stringify(res.error)}`);
}

async function waitFor(fn: () => Promise<boolean> | boolean, timeoutMs = 8000): Promise<void> {
  const start = Date.now();
  for (;;) {
    if (await fn()) return;
    if (Date.now() - start > timeoutMs) throw new Error("condition not met in time");
    await new Promise((r) => setTimeout(r, 25));
  }
}

async function waitForSocket(socketPath: string, timeoutMs = 10000): Promise<void> {
  const start = Date.now();
  for (;;) {
    try {
      const probe = await rpcConnect(socketPath);
      probe.close();
      return;
    } catch {
      if (Date.now() - start > timeoutMs) {
        throw new Error("daemon socket never became connectable");
      }
      await new Promise((r) => setTimeout(r, 25));
    }
  }
}

describe("on-demand start", () => {
  test("two parallel daemon starts leave exactly one daemon", async () => {
    const home = tmpHome();
    homes.push(home);
    const env = { ...process.env, KNOCK_HOME: home };

    // Two on-demand starts race; the single-instance lock lets exactly one win.
    const a = Bun.spawn([process.execPath, ENTRY, "daemon"], {
      env,
      stdout: "pipe",
      stderr: "pipe",
    });
    const b = Bun.spawn([process.execPath, ENTRY, "daemon"], {
      env,
      stdout: "pipe",
      stderr: "pipe",
    });
    procs.push(a, b);

    await waitForSocket(join(home, "knock.sock"));
    await waitFor(() => {
      const aRunning = a.exitCode === null;
      const bRunning = b.exitCode === null;
      return (aRunning && b.exitCode === 3) || (bRunning && a.exitCode === 3);
    });

    const winner = a.exitCode === null ? a : b;
    const loser = a.exitCode === null ? b : a;
    expect(winner.exitCode).toBeNull();
    expect(loser.exitCode).toBe(3);
  });

  test("two shims starting at once connect to exactly one daemon", async () => {
    const home = tmpHome();
    homes.push(home);
    const socketPath = join(home, "knock.sock");
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });

    // No daemon is pre-started: each shim must start it on demand.
    const [a, b] = await Promise.all([
      startShim(home, "sess-a", cwd),
      startShim(home, "sess-b", cwd),
    ]);

    const [caseA, caseB] = await Promise.all([
      askAndGetCaseId(a, questionInput("Pick A")),
      askAndGetCaseId(b, questionInput("Pick B")),
    ]);
    expect(caseA).not.toBe(caseB);

    // Single instance: a fresh daemon on the same home exits 3, which proves
    // exactly one daemon owns the socket after the two parallel starts.
    const probe = Bun.spawn([process.execPath, ENTRY, "daemon"], {
      env: { ...process.env, KNOCK_HOME: home },
      stdout: "pipe",
      stderr: "pipe",
    });
    procs.push(probe);
    expect(await probe.exited).toBe(3);

    // Both cases live in the one daemon's database.
    const app = await rpcConnect(socketPath);
    const listed = await app.request("cases.list", {});
    const ids = (listed.result as { id: string }[]).map((c) => c.id);
    expect(ids).toContain(caseA);
    expect(ids).toContain(caseB);
    app.close();
  });

  test("a shim restarts the daemon on demand and still gets the reply once", async () => {
    const home = tmpHome();
    homes.push(home);
    const daemon = await startDaemon(home);
    procs.push(daemon);
    const socketPath = join(home, "knock.sock");

    const cwd = join(home, "work", "reconnect");
    mkdirSync(cwd, { recursive: true });

    // A long wait so the shim is still blocked in case.wait when we kill the
    // daemon (waggle_ask and waggle_check share this wait path).
    const shim = await startShim(home, "sess-reconnect", cwd, { KNOCK_ASK_WAIT_MS: "30000" });

    const askPromise = shim.client.callTool({
      name: "waggle_ask",
      arguments: questionInput("Reconnect check"),
    });

    // Read the case id once the case exists, while the shim waits for a reply.
    const caseId = await waitForCase(home, socketPath);

    // Kill the daemon while the shim waits.
    daemon.kill("SIGKILL");
    await daemon.exited;

    // The shim restarts the daemon on demand and reconnects with the same
    // session id. Wait for the new daemon's socket, then submit the reply.
    await waitForSocket(socketPath);
    const app = await rpcConnect(socketPath);
    await submitReply(app, caseId, "key-reconnect", "reply-after-reconnect");
    app.close();

    const result = await askPromise;
    if (result.isError) throw new Error(`waggle_ask errored after restart: ${textOf(result)}`);
    expect(textOf(result)).toContain("Message: reply-after-reconnect");

    // Delivered once: exactly one reply, marked delivered.
    const app2 = await rpcConnect(socketPath);
    const detail = await app2.request("cases.get", { id: caseId });
    const replies = (detail.result as { replies: { state: string }[] }).replies;
    expect(replies).toHaveLength(1);
    expect(replies[0].state).toBe("delivered");
    app2.close();
  });
});

// Polls cases.list until exactly one case exists, returning its id.
async function waitForCase(home: string, socketPath: string): Promise<string> {
  let id: string | null = null;
  await waitFor(async () => {
    const app = await rpcConnect(socketPath);
    try {
      const res = await app.request("cases.list", {});
      const rows = (res.result as { id: string }[]) ?? [];
      if (rows.length > 0) {
        id = rows[0].id;
        return true;
      }
      return false;
    } finally {
      app.close();
    }
  });
  return id!;
}
