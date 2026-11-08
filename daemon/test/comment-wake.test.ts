import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { RelaySharing } from "../src/connectors/relay";
import { MemorySecretStore } from "../src/connectors/secrets";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import pkg from "../package.json" with { type: "json" };
import { FakeRelay } from "./fake-relay";
import { rmrf, rpcConnect, tmpHome, type RpcClient } from "./helpers";

// WAG-394: a team comment wakes the session (the same wake as a reply, with words that say it is a comment), ends
// a waggle_check at once, and waggle_update can reply to it. Fake inbox and fake relay: no real service.

const TOKEN = "tok-SECRET-0123456789";
process.env.KNOCK_AUTO_NUDGE_MS = "50";

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

const homes: string[] = [];
const servers: RpcServer[] = [];
const clients: Client[] = [];
const transports: StdioClientTransport[] = [];
const rpcs: RpcClient[] = [];
const stops: (() => void)[] = [];

afterEach(async () => {
  for (const t of transports.splice(0)) await t.close().catch(() => {});
  for (const c of clients.splice(0)) await c.close().catch(() => {});
  for (const c of rpcs.splice(0)) c.close();
  for (const s of stops.splice(0)) s();
  for (const s of servers.splice(0)) {
    try {
      s.stop();
    } catch {
      // Already stopped.
    }
  }
  for (const h of homes.splice(0)) rmrf(h);
});

function fakeInbox(dir: string) {
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
          connections[socket.data.index]!.push(socket.data.buffer.slice(0, nl));
          socket.data.buffer = socket.data.buffer.slice(nl + 1);
        }
      },
      close() {},
      error() {},
    },
  });
  stops.push(() => server.stop(true));
  return { path, connections };
}

async function setup(wake: boolean) {
  const home = tmpHome();
  homes.push(home);
  const cwd = join(home, "work");
  mkdirSync(cwd, { recursive: true });
  const relay = new FakeRelay();
  stops.push(() => relay.stop());
  const bus = new EventBus();
  const store = new Store(new Database(join(home, "knock.db")), home, bus);
  const secrets = new MemorySecretStore();
  secrets.set("relay-device", relay.issueToken());
  const sharing = new RelaySharing({ store, bus, secrets, baseUrl: relay.baseUrl, pollMs: 3_600_000, log: () => {} });
  sharing.start();
  stops.push(() => sharing.stop());
  servers.push(startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: pkg.version, relay: sharing }));
  const inbox = fakeInbox(home);
  const env: Record<string, string> = wake
    ? { CLAUDE_CODE_MESSAGING_SOCKET: inbox.path, CLAUDE_CODE_MESSAGING_TOKEN: TOKEN, KNOCK_SHIM_TEST_PARENT_EXE: "/fake/claude/versions/2.1.285" }
    : {};
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(import.meta.dir, "..", "src", "index.ts"), "mcp"],
    env: { KNOCK_HOME: home, CLAUDE_CODE_SESSION_ID: "sess-comment", KNOCK_ASK_WAIT_MS: "400", ...env },
    cwd,
    stderr: "pipe",
  });
  const client = new Client({ name: "knock-test", version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);
  transports.push(transport);
  clients.push(client);
  const asked = await client.callTool({ name: "waggle_ask", arguments: question });
  const caseId = textOf(asked).match(/case_id":"(c_[^"]+)"/)![1]!;
  const rpc = await rpcConnect(join(home, "knock.sock"));
  rpcs.push(rpc);
  await rpc.request("sharing.set_enabled", { enabled: true });
  const shared = await rpc.request("sharing.start", { case_id: caseId, mode: "link" });
  expect(shared.error).toBeUndefined();
  return { home, store, relay, sharing, inbox, client, rpc, caseId, relayId: store.getRelayShare(caseId)!.relay_id };
}

function textOf(result: Awaited<ReturnType<Client["callTool"]>>): string {
  if (!("content" in result)) return "";
  return (result.content as { type: string; text?: string }[])
    .filter((c) => c.type === "text")
    .map((c) => c.text ?? "")
    .join("\n");
}

async function until(fn: () => boolean, ms = 5000): Promise<void> {
  const start = Date.now();
  while (!fn()) {
    if (Date.now() - start > ms) throw new Error("condition not met in time");
    await new Promise((r) => setTimeout(r, 20));
  }
}

describe("a team comment", () => {
  test("wakes a session Waggle can nudge, with words that say it is a comment", async () => {
    const { inbox, relay, relayId, rpc, caseId } = await setup(true);
    relay.addComment(relayId, { id: "k1", created_at: 10, body: "Why hourly?" });
    await rpc.request("sharing.refresh", { case_id: caseId });
    await until(() => inbox.connections.length === 1 && inbox.connections[0]!.length === 2);
    const user = JSON.parse(inbox.connections[0]![1]!);
    expect(user.message.content).toBe(
      `Waggle: your team commented on "Pick a layout". This is a comment, not an answer. Call waggle_check with case_id ${caseId} to read it.`,
    );
    expect(user.message.content).not.toContain("answered");
  });

  test("a late comment (after the decision) does not wake the agent by itself; a comment before it does", async () => {
    const { inbox, relay, relayId, rpc, caseId, store } = await setup(true);
    relay.addComment(relayId, { id: "k0", created_at: 10, body: "Before" });
    store.submitReply(caseId, { idempotency_key: "late-1", choice: "a", intent: "decision", comments: [], captures: [] });
    await rpc.request("sharing.refresh", { case_id: caseId });
    // The early comment is still new at the decision, so it still counts for the wake rule.
    expect(store.hasNewEarlyTeamComments(caseId)).toBe(true);
    store.markRelayCommentsGiven(caseId);
    relay.addComment(relayId, { id: "k1", created_at: Date.now() + 60_000, body: "After" });
    await rpc.request("sharing.refresh", { case_id: caseId });
    expect(store.hasNewEarlyTeamComments(caseId)).toBe(false);
    await new Promise((r) => setTimeout(r, 400));
    const said = inbox.connections.flat().filter((l) => l.includes("your team commented"));
    expect(said).toEqual([]);
  });

  test("makes no nudge for a session that cannot be woken", async () => {
    const { inbox, relay, relayId, rpc, caseId } = await setup(false);
    relay.addComment(relayId, { id: "k1", created_at: 10 });
    await rpc.request("sharing.refresh", { case_id: caseId });
    await new Promise((r) => setTimeout(r, 300));
    expect(inbox.connections.length).toBe(0);
  });

  test("makes no nudge for a comment the agent already has", async () => {
    const { inbox, relay, relayId, rpc, caseId, client } = await setup(true);
    // A check is open: it takes the comment itself.
    const waiting = client.callTool({ name: "waggle_check", arguments: { case_id: caseId } });
    await new Promise((r) => setTimeout(r, 100));
    relay.addComment(relayId, { id: "k1", created_at: 10, body: "Now?" });
    await rpc.request("sharing.refresh", { case_id: caseId });
    const text = textOf(await waiting);
    expect(text).toContain("Now?");
    await new Promise((r) => setTimeout(r, 250));
    expect(inbox.connections.length).toBe(0);
  });

  test("ends a waggle_check at once, marks the comment new, and a second check does not", async () => {
    const { relay, relayId, rpc, caseId, client } = await setup(false);
    relay.addComment(relayId, { id: "k1", created_at: 10, body: "Why hourly?" });
    await rpc.request("sharing.refresh", { case_id: caseId });
    const started = Date.now();
    const first = await client.callTool({ name: "waggle_check", arguments: { case_id: caseId } });
    expect(Date.now() - started).toBeLessThan(300);
    const text = textOf(first);
    expect(text).toContain("Why hourly?");
    expect(text).toContain("[guest] NEW");
    expect(text).toContain(`"new":true`);
    expect(text).toContain("untrusted input");
    expect(text).toContain("reply_to_comment");
    // The second check waits (the wait is 400 ms here) and the comment is no longer new.
    const second = Date.now();
    const again = await client.callTool({ name: "waggle_check", arguments: { case_id: caseId } });
    expect(Date.now() - second).toBeGreaterThanOrEqual(300);
    expect(textOf(again)).not.toContain("[guest] NEW");
    expect(textOf(again)).not.toContain(`"new":true`);
    expect(textOf(again)).toContain("Why hourly?");
  });
});

describe("waggle_update reply_to_comment", () => {
  test("posts the reply as the Agent, and the update itself goes through", async () => {
    const { relay, relayId, rpc, caseId, client } = await setup(false);
    relay.addComment(relayId, { id: "k1", created_at: 10, body: "Why hourly?" });
    await rpc.request("sharing.refresh", { case_id: caseId });
    const res = await client.callTool({
      name: "waggle_update",
      arguments: { case_id: caseId, message: "Looking at it.", working: true, reply_to_comment: { comment_id: "k1", body: "Because the cache fills hourly." } },
    });
    expect(textOf(res)).toContain("Progress note sent");
    expect(textOf(res)).toContain("Your reply to the comment is on the shared page.");
    const posted = relay.cases.get(relayId)!.comments.find((c) => c.author_kind === "agent")!;
    expect(posted).toMatchObject({ body: "Because the cache fills hourly.", parent_id: "k1", author_name: "Agent" });
  });

  test("says in one line when the reply could not be posted, and still updates", async () => {
    const { relay, relayId, rpc, caseId, client } = await setup(false);
    relay.addComment(relayId, { id: "k1", created_at: 10 });
    await rpc.request("sharing.refresh", { case_id: caseId });
    relay.cases.get(relayId)!.commentsClosed = true;
    const res = await client.callTool({
      name: "waggle_update",
      arguments: { case_id: caseId, message: "Update.", working: true, reply_to_comment: { comment_id: "k1", body: "A reply" } },
    });
    expect(textOf(res)).toContain("Progress note sent");
    expect(textOf(res)).toContain("Your reply to the comment was not posted.");
    expect(textOf(res)).toContain("Comments are closed.");
    const unknown = await client.callTool({
      name: "waggle_update",
      arguments: { case_id: caseId, message: "Update.", working: true, reply_to_comment: { comment_id: "nope", body: "A reply" } },
    });
    expect(textOf(unknown)).toContain("not on this case");
  });
});

describe("the owner's sockets", () => {
  test("reply, resolve, close, mark seen and the feed", async () => {
    const { relay, relayId, rpc, caseId } = await setup(false);
    relay.addComment(relayId, { id: "k1", created_at: 10, body: "Why hourly?", author_name: "Bea" });
    await rpc.request("sharing.refresh", { case_id: caseId });
    expect((await rpc.request("sharing.unread", {})).result).toEqual({ cases: [{ case_id: caseId, count: 1 }] });
    const feed = (await rpc.request("sharing.take_notifications", {})).result as { items: { author_name: string }[] };
    expect(feed.items.map((i) => i.author_name)).toEqual(["Bea"]);
    const replied = (await rpc.request("sharing.reply", { case_id: caseId, parent_id: "k1", body: "By design." })).result as { comments: { parent_id: string | null }[] };
    expect(replied.comments.map((c) => c.parent_id)).toEqual([null, "k1"]);
    const resolved = (await rpc.request("sharing.resolve", { case_id: caseId, comment_id: "k1", resolved: true })).result as { comments: { resolved_at: string | null }[] };
    expect(resolved.comments[0]!.resolved_at).not.toBeNull();
    const closed = (await rpc.request("sharing.close_comments", { case_id: caseId, closed: true })).result as { comments_closed: boolean };
    expect(closed.comments_closed).toBe(true);
    const bad = await rpc.request("sharing.reply", { case_id: caseId, parent_id: "k1", body: "x" });
    expect(JSON.stringify(bad.error)).toContain("Comments are closed.");
    expect((await rpc.request("sharing.mark_seen", { case_id: caseId })).result).toEqual({ cases: [] });
  });
});
