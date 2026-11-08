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
import pkg from "../package.json" with { type: "json" };
import { rmrf, rpcConnect, tmpHome, type RpcClient, type RpcLine } from "./helpers";

// HAIL-76: the nudge. Every socket here is a FAKE unix socket server in a temp dir.
// No test connects to a real Claude Code messaging socket or reads a real token.

const TOKEN = "tok-SECRET-0123456789";
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

describe("nudge text and version gating", () => {
  test("the posted line names the ask and the case, never a reply", () => {
    expect(nudgeText("Pick a layout", "c_1")).toBe(
      'Waggle: the human answered "Pick a layout". Call waggle_check with case_id c_1 now.',
    );
    expect(nudgeText('A "quoted"\nline', "c_2")).toBe(
      "Waggle: the human answered \"A 'quoted' line\". Call waggle_check with case_id c_2 now.",
    );
    expect(nudgeText("x".repeat(300), "c_3").length).toBeLessThan(220);
  });

  test("readMessagingEnv needs both values", () => {
    expect(readMessagingEnv({})).toBeNull();
    expect(readMessagingEnv({ CLAUDE_CODE_MESSAGING_SOCKET: "/s" })).toBeNull();
    expect(readMessagingEnv({ CLAUDE_CODE_MESSAGING_TOKEN: "t" })).toBeNull();
    expect(readMessagingEnv({ CLAUDE_CODE_MESSAGING_SOCKET: "/s", CLAUDE_CODE_MESSAGING_TOKEN: "t" })).toEqual({
      socket: "/s",
      token: "t",
    });
  });

  test("parseVersion", () => {
    expect(parseVersion("2.1.285")).toBe("2.1.285");
    expect(parseVersion("2.1.285 (Claude Code)\n")).toBe("2.1.285");
    expect(parseVersion("v22.1.0")).toBe("22.1.0");
    expect(parseVersion("claude")).toBeNull();
  });

  const probe = (exe: string | null, versionOut: string | null = null): VersionProbe => ({
    exePath: () => exe,
    run: () => versionOut,
  });
  const messagingEnv = { CLAUDE_CODE_MESSAGING_SOCKET: "/s", CLAUDE_CODE_MESSAGING_TOKEN: "t" };

  test("version comes from the binary name, then from `claude --version`", () => {
    expect(detectClaudeVersion(1, {}, probe("/home/u/.local/share/claude/versions/2.1.285"))).toBe("2.1.285");
    expect(detectClaudeVersion(1, {}, probe("/usr/local/bin/claude", "2.1.230 (Claude Code)"))).toBe("2.1.230");
    expect(detectClaudeVersion(1, { CLAUDE_CODE_ENTRYPOINT: "/x/versions/2.2.0" }, probe(null))).toBe("2.2.0");
  });

  test("a parent that is not Claude Code has an unknown version", () => {
    expect(detectClaudeVersion(1, { CLAUDE_CODE_ENTRYPOINT: "cli" }, probe("/usr/bin/node", "v22.1.0"))).toBeNull();
    expect(detectClaudeVersion(1, {}, probe(null))).toBeNull();
    expect(detectClaudeVersion(1, {}, probe("/usr/local/bin/claude", "garbage"))).toBeNull();
  });

  test("can_nudge gating: env missing, old version, unknown version, enough version", () => {
    const at = (v: string) => probe(`/x/versions/${v}`);
    expect(resolveNudgeSupport(1, {}, at("2.1.285")).canNudge).toBe(false);
    expect(resolveNudgeSupport(1, { CLAUDE_CODE_MESSAGING_SOCKET: "/s" }, at("2.1.285")).canNudge).toBe(false);
    expect(resolveNudgeSupport(1, messagingEnv, at("2.1.223")).canNudge).toBe(false);
    expect(resolveNudgeSupport(1, messagingEnv, probe("/usr/bin/node")).canNudge).toBe(false);
    expect(resolveNudgeSupport(1, messagingEnv, at(MIN_NUDGE_CLAUDE_VERSION)).canNudge).toBe(true);
    expect(resolveNudgeSupport(1, messagingEnv, at("3.0.0")).canNudge).toBe(true);
    // The token is handed back only when the session can be nudged.
    expect(resolveNudgeSupport(1, messagingEnv, at("2.1.223")).messaging).toBeNull();
  });
});

describe("postNudge against a fake inbox socket", () => {
  test("writes the auth line first, then exactly one user line", async () => {
    const dir = tmpHome();
    homes.push(dir);
    const inbox = fakeInbox(dir);
    inboxes.push(inbox);
    await postNudge({ socket: inbox.path, token: TOKEN }, "hello there");
    await waitFor(() => inbox.connections.length === 1 && inbox.connections[0].length === 2);
    const [auth, user] = inbox.connections[0].map((l) => JSON.parse(l));
    expect(auth).toEqual({ type: "auth", token: TOKEN });
    expect(user).toEqual({ type: "user", message: { role: "user", content: "hello there" } });
    expect(inbox.connections[0].join("\n").split(TOKEN).length - 1).toBe(1);
  });

  test("an unreachable socket rejects with a message that has no token", async () => {
    const dir = tmpHome();
    homes.push(dir);
    const err = await postNudge({ socket: join(dir, "missing.sock"), token: TOKEN }, "x").catch((e) => e as Error);
    expect(err).toBeInstanceOf(Error);
    expect((err as Error).message).not.toContain(TOKEN);
  });
});

describe("session.nudge end to end (real shim, real daemon, fake inbox)", () => {
  test("hello reports can_nudge true, and a nudge posts one line into the inbox", async () => {
    const { home, inbox, rpc, caseId } = await queuedReply();
    const sessions = (await rpc.request("sessions.list", {})).result as { can_nudge: boolean }[];
    expect(sessions[0].can_nudge).toBe(true);

    const notifications: RpcLine[] = [];
    const sub = await app(home);
    await sub.request("events.subscribe", {}, notifications);

    const res = await rpc.request("session.nudge", { case_id: caseId });
    expect(res.result).toEqual({ sent: true });

    await waitFor(() => inbox.connections.length === 1 && inbox.connections[0].length === 2);
    const [auth, user] = inbox.connections[0].map((l) => JSON.parse(l));
    expect(auth).toEqual({ type: "auth", token: TOKEN });
    expect(user.type).toBe("user");
    expect(user.message.role).toBe("user");
    expect(user.message.content).toBe(
      `Waggle: the human answered "Pick a layout". Call waggle_check with case_id ${caseId} now.`,
    );
    // No reply content in the line.
    expect(inbox.connections[0].join("\n")).not.toContain("colours");
    expect(inbox.connections[0].join("\n")).not.toContain(REPLY_TEXT);

    // The event reaches a subscriber.
    await waitFor(() => {
      const extra = sub as unknown as { conn: { lines: string[] } };
      return extra.conn.lines.some((l) => l.includes("session.nudged"));
    });
    const line = (sub as unknown as { conn: { lines: string[] } }).conn.lines.find((l) =>
      l.includes("session.nudged"),
    )!;
    const event = JSON.parse(line).params;
    expect(event.type).toBe("session.nudged");
    expect(event.case_id).toBe(caseId);
    expect(typeof event.at).toBe("string");
  });

  test("the token appears nowhere else: not in the daemon database, sessions or events", async () => {
    const { home, rpc, caseId, store } = await queuedReply();
    await rpc.request("session.nudge", { case_id: caseId });
    const sessions = JSON.stringify((await rpc.request("sessions.list", {})).result);
    const cases = JSON.stringify((await rpc.request("cases.get", { id: caseId })).result);
    expect(sessions).not.toContain(TOKEN);
    expect(cases).not.toContain(TOKEN);
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    for (const name of readdirSync(home)) {
      if (!name.startsWith("knock.db")) continue;
      expect(readFileSync(join(home, name)).includes(Buffer.from(TOKEN))).toBe(false);
    }
  });

  test("one nudge per case per minute, then rate_limited", async () => {
    const { rpc, caseId, inbox } = await queuedReply();
    expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({ sent: true });
    for (let i = 0; i < 2; i++) {
      expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({
        sent: false,
        reason: "rate_limited",
      });
    }
    await waitFor(() => inbox.connections.length === 1);
    await new Promise((r) => setTimeout(r, 100));
    expect(inbox.connections.length).toBe(1);
  });

  test("the daemon lets a nudge through again after the window", async () => {
    process.env.KNOCK_NUDGE_INTERVAL_MS = "200";
    try {
      const { rpc, caseId, inbox } = await queuedReply({ shimEnv: { KNOCK_NUDGE_INTERVAL_MS: "200" } });
      expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({ sent: true });
      await new Promise((r) => setTimeout(r, 300));
      expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({ sent: true });
      await waitFor(() => inbox.connections.length === 2);
    } finally {
      delete process.env.KNOCK_NUDGE_INTERVAL_MS;
    }
  });

  test("the shim keeps its own window when the daemon's record is gone", async () => {
    process.env.KNOCK_NUDGE_INTERVAL_MS = "100";
    try {
      const { rpc, caseId, inbox } = await queuedReply({ shimEnv: { KNOCK_NUDGE_INTERVAL_MS: "60000" } });
      expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({ sent: true });
      await new Promise((r) => setTimeout(r, 200));
      expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({
        sent: false,
        reason: "rate_limited",
      });
      await new Promise((r) => setTimeout(r, 100));
      expect(inbox.connections.length).toBe(1);
    } finally {
      delete process.env.KNOCK_NUDGE_INTERVAL_MS;
    }
  });

  test("the token is never written to the shim's stderr", async () => {
    const { rpc, caseId, inbox, home } = await queuedReply();
    await rpc.request("session.nudge", { case_id: caseId });
    await waitFor(() => inbox.connections.length === 1);
    inbox.stop();
    rmSync(join(home, "inbox.sock"), { force: true });
    await rpc.request("session.nudge", { case_id: caseId });
    expect(shimStderr.join("")).not.toContain(TOKEN);
  });

  test("already_picked_up once the agent fetched the reply", async () => {
    const { rpc, caseId, client } = await queuedReply();
    const checked = await client.callTool({ name: "waggle_check", arguments: { case_id: caseId } });
    expect(textOf(checked)).toContain("Detailed");
    expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({
      sent: false,
      reason: "already_picked_up",
    });
  });

  test("not_supported when the shim has no messaging socket", async () => {
    const { rpc, caseId, home } = await queuedReply({ env: {} });
    const sessions = (await rpc.request("sessions.list", {})).result as { can_nudge: boolean }[];
    expect(sessions[0].can_nudge).toBe(false);
    expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({
      sent: false,
      reason: "not_supported",
    });
    expect(home).toBeTruthy();
  });

  test("not_supported when Claude Code is older than 2.1.224", async () => {
    const { rpc, caseId } = await queuedReply({
      env: {
        CLAUDE_CODE_MESSAGING_SOCKET: "/tmp/never-used.sock",
        CLAUDE_CODE_MESSAGING_TOKEN: TOKEN,
        KNOCK_SHIM_TEST_PARENT_EXE: "/fake/claude/versions/2.1.200",
      },
    });
    expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({
      sent: false,
      reason: "not_supported",
    });
  });

  test("not_supported when the version is unknown", async () => {
    const { rpc, caseId } = await queuedReply({
      env: {
        CLAUDE_CODE_MESSAGING_SOCKET: "/tmp/never-used.sock",
        CLAUDE_CODE_MESSAGING_TOKEN: TOKEN,
        KNOCK_SHIM_TEST_PARENT_EXE: "/usr/bin/node",
      },
    });
    expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({
      sent: false,
      reason: "not_supported",
    });
  });

  test("session_closed after the shim goes away", async () => {
    const { rpc, caseId, transport, store } = await queuedReply();
    await transport.close();
    await waitFor(() => store.findSession("sess-nudge")?.state !== "live");
    expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({
      sent: false,
      reason: "session_closed",
    });
  });

  test("post_failed when the inbox socket is gone, and it does not use up a nudge", async () => {
    const { rpc, caseId, inbox, home } = await queuedReply();
    inbox.stop();
    rmSync(join(home, "inbox.sock"), { force: true });
    for (let i = 0; i < 4; i++) {
      expect((await rpc.request("session.nudge", { case_id: caseId })).result).toEqual({
        sent: false,
        reason: "post_failed",
      });
    }
  });

  test("an unknown case is a case-not-found error", async () => {
    const { rpc } = await queuedReply();
    const res = await rpc.request("session.nudge", { case_id: "c_nope" });
    expect(res.error?.code).toBe(-32001);
  });
});
