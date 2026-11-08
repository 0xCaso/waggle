import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import pkg from "../package.json" with { type: "json" };
import { EventBus } from "../src/events";
import { startRpcServer, type RpcServer } from "../src/server";
import { cwdSlug, humanizeTool, sessionContext } from "../src/sessions/context";
import { MOD_ATTACHED_MS, ModRegistry } from "../src/sessions/live";
import { Store } from "../src/store";
import { rmrf, rpcConnect, tmpHome, type RpcClient } from "./helpers";

// HAIL-134: the Claude Code mod's RPCs (mod.report, mod.poll, case.open), the live
// state that outranks transcript inference while fresh, and the nudge through the mod.

const question = {
  kind: "question",
  title: "Pick a **layout**",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact layout with small rows", title: "Compact" },
    { id: "b", label: "Detailed layout" },
  ],
};

const homes: string[] = [];
const servers: RpcServer[] = [];
const clients: RpcClient[] = [];
const savedProjects = process.env.KNOCK_CLAUDE_PROJECTS;
const savedInterval = process.env.KNOCK_NUDGE_INTERVAL_MS;

afterEach(() => {
  for (const c of clients.splice(0)) c.close();
  for (const s of servers.splice(0)) s.stop();
  for (const h of homes.splice(0)) rmrf(h);
  process.env.KNOCK_CLAUDE_PROJECTS = savedProjects;
  if (savedInterval === undefined) delete process.env.KNOCK_NUDGE_INTERVAL_MS;
  else process.env.KNOCK_NUDGE_INTERVAL_MS = savedInterval;
});

async function setup(mods = new ModRegistry()) {
  const home = tmpHome();
  homes.push(home);
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  const socketPath = join(home, "knock.sock");
  servers.push(startRpcServer({ socketPath, store, bus, version: pkg.version, mods }));
  const connect = async () => {
    const c = await rpcConnect(socketPath);
    clients.push(c);
    return c;
  };
  return { home, store, mods, connect, db };
}

// A session as the shim makes it: hello, then an ask.
async function sessionWithAsk(connect: () => Promise<RpcClient>, id = "sess-1", cwd = "/tmp/proj") {
  const shim = await connect();
  await shim.request("session.hello", { session_id: id, cwd, parent_pid: process.pid, runtime: "claude" });
  const created = await shim.request("case.create", question);
  return { shim, caseId: (created.result as { id: string }).id };
}

const answer = (rpc: RpcClient, caseId: string, extra: object) =>
  rpc.request("reply.submit", { case_id: caseId, idempotency_key: `k-${Math.random()}`, comments: [], captures: [], ...extra });

describe("ModRegistry", () => {
  test("turn events set the phase; tool calls count; no prompt text is held", () => {
    let t = 1_000_000;
    const mods = new ModRegistry(() => t);
    expect(mods.live("s")).toBeNull();
    mods.report("s", "prompt.submit");
    expect(mods.live("s")).toBeNull(); // a prompt alone says nothing about the phase
    mods.report("s", "turn.start");
    t += 1000;
    mods.report("s", "tool.call", "Bash");
    mods.report("s", "tool.call", "Edit", 3);
    const live = mods.live("s")!;
    expect(live.phase).toBe("working");
    expect(live.tool_count).toBe(4);
    expect(live.last_tool).toBe("Edit");
    t += 1000;
    mods.report("s", "turn.complete");
    expect(mods.live("s")!.phase).toBe("idle");
    expect(JSON.stringify(mods.live("s"))).not.toContain("prompt text");
  });

  test("live state is fresh only while the mod polls", () => {
    let t = 1_000_000;
    const mods = new ModRegistry(() => t);
    mods.report("s", "turn.start");
    expect(mods.attached("s")).toBe(true);
    t += MOD_ATTACHED_MS + 1;
    expect(mods.attached("s")).toBe(false);
    expect(mods.live("s")).toBeNull();
    mods.beginPoll("s");
    t += MOD_ATTACHED_MS * 3; // a long poll in flight keeps it attached
    expect(mods.live("s")?.phase).toBe("working");
    mods.endPoll("s");
    expect(mods.attached("s")).toBe(true);
  });

  test("a tool call without a turn.start still means working", () => {
    const mods = new ModRegistry();
    mods.report("s", "tool.call", "Read");
    expect(mods.live("s")?.phase).toBe("working");
  });
});

describe("mod.report and mod.poll", () => {
  test("rejects prompt text, unknown events and empty ids", async () => {
    const { connect } = await setup();
    const rpc = await connect();
    const bad = await rpc.request("mod.report", { session_id: "s", event: "prompt.submit", text: "my secret prompt" });
    expect(bad.error?.code).toBe(-32602);
    expect((await rpc.request("mod.report", { session_id: "s", event: "turn.explode" })).error?.code).toBe(-32602);
    expect((await rpc.request("mod.report", { session_id: "", event: "turn.start" })).error?.code).toBe(-32602);
    expect((await rpc.request("mod.report", { session_id: "s", event: "turn.start" })).result).toEqual({ ok: true });
  });

  test("poll shows the oldest open ask with a plain title, then the answer", async () => {
    const { connect } = await setup();
    const { caseId } = await sessionWithAsk(connect);
    const app = await connect();
    const first = (await app.request("mod.poll", { session_id: "sess-1" })).result as any;
    expect(first.open_ask).toMatchObject({ case_id: caseId, title: "Pick a layout" });
    expect(first.open_count).toBe(1);
    expect(first.answer).toBeNull();
    expect(first.nudge).toBeNull();

    await answer(app, caseId, { choice: "a", message: "Go **small**, thanks." });
    const after = (await app.request("mod.poll", { session_id: "sess-1" })).result as any;
    expect(after.open_ask).toBeNull();
    expect(after.open_count).toBe(0);
    expect(after.answer).toMatchObject({ case_id: caseId, choice: "Compact", note: "Go small, thanks." });
    expect(after.sig).not.toBe(first.sig);
  });

  test("waiting_since is the creation of a plain ask and the latest update of a plan case", async () => {
    const { connect, db } = await setup();
    const { shim, caseId } = await sessionWithAsk(connect);
    const app = await connect();
    const plain = ((await app.request("mod.poll", { session_id: "sess-1" })).result as any).open_ask;
    expect(plain.waiting_since).toBe(plain.created_at);
    // A case made 60 minutes ago whose latest update came 2 minutes ago.
    const created = new Date(Date.now() - 60 * 60_000).toISOString();
    const updated = new Date(Date.now() - 2 * 60_000).toISOString();
    db.query("UPDATE cases SET created_at = ?, updated_at = ? WHERE id = ?").run(created, updated, caseId);
    const aged = ((await app.request("mod.poll", { session_id: "sess-1" })).result as any).open_ask;
    expect(aged.created_at).toBe(created);
    expect(aged.waiting_since).toBe(updated);
    // A real waggle_update moves it to the update's time.
    const before = Date.now();
    await shim.request("case.update", { case_id: caseId, message: "Revised" });
    const after = ((await app.request("mod.poll", { session_id: "sess-1" })).result as any).open_ask;
    expect(Date.parse(after.waiting_since)).toBeGreaterThanOrEqual(before);
    expect(after.created_at).toBe(created);
  });

  test("an option without a title answers with its label; a note-only answer has no choice", async () => {
    const { connect } = await setup();
    const { caseId } = await sessionWithAsk(connect);
    const app = await connect();
    await answer(app, caseId, { choice: "b" });
    let r = (await app.request("mod.poll", { session_id: "sess-1" })).result as any;
    expect(r.answer).toMatchObject({ choice: "Detailed layout", note: null });
    const second = await sessionWithAsk(connect, "sess-2");
    await answer(app, second.caseId, { message: "Neither, make it a list." });
    r = (await app.request("mod.poll", { session_id: "sess-2" })).result as any;
    expect(r.answer).toMatchObject({ choice: null, note: "Neither, make it a list." });
  });

  test("poll counts the asks of other sessions, never this session's own", async () => {
    const { connect } = await setup();
    await sessionWithAsk(connect, "sess-1");
    await sessionWithAsk(connect, "sess-2");
    await sessionWithAsk(connect, "sess-3");
    const app = await connect();
    const one = (await app.request("mod.poll", { session_id: "sess-1" })).result as any;
    expect(one.open_count).toBe(1);
    expect(one.other_open_count).toBe(2);
    const none = (await app.request("mod.poll", { session_id: "sess-unknown" })).result as any;
    expect(none.open_count).toBe(0);
    expect(none.other_open_count).toBe(3);
    expect(none.sig).not.toBe(one.sig);
  });

  test("a session sees only its own asks; an unknown session sees none", async () => {
    const { connect } = await setup();
    await sessionWithAsk(connect, "sess-1");
    const app = await connect();
    const other = (await app.request("mod.poll", { session_id: "sess-other" })).result as any;
    expect(other.open_ask).toBeNull();
    expect(other.open_count).toBe(0);
  });

  test("a long poll wakes when the human answers", async () => {
    const { connect } = await setup();
    const { caseId } = await sessionWithAsk(connect);
    const app = await connect();
    const poller = await connect();
    const sig = ((await app.request("mod.poll", { session_id: "sess-1" })).result as any).sig;
    const started = Date.now();
    const pending = poller.request("mod.poll", { session_id: "sess-1", wait_ms: 10_000, seen: sig });
    await new Promise((r) => setTimeout(r, 100));
    await answer(app, caseId, { choice: "a" });
    const result = (await pending).result as any;
    expect(Date.now() - started).toBeLessThan(3000);
    expect(result.answer?.choice).toBe("Compact");
  });

  test("a poll whose seen sig is already stale answers at once", async () => {
    const { connect } = await setup();
    await sessionWithAsk(connect);
    const app = await connect();
    const started = Date.now();
    const r = (await app.request("mod.poll", { session_id: "sess-1", wait_ms: 10_000, seen: "old" })).result as any;
    expect(Date.now() - started).toBeLessThan(1000);
    expect(r.open_count).toBe(1);
  });

  test("a long poll with nothing new returns at wait_ms", async () => {
    const { connect } = await setup();
    const { shim } = await sessionWithAsk(connect);
    void shim;
    const app = await connect();
    const sig = ((await app.request("mod.poll", { session_id: "sess-1" })).result as any).sig;
    const started = Date.now();
    await app.request("mod.poll", { session_id: "sess-1", wait_ms: 300, seen: sig });
    expect(Date.now() - started).toBeGreaterThanOrEqual(290);
  });

  test("case.open emits case.open_requested; an unknown case is an error", async () => {
    const { connect } = await setup();
    const { caseId } = await sessionWithAsk(connect);
    const app = await connect();
    await app.request("events.subscribe", {});
    const seen: any[] = [];
    expect((await app.request("case.open", { case_id: caseId }, seen)).result).toEqual({ ok: true });
    const event = seen.find((l) => l.params?.type === "case.open_requested") ?? (await app.nextLine());
    expect(event.params).toMatchObject({ type: "case.open_requested", case_id: caseId });
    expect((await app.request("case.open", { case_id: "c_missing" })).error?.code).toBe(-32001);
  });

  test("case.open without a case asks the app for its queue", async () => {
    const { connect } = await setup();
    const app = await connect();
    await app.request("events.subscribe", {});
    const seen: any[] = [];
    expect((await app.request("case.open", {}, seen)).result).toEqual({ ok: true });
    const event = seen.find((l) => l.params?.type === "case.open_requested") ?? (await app.nextLine());
    expect(event.params.type).toBe("case.open_requested");
    expect(event.params.case_id).toBeUndefined();
  });
});

describe("live state outranks the transcript", () => {
  function transcriptFor(cwd: string, sessionId: string, mtimeAgoMs: number): string {
    const root = join(tmpHome(), "projects");
    homes.push(root);
    const dir = join(root, cwdSlug(cwd));
    mkdirSync(dir, { recursive: true });
    const file = join(dir, `${sessionId}.jsonl`);
    writeFileSync(file, JSON.stringify({ type: "ai-title", aiTitle: "Transcript title" }) + "\n");
    const when = new Date(Date.now() - mtimeAgoMs);
    require("node:fs").utimesSync(file, when, when);
    process.env.KNOCK_CLAUDE_PROJECTS = root;
    return root;
  }

  const base = { id: "s1", cwd: "/tmp/live-proj", runtime: "claude", state: "live" };
  const idle = (extra = {}) => ({
    phase: "idle" as const,
    since: new Date().toISOString(),
    last_tool: null,
    last_tool_at: null,
    tool_count: 0,
    last_event: "turn.complete" as const,
    last_event_at: new Date().toISOString(),
    ...extra,
  });

  test("a fresh idle state beats a transcript that is still growing", async () => {
    const root = transcriptFor(base.cwd, "s1", 1000); // written a second ago: inferred busy
    expect((await sessionContext(base, { root }))?.growing).toBe(true);
    const ctx = await sessionContext(base, { root, live: idle() });
    expect(ctx?.growing).toBe(false);
    expect(ctx?.live?.phase).toBe("idle");
    expect(ctx?.title).toBe("Transcript title"); // the transcript still supplies the title
  });

  test("a fresh working state beats a transcript that went quiet", async () => {
    const root = transcriptFor(base.cwd, "s1", 10 * 60_000);
    expect((await sessionContext(base, { root }))?.growing).toBe(false);
    const ctx = await sessionContext(base, { root, live: idle({ phase: "working", last_tool: "Bash", last_tool_at: new Date().toISOString() }) });
    expect(ctx?.growing).toBe(true);
    expect(ctx?.last_action).toBe("Ran a command");
  });

  test("live state alone gives a context when no transcript exists", async () => {
    process.env.KNOCK_CLAUDE_PROJECTS = join(tmpHome(), "none");
    const ctx = await sessionContext(base, { live: idle({ phase: "working" }) });
    expect(ctx?.growing).toBe(true);
    expect(ctx?.title).toBeNull();
  });

  test("without live state the transcript reading is unchanged", async () => {
    const root = transcriptFor(base.cwd, "s1", 1000);
    const ctx = await sessionContext(base, { root, live: null });
    expect(ctx?.growing).toBe(true);
    expect(ctx?.live).toBeUndefined();
  });

  test("sessions.list reports a stale mod as no live state", async () => {
    let t = Date.now();
    const mods = new ModRegistry(() => t);
    const { connect } = await setup(mods);
    const { shim } = await sessionWithAsk(connect, "sess-1");
    void shim;
    process.env.KNOCK_CLAUDE_PROJECTS = join(tmpHome(), "none");
    const app = await connect();
    mods.report("sess-1", "turn.start");
    let list = (await app.request("sessions.list", {})).result as any[];
    expect(list[0].context.live.phase).toBe("working");
    expect(list[0].context.growing).toBe(true);
    expect(list[0].can_nudge).toBe(true); // the mod can nudge
    t += MOD_ATTACHED_MS + 1000;
    list = (await app.request("sessions.list", {})).result as any[];
    expect(list[0].context?.live).toBeUndefined();
    expect(list[0].can_nudge).toBe(false);
  });
});

describe("the plugin's tool names", () => {
  test("transcript inference reads plugin tool names like the user entry's", () => {
    expect(humanizeTool("mcp__plugin_knock_knock__knock_ask", { title: "Pick" })).toBe("Needs your decision: Pick");
    expect(humanizeTool("mcp__plugin_knock_knock__knock_check", {})).toBe("Waited for your answer");
  });
});

describe("nudge through the mod", () => {
  async function replied(mods: ModRegistry) {
    const ctx = await setup(mods);
    const { caseId } = await sessionWithAsk(ctx.connect);
    const app = await ctx.connect();
    await answer(app, caseId, { choice: "a" });
    return { ...ctx, app, caseId };
  }

  test("the mod's poll takes the nudge; no messaging socket is needed", async () => {
    const { app, caseId, connect } = await replied(new ModRegistry());
    const poller = await connect();
    const first = (await poller.request("mod.poll", { session_id: "sess-1" })).result as any;
    const polling = poller.request("mod.poll", { session_id: "sess-1", wait_ms: 5000, seen: first.sig });
    await new Promise((r) => setTimeout(r, 50));
    const sent = (await app.request("session.nudge", { case_id: caseId })).result;
    expect(sent).toEqual({ sent: true });
    const nudge = ((await polling).result as any).nudge;
    expect(nudge.case_id).toBe(caseId);
    expect(nudge.text).toBe(`Waggle: the human answered "Pick a **layout**". Call waggle_check with case_id ${caseId} now.`);
    // The reply text never rides on the nudge.
    expect(JSON.stringify(nudge)).not.toContain("Compact");
  });

  test("one nudge per case per interval holds, and nudge.failed gives the window back", async () => {
    const { app, caseId, connect, store } = await replied(new ModRegistry());
    const poller = await connect();
    // Keep the mod attached with a poll in flight, and take the nudge.
    const attach = poller.request("mod.poll", { session_id: "sess-1" });
    await attach;
    const waiting = poller.request("mod.poll", { session_id: "sess-1", wait_ms: 3000, seen: ((await attach).result as any).sig });
    await new Promise((r) => setTimeout(r, 50));
    expect((await app.request("session.nudge", { case_id: caseId })).result).toEqual({ sent: true });
    expect(((await waiting).result as any).nudge?.case_id).toBe(caseId);
    // A second click inside the interval is refused.
    expect((await app.request("session.nudge", { case_id: caseId })).result).toEqual({ sent: false, reason: "rate_limited" });
    const nudges = () => store.nudgeTarget(caseId)!.reply!.nudge_count;
    expect(nudges()).toBe(1);
    // The mod could not submit it: the window is given back.
    await app.request("mod.report", { session_id: "sess-1", event: "nudge.failed", case_id: caseId });
    expect(nudges()).toBe(0);
    // A report for a nudge the mod never took changes nothing.
    await app.request("mod.report", { session_id: "sess-1", event: "nudge.failed", case_id: caseId });
    expect(nudges()).toBe(0);
  });

  test("a mod that never polls again falls through to post_failed without a socket", async () => {
    process.env.KNOCK_NUDGE_INTERVAL_MS = "60000";
    const mods = new ModRegistry(Date.now, 150);
    const { app, caseId, connect, store } = await replied(mods);
    const poller = await connect();
    await poller.request("mod.poll", { session_id: "sess-1" }); // attached, then silent
    const result = (await app.request("session.nudge", { case_id: caseId })).result;
    expect(result).toEqual({ sent: false, reason: "post_failed" });
    expect(store.nudgeTarget(caseId)!.reply!.nudge_count).toBe(0);
  });

  test("a session without the mod and without a socket is not supported, as before", async () => {
    const { app, caseId } = await replied(new ModRegistry());
    expect((await app.request("session.nudge", { case_id: caseId })).result).toEqual({
      sent: false,
      reason: "not_supported",
    });
  });
});

describe("session.send_prompt (HAIL-169)", () => {
  const prompt = 'Read "/tmp/a b/PRD.md". Find the open decisions.';

  test("a live session with the mod takes the prompt text through its poll", async () => {
    const { connect } = await setup(new ModRegistry());
    await sessionWithAsk(connect);
    const mod = await connect();
    const polling = mod.request("mod.poll", { session_id: "sess-1", wait_ms: 5000 });
    const app = await connect();
    const sent = (await app.request("session.send_prompt", { session_id: "sess-1", text: prompt })).result;
    expect(sent).toEqual({ sent: true });
    const nudge = ((await polling).result as any).nudge;
    expect(nudge.text).toBe(prompt);
    expect(nudge.case_id).toStartWith("prompt-");
  });

  test("a failed submit gives nothing back to the case window", async () => {
    const { connect, store } = await setup(new ModRegistry());
    await sessionWithAsk(connect);
    const mod = await connect();
    const polling = mod.request("mod.poll", { session_id: "sess-1", wait_ms: 5000 });
    const app = await connect();
    await app.request("session.send_prompt", { session_id: "sess-1", text: prompt });
    const id = ((await polling).result as any).nudge.case_id;
    const reported = await app.request("mod.report", { session_id: "sess-1", event: "nudge.failed", case_id: id });
    expect(reported.result).toEqual({ ok: true });
    expect(store.listSessions().length).toBe(1);
  });

  test("a session without the mod is not supported", async () => {
    const { connect } = await setup(new ModRegistry());
    await sessionWithAsk(connect);
    const app = await connect();
    expect((await app.request("session.send_prompt", { session_id: "sess-1", text: prompt })).result).toEqual({
      sent: false,
      reason: "not_supported",
    });
  });

  test("an unknown session is closed; a mod that never polls fails the post", async () => {
    const mods = new ModRegistry(undefined, 50);
    const { connect } = await setup(mods);
    await sessionWithAsk(connect);
    const app = await connect();
    expect((await app.request("session.send_prompt", { session_id: "nope", text: prompt })).result).toEqual({
      sent: false,
      reason: "session_closed",
    });
    const mod = await connect();
    await mod.request("mod.poll", { session_id: "sess-1" }); // attached, then silent
    expect((await app.request("session.send_prompt", { session_id: "sess-1", text: prompt })).result).toEqual({
      sent: false,
      reason: "post_failed",
    });
  });
});
