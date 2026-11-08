import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import type { Subprocess } from "bun";
import { rpcConnect, rmrf, startDaemon, stopDaemonByHome, tmpHome, type RpcClient } from "../helpers";

// The dogfood harness (MVP AC 9, docs/stories/KNOCK-16.md). It runs the real
// `waggle daemon` on a temp KNOCK_HOME and the real `waggle mcp` shims over stdio,
// then proves three behaviours end to end:
//   1. Three parallel sessions each receive only their own reply, exactly once.
//   2. A queued reply survives a daemon SIGKILL and is delivered once after
//      the daemon restarts.
//   3. A reply to a session whose shim died becomes failed; reply.retry fails
//      again and never reports delivered.
//
// Run with: bun test test/e2e

const SHIM_ENTRY = join(import.meta.dir, "..", "..", "src", "index.ts");

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const SHOT = Buffer.concat([PNG_SIG, Buffer.from("screenshot")]);

// The wrapper gives the failure test a real shim whose parent pid it controls.
// The transport spawns this wrapper; the wrapper spawns the shim with inherited
// stdio (so the transport talks straight to the shim) and reports both pids to
// a file. Killing the wrapper first, then the shim, makes the daemon see a dead
// parent and mark the session ended.
const WRAPPER = `
const child = Bun.spawn([process.execPath, process.env.KNOCK_SHIM_ENTRY, "mcp"], {
  env: process.env,
  stdin: "inherit",
  stdout: "inherit",
  stderr: "inherit",
});
await Bun.write(process.env.KNOCK_PIDS_FILE, JSON.stringify({ parent: process.pid, child: child.pid }));
await child.exited;
`;

interface Shim {
  client: Client;
  transport: StdioClientTransport;
}

interface ContentItem {
  type: string;
  text?: string;
  data?: string;
  mimeType?: string;
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

function writeShot(cwd: string): void {
  const shots = join(cwd, "shots");
  mkdirSync(shots, { recursive: true });
  writeFileSync(join(shots, "a.png"), SHOT);
}

function reviewInput(title: string): Record<string, unknown> {
  return {
    kind: "review",
    title,
    need: "Please review this.",
    why: "I cannot decide alone.",
    recommendation: "a",
    recommendation_why: "It follows the brief.",
    options: [
      { id: "a", label: "Ship it" },
      { id: "b", label: "Change it" },
    ],
    artifact: { type: "screenshot", path: "./shots/a.png" },
  };
}

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
): Promise<Shim> {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [SHIM_ENTRY, "mcp"],
    env: { KNOCK_HOME: home, CLAUDE_CODE_SESSION_ID: sessionId, KNOCK_ASK_WAIT_MS: "300" },
    cwd,
    stderr: "pipe",
  });
  const client = new Client({ name: "knock-e2e", version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);
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
  const reply = res.result as { state?: string };
  if (reply.state !== "queued") throw new Error(`reply.submit did not queue: ${JSON.stringify(res.result)}`);
}

async function repliesOf(
  app: RpcClient,
  caseId: string,
): Promise<{ id: string; state: string; reason?: string }[]> {
  const res = await app.request("cases.get", { id: caseId });
  if (res.error) throw new Error(`cases.get errored: ${JSON.stringify(res.error)}`);
  const detail = res.result as { replies: { id: string; state: string; reason?: string }[] };
  return detail.replies;
}

async function waitFor(fn: () => Promise<boolean> | boolean, timeoutMs = 8000): Promise<void> {
  const start = Date.now();
  for (;;) {
    if (await fn()) return;
    if (Date.now() - start > timeoutMs) throw new Error("condition not met in time");
    await new Promise((r) => setTimeout(r, 25));
  }
}

function killQuiet(pid: number): void {
  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // Already gone.
  }
}

describe("dogfood harness", () => {
  test("three parallel sessions each receive only their own reply, exactly once", async () => {
    const home = tmpHome();
    homes.push(home);
    const daemon = await startDaemon(home);
    procs.push(daemon);
    const socketPath = join(home, "knock.sock");

    interface StartedReview {
      session: string;
      marker: string;
      title: string;
      cwd: string;
      shim: Shim;
      caseId: string;
    }

    const sessions: StartedReview[] = [];
    for (const r of [
      { session: "sess-checkout", marker: "reply-for-checkout", title: "Checkout layout" },
      { session: "sess-rarity", marker: "reply-for-rarity", title: "Rarity weights" },
      { session: "sess-typography", marker: "reply-for-typography", title: "Typography pass" },
    ]) {
      const cwd = join(home, "work", r.session);
      mkdirSync(cwd, { recursive: true });
      writeShot(cwd);
      const shim = await startShim(home, r.session, cwd);
      shims.push(shim);
      const caseId = await askAndGetCaseId(shim, reviewInput(r.title));
      sessions.push({ ...r, cwd, shim, caseId });
    }

    // Replies land through the RPC in a shuffled order.
    const app = await rpcConnect(socketPath);
    const shuffled = [...sessions].sort(() => Math.random() - 0.5);
    for (const s of shuffled) {
      await submitReply(app, s.caseId, `key-${s.session}`, s.marker);
    }

    // Each shim receives only its own reply.
    for (const s of sessions) {
      const result = await s.shim.client.callTool({
        name: "waggle_check",
        arguments: { case_id: s.caseId },
      });
      if (result.isError) throw new Error(`waggle_check errored: ${textOf(result)}`);
      const text = textOf(result);
      expect(text).toContain(`Message: ${s.marker}`);
      for (const other of sessions) {
        if (other.session !== s.session) expect(text).not.toContain(other.marker);
      }
    }

    // Delivered exactly once: one reply per case, delivered, and a second
    // check returns pending instead of a second delivery.
    for (const s of sessions) {
      const replies = await repliesOf(app, s.caseId);
      expect(replies).toHaveLength(1);
      expect(replies[0].state).toBe("delivered");

      const again = await s.shim.client.callTool({
        name: "waggle_check",
        arguments: { case_id: s.caseId },
      });
      if (again.isError) throw new Error(`second waggle_check errored: ${textOf(again)}`);
      expect(textOf(again)).toContain('"status":"pending"');
    }
    app.close();
  });

  test("a queued reply survives a daemon SIGKILL and is delivered once after restart", async () => {
    const home = tmpHome();
    homes.push(home);
    let daemon = await startDaemon(home);
    procs.push(daemon);
    const socketPath = join(home, "knock.sock");

    const cwd = join(home, "work", "restart");
    mkdirSync(cwd, { recursive: true });
    const shim = await startShim(home, "sess-restart", cwd);
    shims.push(shim);
    const caseId = await askAndGetCaseId(shim, questionInput("Restart check"));

    const app = await rpcConnect(socketPath);
    await submitReply(app, caseId, "key-restart", "reply-for-restart");

    // The reply is queued; kill the daemon before the shim fetches it.
    daemon.kill("SIGKILL");
    await daemon.exited;

    // Restart on the same KNOCK_HOME and reconnect the same session id.
    daemon = await startDaemon(home);
    procs.push(daemon);
    const shim2 = await startShim(home, "sess-restart", cwd);
    shims.push(shim2);

    const result = await shim2.client.callTool({
      name: "waggle_check",
      arguments: { case_id: caseId },
    });
    if (result.isError) throw new Error(`waggle_check after restart errored: ${textOf(result)}`);
    expect(textOf(result)).toContain("Message: reply-for-restart");

    const app2 = await rpcConnect(socketPath);
    const replies = await repliesOf(app2, caseId);
    expect(replies).toHaveLength(1);
    expect(replies[0].state).toBe("delivered");

    const again = await shim2.client.callTool({
      name: "waggle_check",
      arguments: { case_id: caseId },
    });
    expect(textOf(again)).toContain('"status":"pending"');

    app2.close();
    app.close();
  });

  test("a reply to a killed shim becomes failed and retry never reports delivered", async () => {
    const home = tmpHome();
    homes.push(home);
    const daemon = await startDaemon(home);
    procs.push(daemon);
    const socketPath = join(home, "knock.sock");

    const cwd = join(home, "work", "gone");
    mkdirSync(cwd, { recursive: true });

    // A real shim under a wrapper whose pid this test can kill.
    const pidsFile = join(home, "pids.json");
    const wrapperPath = join(home, "wrapper.mjs");
    writeFileSync(wrapperPath, WRAPPER);

    const transport = new StdioClientTransport({
      command: process.execPath,
      args: [wrapperPath],
      env: {
        KNOCK_HOME: home,
        CLAUDE_CODE_SESSION_ID: "sess-gone",
        KNOCK_ASK_WAIT_MS: "300",
        KNOCK_SHIM_ENTRY: SHIM_ENTRY,
        KNOCK_PIDS_FILE: pidsFile,
      },
      cwd,
      stderr: "pipe",
    });
    const client = new Client({ name: "knock-e2e", version: "0.0.0" }, { capabilities: {} });
    await client.connect(transport);
    shims.push({ client, transport });

    const caseId = await askAndGetCaseId({ client, transport }, questionInput("Gone session"));

    const app = await rpcConnect(socketPath);
    await submitReply(app, caseId, "key-gone", "reply-for-gone");

    // Wait for the wrapper to report its pids, then kill the parent first and
    // the shim second, so the daemon sees a dead parent and ends the session.
    await waitFor(() => existsSync(pidsFile));
    const pids = JSON.parse(readFileSync(pidsFile, "utf8")) as { parent: number; child: number };
    killQuiet(pids.parent);
    killQuiet(pids.child);

    await waitFor(async () => {
      const replies = await repliesOf(app, caseId);
      return replies.length === 1 && replies[0].state === "failed";
    });

    const [failed] = await repliesOf(app, caseId);
    expect(failed.state).toBe("failed");
    expect(failed.reason).toBe("session_unreachable");

    // retry re-fails under the same id; it never becomes delivered.
    const retried = await app.request("reply.retry", { reply_id: failed.id });
    expect(retried.error).toBeUndefined();
    expect((retried.result as { id: string; state: string }).id).toBe(failed.id);
    expect((retried.result as { id: string; state: string }).state).toBe("failed");

    const after = await repliesOf(app, caseId);
    expect(after).toHaveLength(1);
    expect(after[0].state).toBe("failed");
    app.close();
  });
});
