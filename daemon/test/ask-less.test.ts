import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { EventBus } from "../src/events";
import { startRpcServer, type RpcServer } from "../src/server";
import { Store } from "../src/store";
import { UsageLogger } from "../src/usage";
import { guideIndex, getGuide } from "../src/guide";
import { askLessSection } from "../src/guide/asks";
import type { Event, KnockAskInput } from "../src/protocol";
import { DEFAULT_ASK_LESS, type AskLess } from "../src/protocol";
import { rmrf, rpcConnect, stageIncoming, tmpHome, type RpcClient } from "./helpers";

// WAG-412: "Let the agent decide small things". The daemon decides a small ask by the operator's rule.

const ALL_ON: AskLess = { enabled: true, rules: { naming: true, wording: true, formatting: true, tests: true } };
const NAMING_ONLY: AskLess = { enabled: true, rules: { naming: true, wording: false, formatting: false, tests: false } };

const small: KnockAskInput = {
  title: "Name the helper",
  need: "What do we call the helper?",
  why: "Two names fit.",
  recommendation: "a",
  recommendation_why: "It is shorter.",
  options: [
    { id: "a", label: "Call it parseRow", title: "parseRow" },
    { id: "b", label: "Call it readRow", title: "readRow" },
  ],
  category: "naming",
};

const homes: string[] = [];
const closers: Array<() => void> = [];
afterEach(() => {
  for (const close of closers.splice(0).reverse()) {
    try {
      close();
    } catch {
      // Already closed.
    }
  }
  for (const home of homes.splice(0)) rmrf(home);
});

function setup(askLess?: AskLess) {
  const home = tmpHome();
  homes.push(home);
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const events: Event[] = [];
  bus.subscribe((e) => events.push(e));
  const store = new Store(db, home, bus, new UsageLogger(db, home));
  if (askLess) store.setAskLess(askLess);
  const task = store.createTask({ name: "work", project: "waggle" });
  const sessionId = "sess-ask-less";
  store.createSession(task.id, { id: sessionId, cwd: "/work", branch: null, pid: 4242 });
  closers.push(() => db.close());
  return { home, db, store, task, sessionId, events };
}

const usageRows = (db: Database) => db.query(`SELECT * FROM usage WHERE event = 'ask_auto_decided'`).all() as Record<string, unknown>[];

describe("ask less: off by default", () => {
  test("a fresh store has the master and every rule off", () => {
    const { store } = setup();
    expect(store.getAskLess()).toEqual(DEFAULT_ASK_LESS);
    expect(DEFAULT_ASK_LESS.enabled).toBe(false);
    expect(Object.values(DEFAULT_ASK_LESS.rules).every((v) => v === false)).toBe(true);
  });

  test("turning the master off turns every rule off", () => {
    const { store } = setup(ALL_ON);
    expect(store.getAskLess()).toEqual(ALL_ON);
    expect(store.setAskLess({ enabled: false, rules: ALL_ON.rules })).toEqual(DEFAULT_ASK_LESS);
    expect(store.getAskLess()).toEqual(DEFAULT_ASK_LESS);
    // Turned on again, the rules do not come back by themselves.
    expect(store.setAskLess({ enabled: true, rules: DEFAULT_ASK_LESS.rules }).rules.naming).toBe(false);
  });
});

describe("ask less: the guards", () => {
  test("the rule decides when all guards pass", () => {
    const { store, task, db, events } = setup(NAMING_ONLY);
    const created = store.createCase(task.id, small);
    expect(created.status).toBe("resolved");
    expect(created.auto_decided).toMatchObject({ category: "naming", rule: "ask_less_naming", choice: "a", answer: "parseRow" });
    expect(store.listCases("needs_you")).toHaveLength(0);
    // No "case.created": no notification, no phone message, no share. "case.updated" refreshes the app.
    expect(events.map((e) => e.type)).toEqual(["case.updated"]);
    const row = store.caseById(created.id)!;
    expect(row.status).toBe("resolved");
    expect(row.auto_decided?.answer).toBe("parseRow");
    expect(row.latest_reply_id).toBeNull();
    // The usage log: category slug and rule id only.
    const rows = usageRows(db);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ category: "naming", rule_id: "ask_less_naming" });
    const text = JSON.stringify(rows);
    expect(text).not.toContain("parseRow");
    expect(text).not.toContain("helper");
  });

  test("master off: the category is ignored and the ask reaches the queue", () => {
    const { store, task, db, events } = setup();
    const created = store.createCase(task.id, small);
    expect(created.status).toBe("needs_you");
    expect(created.auto_decided).toBeUndefined();
    expect(events.map((e) => e.type)).toEqual(["case.created"]);
    expect(usageRows(db)).toHaveLength(0);
    // ask_created carries no category while the feature is off.
    expect(db.query(`SELECT category FROM usage WHERE event = 'ask_created'`).get()).toEqual({ category: null });
  });

  test("rule off for the category: the ask reaches the queue", () => {
    const { store, task } = setup(NAMING_ONLY);
    const created = store.createCase(task.id, { ...small, category: "wording" });
    expect(created.status).toBe("needs_you");
    expect(created.auto_decided).toBeUndefined();
  });

  test("an unknown category reaches the queue", () => {
    const { store, task, db } = setup(ALL_ON);
    const created = store.createCase(task.id, { ...small, category: "deploy" });
    expect(created.status).toBe("needs_you");
    expect(usageRows(db)).toHaveLength(0);
    expect(db.query(`SELECT category FROM usage WHERE event = 'ask_created'`).get()).toEqual({ category: null });
  });

  test("an ask with no category reaches the queue", () => {
    const { store, task } = setup(ALL_ON);
    const { category: _drop, ...plain } = small;
    expect(store.createCase(task.id, plain).status).toBe("needs_you");
  });

  test("an ask with no recommendation reaches the queue", () => {
    const { store, task } = setup(ALL_ON);
    const created = store.createCase(task.id, {
      title: "Name the helper",
      need: "What do we call the helper?",
      why: "Two names fit.",
      category: "naming",
      items: [{ id: "name", options: [{ id: "a", label: "parseRow" }, { id: "b", label: "readRow" }] }],
    });
    expect(created.status).toBe("needs_you");
    expect(created.auto_decided).toBeUndefined();
  });

  test("a review always reaches the queue", () => {
    const { store, task, home } = setup(ALL_ON);
    mkdirSync(join(home, "work"), { recursive: true });
    writeFileSync(join(home, "work", "plan.md"), "# Plan\n");
    const created = store.createCase(task.id, {
      kind: "review",
      title: "Review the plan",
      need: "Is the plan right?",
      why: "It ships tomorrow.",
      category: "naming",
      recommendation: "approve",
      recommendation_why: "It reads well.",
      artifact: stageIncoming(home, join(home, "work"), { type: "markdown", path: "plan.md" }),
    });
    expect(created.kind).toBe("review");
    expect(created.status).toBe("needs_you");
    expect(created.auto_decided).toBeUndefined();
  });

  test("a follow-up to a human reply nobody has picked up reaches the queue", () => {
    const { store, task } = setup(ALL_ON);
    const first = store.createCase(task.id, { ...small, category: undefined });
    store.submitReply(first.id, { idempotency_key: "k1", choice: "b", comments: [], captures: [] });
    const follow = store.createCase(task.id, { ...small, title: "Name the next helper", follows: first.id });
    expect(follow.status).toBe("needs_you");
    // Once the agent picked the reply up, a follow-up may be decided.
    const reply = store.getCase(first.id)!.replies[0]!;
    store.markReplyDelivered(reply.id);
    const later = store.createCase(task.id, { ...small, title: "Name a third helper", follows: first.id });
    expect(later.status).toBe("resolved");
  });

  test("a multi-select ask reaches the queue", () => {
    const { store, task } = setup(ALL_ON);
    const created = store.createCase(task.id, { ...small, select: "many", recommendation: ["a"] });
    expect(created.status).toBe("needs_you");
  });
});

describe("ask less: the app side", () => {
  test("the auto-decided list holds the decided cases, newest first", () => {
    const { store, task } = setup(NAMING_ONLY);
    const one = store.createCase(task.id, small);
    const two = store.createCase(task.id, { ...small, title: "Name the other helper", need: "And this one?" });
    expect(store.listAutoDecided().map((c) => c.id)).toEqual([two.id, one.id]);
    expect(store.listAutoDecided("2999-01-01T00:00:00.000Z")).toHaveLength(0);
  });

  test("Change my mind reopens the case; the new pick is a normal reply for the live session", () => {
    const { store, task, events } = setup(NAMING_ONLY);
    const one = store.createCase(task.id, small);
    const two = store.createCase(task.id, { ...small, title: "Name the other helper", need: "And this one?" });
    events.length = 0;
    const reopened = store.changeMind(one.id)!;
    expect(reopened.status).toBe("needs_you");
    expect(reopened.auto_decided).toBeUndefined();
    expect(events.map((e) => e.type)).toEqual(["case.updated"]);
    expect(store.listAutoDecided().map((c) => c.id)).toEqual([two.id]);
    const reply = store.submitReply(one.id, { idempotency_key: "k-change", choice: "b", comments: [], captures: [] });
    expect(reply.state).toBe("queued");
    expect(store.caseById(one.id)!.status).toBe("waiting_on_agent");
    // A case nobody decided, and a case that already has a reply, stay as they are.
    expect(store.changeMind(one.id)!.status).toBe("waiting_on_agent");
    expect(store.changeMind("c_missing")).toBeNull();
  });

  test("Change my mind on a case whose session ended reports session_unreachable", () => {
    const { store, task, sessionId } = setup(NAMING_ONLY);
    const created = store.createCase(task.id, small);
    store.setSessionState(sessionId, "ended");
    store.changeMind(created.id);
    const reply = store.submitReply(created.id, { idempotency_key: "k-late", choice: "b", comments: [], captures: [] });
    expect(reply.state).toBe("failed");
    expect(reply.reason).toBe("session_unreachable");
  });

  test("the dock badge count ignores an auto-decided case", () => {
    const { store, task } = setup(NAMING_ONLY);
    store.createCase(task.id, small);
    expect(store.listCases("needs_you")).toHaveLength(0);
    expect(store.listCases("waiting_on_agent")).toHaveLength(0);
  });
});

describe("ask less: the usage log", () => {
  test("ask_created carries the category slug and the export holds the new event", () => {
    const { store, task, db, home } = setup(NAMING_ONLY);
    store.createCase(task.id, small);
    expect(db.query(`SELECT category FROM usage WHERE event = 'ask_created'`).get()).toEqual({ category: "naming" });
    const out = new UsageLogger(db, home).tools.export(join(home, "export.json"), { app: "0.0.0", plugin: null, macos: "26" });
    const body = JSON.parse(readFileSync(out.json_path, "utf8")) as { usage_events: Record<string, unknown>[] };
    const auto = body.usage_events.find((e) => e.event === "ask_auto_decided");
    expect(auto).toMatchObject({ category: "naming", rule_id: "ask_less_naming" });
    expect(JSON.stringify(body.usage_events)).not.toContain("parseRow");
  });
});

describe("ask less: the guide", () => {
  test("the category line shows only while the master is on", () => {
    expect(guideIndex(undefined, undefined, DEFAULT_ASK_LESS)).not.toContain("category");
    expect(guideIndex()).not.toContain("category");
    expect(getGuide("writing-an-ask", undefined, undefined, undefined, DEFAULT_ASK_LESS)).not.toContain("auto_decided");
    const on = guideIndex(undefined, undefined, NAMING_ONLY);
    expect(on).toContain("category");
    expect(on).toContain("Categories that are on: naming.");
    expect(on).toContain("Never send category for a choice that deletes data, spends money or ships.");
    expect(getGuide("writing-an-ask", undefined, undefined, undefined, ALL_ON)).toContain("auto_decided");
  });

  test("the line is plain, with no em-dash", () => {
    expect(askLessSection(ALL_ON)).not.toContain("—");
    expect(askLessSection({ enabled: true, rules: DEFAULT_ASK_LESS.rules })).toContain("No category is on now.");
  });
});

describe("ask less: over the socket", () => {
  let server: RpcServer | undefined;
  afterEach(() => server?.stop());

  async function boot() {
    const ctx = setup();
    server = startRpcServer({ socketPath: join(ctx.home, "knock.sock"), store: ctx.store, bus: new EventBus(), version: "0.1.0", onRestart: () => {} });
    const client: RpcClient = await rpcConnect(join(ctx.home, "knock.sock"));
    closers.push(() => client.close());
    await client.request("session.hello", { session_id: "sock-1", cwd: join(ctx.home, "work"), parent_pid: 4242 });
    return { ...ctx, client };
  }

  test("settings.get reads off, settings.set normalises, guide.get follows the master", async () => {
    const { client } = await boot();
    expect((await client.request("settings.get", { key: "askLess" })).result).toEqual({ key: "askLess", value: DEFAULT_ASK_LESS });
    expect(((await client.request("guide.get", {})).result as { text: string }).text).not.toContain("category");
    const set = await client.request("settings.set", { key: "askLess", value: NAMING_ONLY });
    expect(set.result).toEqual({ key: "askLess", value: NAMING_ONLY });
    expect(((await client.request("guide.get", {})).result as { text: string }).text).toContain("Categories that are on: naming.");
    const off = await client.request("settings.set", { key: "askLess", value: { enabled: false, rules: ALL_ON.rules } });
    expect(off.result).toEqual({ key: "askLess", value: DEFAULT_ASK_LESS });
    // A word outside the fixed shape is refused.
    const bad = await client.request("settings.set", { key: "askLess", value: { enabled: true, rules: { naming: true } } });
    expect(bad.error).toBeDefined();
  });

  test("case.create returns the decision and cases.auto_decided lists it", async () => {
    const { client, store } = await boot();
    store.setAskLess(NAMING_ONLY);
    const res = await client.request("case.create", { ...small, client_request_id: "req-ask-less-1" });
    expect(res.error).toBeUndefined();
    const created = res.result as { id: string; status: string; auto_decided: { category: string; answer: string } };
    expect(created.status).toBe("resolved");
    expect(created.auto_decided).toMatchObject({ category: "naming", answer: "parseRow" });
    // The same call again returns the same decided case.
    const again = (await client.request("case.create", { ...small, client_request_id: "req-ask-less-1" })).result as { id: string; auto_decided?: unknown };
    expect(again.id).toBe(created.id);
    expect(again.auto_decided).toBeDefined();
    const listed = (await client.request("cases.auto_decided", {})).result as { id: string }[];
    expect(listed.map((c) => c.id)).toEqual([created.id]);
    expect(((await client.request("cases.list", { status: "needs_you" })).result as unknown[]).length).toBe(0);
    // Change my mind over the socket: the case is open again and leaves the decided list.
    const mind = await client.request("case.change_mind", { case_id: created.id });
    expect((mind.result as { status: string }).status).toBe("needs_you");
    expect(((await client.request("cases.auto_decided", {})).result as unknown[]).length).toBe(0);
    expect(((await client.request("cases.list", { status: "needs_you" })).result as unknown[]).length).toBe(1);
  });
});
