import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import {
  MIN_NUDGE_CLAUDE_VERSION,
  detectClaudeVersion,
  nudgeText,
  parseVersion,
  postNudge,
  readMessagingEnv,
  resolveNudgeSupport,
  type VersionProbe,
} from "../src/mcp/nudge";
import { pendingMode, pendingText, waitMsFor } from "../src/mcp/shim";
import pkg from "../package.json" with { type: "json" };
import { rmrf, rpcConnect, tmpHome, type RpcClient, type RpcLine } from "./helpers";

// HAIL-181: the automatic nudge, the per-session wait and pending text. Every socket here is a FAKE unix socket server in a temp dir.
// No test connects to a real Claude Code messaging socket or reads a real token.

const TOKEN = "tok-SECRET-0123456789";
process.env.KNOCK_AUTO_NUDGE_MS = "50";
const REPLY_TEXT = "Go with Detailed, the colours are nicer.";

const question = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact" },
    { id: "b", label: "Detailed" },
  ],
};

interface FakeInbox {
  path: string;
  // Each entry is the lines of one connection, in arrival order.
  connections: string[][];
  stop(): void;
}

// A fake Claude Code session inbox: records every line of every connection.
function fakeInbox(dir: string): FakeInbox {
  const path = join(dir, "inbox.sock");
  const connections: string[][] = [];
  const server = Bun.listen<{ index: number; buffer: string }>({
    unix: path,
    socket: {
      open(socket) {
        connections.push([]);
        socket.data = { index: connections.length - 1, buffer: "" };
      },
      data(socket, data) {
        socket.data.buffer += data.toString("utf8");
        let nl: number;
        while ((nl = socket.data.buffer.indexOf("\n")) >= 0) {
          connections[socket.data.index].push(socket.data.buffer.slice(0, nl));
          socket.data.buffer = socket.data.buffer.slice(nl + 1);
        }
      },
      close() {},
      error() {},
    },
  });
  return { path, connections, stop: () => server.stop(true) };
}

const homes: string[] = [];
const servers: RpcServer[] = [];
const inboxes: FakeInbox[] = [];
const clients: Client[] = [];
const transports: StdioClientTransport[] = [];
const rpcClients: RpcClient[] = [];

afterEach(async () => {
  for (const t of transports.splice(0)) await t.close().catch(() => {});
  for (const c of clients.splice(0)) await c.close().catch(() => {});
  for (const c of rpcClients.splice(0)) c.close();
  for (const i of inboxes.splice(0)) i.stop();
  for (const s of servers.splice(0)) {
    try {
      s.stop();
    } catch {
      // Already stopped.
    }
  }
  for (const h of homes.splice(0)) rmrf(h);
});

function setup(): { home: string; cwd: string; store: Store } {
  const home = tmpHome();
  homes.push(home);
  const cwd = join(home, "work");
  mkdirSync(cwd, { recursive: true });
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  servers.push(
    startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: pkg.version }),
  );
  return { home, cwd, store };
}

const shimStderr: string[] = [];

async function startShim(home: string, cwd: string, sessionId: string, env: Record<string, string>) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(import.meta.dir, "..", "src", "index.ts"), "mcp"],
    env: { KNOCK_HOME: home, CLAUDE_CODE_SESSION_ID: sessionId, KNOCK_ASK_WAIT_MS: "300", ...env },
    cwd,
    stderr: "pipe",
  });
  const client = new Client({ name: "knock-test", version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);
  transport.stderr?.on("data", (d: Buffer) => shimStderr.push(d.toString("utf8")));
  transports.push(transport);
  clients.push(client);
  return { client, transport };
}

function textOf(result: Awaited<ReturnType<Client["callTool"]>>): string {
  if (!("content" in result)) return "";
  return (result.content as { type: string; text?: string }[])
    .filter((c) => c.type === "text")
    .map((c) => c.text ?? "")
    .join("\n");
}

async function waitFor(fn: () => boolean, timeoutMs = 5000): Promise<void> {
  const start = Date.now();
  while (!fn()) {
    if (Date.now() - start > timeoutMs) throw new Error("condition not met in time");
    await new Promise((r) => setTimeout(r, 20));
  }
}

async function app(home: string): Promise<RpcClient> {
  const c = await rpcConnect(join(home, "knock.sock"));
  rpcClients.push(c);
  return c;
}

// A shim with a live inbox, an open ask and a queued reply.
async function queuedReply(opts: { env?: Record<string, string>; shimEnv?: Record<string, string> } = {}) {
  const { home, cwd, store } = setup();
  const inbox = fakeInbox(home);
  inboxes.push(inbox);
  const env = opts.env ?? {
    CLAUDE_CODE_MESSAGING_SOCKET: inbox.path,
    CLAUDE_CODE_MESSAGING_TOKEN: TOKEN,
    KNOCK_SHIM_TEST_PARENT_EXE: "/fake/claude/versions/2.1.285",
  };
  const { client, transport } = await startShim(home, cwd, "sess-nudge", { ...env, ...opts.shimEnv });
  const asked = await client.callTool({ name: "waggle_ask", arguments: question });
  const caseId = textOf(asked).match(/case_id":"(c_[^"]+)"/)![1];
  const rpc = await app(home);
  const submitted = await rpc.request("reply.submit", {
    case_id: caseId,
    idempotency_key: "k1",
    choice: "b",
    message: REPLY_TEXT,
    comments: [],
    captures: [],
  });
  expect((submitted.result as { state: string }).state).toBe("queued");
  return { home, cwd, store, inbox, client, transport, rpc, caseId };
}


const nudgeEnv = (inbox: FakeInbox) => ({
  CLAUDE_CODE_MESSAGING_SOCKET: inbox.path,
  CLAUDE_CODE_MESSAGING_TOKEN: TOKEN,
  KNOCK_SHIM_TEST_PARENT_EXE: "/fake/claude/versions/2.1.285",
});

async function submitReply(home: string, caseId: string): Promise<void> {
  const rpc = await app(home);
  await rpc.request("reply.submit", {
    case_id: caseId,
    idempotency_key: "k1",
    choice: "b",
    message: REPLY_TEXT,
    comments: [],
    captures: [],
  });
}

describe("wake instead of poll (HAIL-181)", () => {
  test("pending tells a can_nudge session Waggle will wake it; the answer nudges with no click", async () => {
    const { home, cwd } = setup();
    const inbox = fakeInbox(home);
    inboxes.push(inbox);
    const { client } = await startShim(home, cwd, "sess-wake", nudgeEnv(inbox));
    const asked = await client.callTool({ name: "waggle_ask", arguments: question });
    const text = textOf(asked);
    const caseId = text.match(/case_id":"(c_[^"]+)"/)![1];
    expect(text).toContain("Waggle will wake you with a message when the human answers");
    expect(text).toContain("end your turn");
    expect(text).toContain(`call waggle_check once with case_id ${caseId}`);
    // The agent's turn has ended: no wait is open. The human answers.
    await submitReply(home, caseId);
    await waitFor(() => inbox.connections.length === 1 && inbox.connections[0].length === 2);
    const user = JSON.parse(inbox.connections[0][1]);
    expect(user.message.content).toBe(
      `Waggle: the human answered "Pick a layout". Call waggle_check with case_id ${caseId} now.`,
    );
    // Woken: one waggle_check returns the reply.
    const checked = await client.callTool({ name: "waggle_check", arguments: { case_id: caseId } });
    expect(textOf(checked)).toContain(REPLY_TEXT);
    // Delivered: no second nudge.
    await new Promise((r) => setTimeout(r, 200));
    expect(inbox.connections.length).toBe(1);
  });

  test("no nudge while a waggle_check is open: it takes the reply", async () => {
    const { home, cwd } = setup();
    const inbox = fakeInbox(home);
    inboxes.push(inbox);
    const { client } = await startShim(home, cwd, "sess-held", { ...nudgeEnv(inbox), KNOCK_ASK_WAIT_MS: "100" });
    const caseId = textOf(await client.callTool({ name: "waggle_ask", arguments: question })).match(
      /case_id":"(c_[^"]+)"/,
    )![1];
    await client.close();
    transports.pop();
    clients.pop();
    const second = await startShim(home, cwd, "sess-held", { ...nudgeEnv(inbox), KNOCK_ASK_WAIT_MS: "4000" });
    const waiting = second.client.callTool({ name: "waggle_check", arguments: { case_id: caseId } });
    await new Promise((r) => setTimeout(r, 300));
    await submitReply(home, caseId);
    expect(textOf(await waiting)).toContain(REPLY_TEXT);
    await new Promise((r) => setTimeout(r, 250));
    expect(inbox.connections.length).toBe(0);
  });

  test("a session that cannot be woken keeps the polling text and gets no nudge", async () => {
    const { home, cwd } = setup();
    const { client } = await startShim(home, cwd, "sess-poll", {});
    const asked = await client.callTool({ name: "waggle_ask", arguments: question });
    const text = textOf(asked);
    expect(text).not.toContain("wake you");
    expect(text).toContain("Call waggle_check with this case_id to get the human's reply.");
  });
});

describe("a reply inside the nudge window still wakes the session (WAG-368)", () => {
  test("the second reply of a talk is nudged when the one-minute window ends, not dropped", async () => {
    const saved = process.env.KNOCK_NUDGE_INTERVAL_MS;
    const savedQuiet = process.env.KNOCK_WORKING_QUIET_MS;
    process.env.KNOCK_NUDGE_INTERVAL_MS = "700";
    // The check is activity: without this the nudge would hold for the busy session, not for the window.
    process.env.KNOCK_WORKING_QUIET_MS = "0";
    try {
      const { home, cwd } = setup();
      const inbox = fakeInbox(home);
      inboxes.push(inbox);
      const { client } = await startShim(home, cwd, "sess-talk", { ...nudgeEnv(inbox), KNOCK_NUDGE_INTERVAL_MS: "700" });
      const caseId = textOf(await client.callTool({ name: "waggle_ask", arguments: question })).match(
        /case_id":"(c_[^"]+)"/,
      )![1];
      const rpc = await app(home);
      const talk = (key: string, message: string) =>
        rpc.request("reply.submit", { case_id: caseId, idempotency_key: key, intent: "discuss", message, comments: [], captures: [] });
      await talk("t1", "First question");
      await waitFor(() => inbox.connections.length === 1 && inbox.connections[0].length === 2);
      expect(textOf(await client.callTool({ name: "waggle_check", arguments: { case_id: caseId } }))).toContain("First question");
      // The human answers again at once: the case had its nudge a moment ago.
      await talk("t2", "Second question");
      await new Promise((r) => setTimeout(r, 250));
      expect(inbox.connections.length).toBe(1);
      // The window ends: the second reply wakes the session.
      await waitFor(() => inbox.connections.length === 2 && inbox.connections[1].length === 2, 4000);
      expect(textOf(await client.callTool({ name: "waggle_check", arguments: { case_id: caseId } }))).toContain("Second question");
      // Delivered: nothing more.
      await new Promise((r) => setTimeout(r, 1000));
      expect(inbox.connections.length).toBe(2);
    } finally {
      if (saved === undefined) delete process.env.KNOCK_NUDGE_INTERVAL_MS;
      else process.env.KNOCK_NUDGE_INTERVAL_MS = saved;
      if (savedQuiet === undefined) delete process.env.KNOCK_WORKING_QUIET_MS;
      else process.env.KNOCK_WORKING_QUIET_MS = savedQuiet;
    }
  });
});

describe("pendingText and waitMsFor", () => {
  const result = { status: "pending" as const, case_id: "c_1", waited_s: 130 };
  test("pending text is chosen per session", () => {
    expect(pendingMode({ runtime: "claude", nudge: { canNudge: true }, clientName: "claude-code" }, {})).toBe("wake");
    expect(pendingMode({ runtime: "claude", nudge: { canNudge: false }, clientName: "claude-ai" }, {})).toBe("desktop");
    expect(pendingMode({ runtime: "codex", nudge: { canNudge: false }, clientName: "codex" }, {})).toBe("poll");
    expect(pendingText(result, "wake")).toContain("will wake you");
    expect(pendingText(result, "wake")).not.toContain("Do not end your turn");
    expect(pendingText(result, "desktop")).toContain("Do not end your turn");
    expect(pendingText(result, "desktop")).toContain("2 minutes");
    expect(pendingText(result, "poll")).toContain("Call waggle_check with this case_id");
  });

  const base = { runtime: "claude" as const, nudge: { canNudge: false }, waitOverrideMs: null };
  test("Claude Code waits 9 minutes, other clients 50 s, the override wins", () => {
    const ccEnv = { CLAUDE_CODE_SESSION_ID: "x" };
    expect(waitMsFor({ ...base, nudge: { canNudge: true }, clientName: "claude-code" }, {})).toBe(540000);
    expect(waitMsFor({ ...base, clientName: null }, ccEnv)).toBe(540000);
    expect(waitMsFor({ ...base, clientName: "claude-ai" }, ccEnv)).toBe(50000);
    expect(waitMsFor({ ...base, clientName: "claude-ai" }, {})).toBe(50000);
    expect(waitMsFor({ ...base, clientName: null }, {})).toBe(50000);
    expect(waitMsFor({ ...base, runtime: "codex", clientName: "codex" }, ccEnv)).toBe(50000);
    expect(waitMsFor({ ...base, clientName: "claude-code", waitOverrideMs: 300 }, {})).toBe(300);
  });

  test("MCP_TOOL_TIMEOUT keeps the wait 30 s under the limit, never below 50 s", () => {
    const s = { ...base, clientName: "claude-code" };
    expect(waitMsFor(s, { MCP_TOOL_TIMEOUT: "120000" })).toBe(90000);
    expect(waitMsFor(s, { MCP_TOOL_TIMEOUT: "30000" })).toBe(50000);
    expect(waitMsFor(s, { MCP_TOOL_TIMEOUT: "100000000" })).toBe(540000);
  });
});

describe("images only when needed (HAIL-181)", () => {
  test("a plain choice reply carries no image, even with a capture attached", async () => {
    const { home, cwd } = setup();
    const { client } = await startShim(home, cwd, "sess-img", {});
    const caseId = textOf(await client.callTool({ name: "waggle_ask", arguments: question })).match(
      /case_id":"(c_[^"]+)"/,
    )![1];
    const rpc = await app(home);
    await rpc.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "k2",
      choice: "a",
      comments: [],
      captures: [{ id: "cap1", revision: 1, png_base64: "/9j/AAAA", annotated_png_base64: "/9j/AAAA", taken_at: "2026-10-05T00:00:00Z" }],
    });
    const checked = await client.callTool({ name: "waggle_check", arguments: { case_id: caseId } });
    const content = (checked as { content: { type: string }[] }).content;
    expect(content.filter((c) => c.type === "image")).toHaveLength(0);
    expect(textOf(checked)).toContain("Choice: a");
  });
});
