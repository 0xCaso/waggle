import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { COMMENTS_EVERY_MS, RelaySharing } from "../src/connectors/relay";
import { MemorySecretStore } from "../src/connectors/secrets";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import type { Event } from "../src/protocol";
import { FakeRelay } from "./fake-relay";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

// WAG-394: the comment loop. Threads, the agent's cursor, the owner's replies and resolve, the answer sent to the
// page, the ask kept fresh, follow-ups on the same link, and the fetch schedule. Against a fake relay on localhost.

let home: string;
let relay: FakeRelay;
let store: Store;
let bus: EventBus;
let secrets: MemorySecretStore;
let sharing: RelaySharing;
let caseId: string;
let events: Event[];
let t: number;
let fetches: number;

function makeSharing(): RelaySharing {
  return new RelaySharing({
    store,
    bus,
    secrets,
    baseUrl: relay.baseUrl,
    pollMs: 3_600_000,
    retryMs: 60_000,
    now: () => t,
    fetch: (input, init) => {
      fetches++;
      return fetch(input, init);
    },
    log: () => {},
  });
}

function newCase(title: string, extra: Record<string, unknown> = {}): string {
  // A follow-up belongs to the task of the case it follows.
  const follows = typeof extra.follows === "string" ? extra.follows : null;
  const taskId = follows ? store.getCase(follows)!.case.task_id : store.createTask({ name: title, project: "waggle" }).id;
  return store.createCase(taskId, {
    kind: "question",
    title,
    need: "Pick one",
    why: "w",
    recommendation: "a",
    recommendation_why: "r",
    options: [
      { id: "a", title: "Flag first", label: "Flag the page first" },
      { id: "b", title: "Cache first", label: "Cache the page first" },
    ],
    ...extra,
  }).id;
}

function addMarkdown(id: string, text: string): void {
  const cwd = join(home, "work");
  mkdirSync(cwd, { recursive: true });
  writeFileSync(join(cwd, "plan.md"), text);
  store.createRevision(id, stageIncoming(home, cwd, { type: "markdown", path: "./plan.md" }));
}

async function until(fn: () => boolean, ms = 3000): Promise<void> {
  const start = Date.now();
  while (!fn()) {
    if (Date.now() - start > ms) throw new Error("condition not met in time");
    await new Promise((r) => setTimeout(r, 10));
  }
}

const relayId = (id = caseId) => store.getRelayShare(id)!.relay_id;
const tick = (s: RelaySharing) => (s as unknown as { tick(): Promise<void> }).tick();
const patches = () => relay.calls.filter((c) => c.method === "PATCH");

beforeEach(async () => {
  home = tmpHome();
  relay = new FakeRelay();
  bus = new EventBus();
  events = [];
  bus.subscribe((e) => events.push(e));
  store = new Store(new Database(join(home, "knock.db")), home, bus);
  secrets = new MemorySecretStore();
  secrets.set("relay-device", relay.issueToken());
  t = 1_000_000;
  fetches = 0;
  sharing = makeSharing();
  sharing.setEnabled(true);
  caseId = newCase("Which plan?");
  addMarkdown(caseId, "# Plan");
  await sharing.share(caseId, "link");
  sharing.start();
});

afterEach(() => {
  sharing.stop();
  relay.stop();
  rmrf(home);
});

describe("G9: the agent sees new comments only", () => {
  test("a comment is new until a result goes to the agent, and the list stays whole", async () => {
    relay.addComment(relayId(), { id: "k1", created_at: 10, body: "First" });
    await sharing.refresh(caseId);
    expect(sharing.commentsForAgent(caseId).map((c) => [c.id, c.new])).toEqual([["k1", true]]);
    sharing.markGivenToAgent(caseId);
    relay.addComment(relayId(), { id: "k2", created_at: 20, body: "Second" });
    await sharing.refresh(caseId);
    const list = sharing.commentsForAgent(caseId);
    expect(list.map((c) => c.id)).toEqual(["k1", "k2"]);
    expect(list[0]!.new).toBeUndefined();
    expect(list[1]!.new).toBe(true);
  });

  test("a team comment says it is new to the wake and the wait; the owner's and the agent's do not", async () => {
    expect(sharing.hasNewComments(caseId)).toBe(false);
    relay.addComment(relayId(), { id: "k1", created_at: 10, author_kind: "owner", author_name: "Me" });
    await sharing.refresh(caseId);
    expect(sharing.hasNewComments(caseId)).toBe(false);
    relay.addComment(relayId(), { id: "k2", created_at: 20 });
    await sharing.refresh(caseId);
    expect(sharing.hasNewComments(caseId)).toBe(true);
    sharing.markGivenToAgent(caseId);
    expect(sharing.hasNewComments(caseId)).toBe(false);
  });

  test("an area comment with no words under it still tells the agent where", async () => {
    relay.addComment(relayId(), { id: "k1", created_at: 10, box: { x: 10, y: 20, w: 100, h: 50, vw: 800, near: "" } });
    relay.addComment(relayId(), { id: "k2", created_at: 11, box: { x: 0, y: 0, w: 40, h: 40, vw: 500, near: "image shot.png" } });
    await sharing.refresh(caseId);
    const [a, b] = sharing.commentsForAgent(caseId);
    expect(a!.area).toBe("a region 100 by 50 px at 10, 20");
    expect(b!.area).toBe("image shot.png");
  });

  test("threads and resolve reach the agent", async () => {
    relay.addComment(relayId(), { id: "k1", created_at: 10 });
    relay.addComment(relayId(), { id: "k2", created_at: 11, parent_id: "k1", body: "Reply" });
    relay.cases.get(relayId())!.comments[0]!.resolved_at = 50;
    relay.cases.get(relayId())!.comments[0]!.resolved_by = "Ada";
    await sharing.refresh(caseId);
    const list = sharing.commentsForAgent(caseId);
    expect(list.map((c) => [c.id, c.reply_to, c.resolved])).toEqual([
      ["k1", null, true],
      ["k2", "k1", true],
    ]);
    // The page reopens the thread: the next fetch shows it.
    relay.cases.get(relayId())!.comments[0]!.resolved_at = null;
    await sharing.refresh(caseId);
    expect(sharing.commentsForAgent(caseId).every((c) => !c.resolved)).toBe(true);
  });
});

describe("G8: tell the app", () => {
  test("a new team comment sends comment.added once, and an owner comment does not", async () => {
    relay.addComment(relayId(), { id: "k1", created_at: 10, author_kind: "owner" });
    await sharing.refresh(caseId);
    expect(events.filter((e) => e.type === "comment.added")).toHaveLength(0);
    relay.addComment(relayId(), { id: "k2", created_at: 20 });
    await sharing.refresh(caseId);
    await sharing.refresh(caseId);
    expect(events.filter((e) => e.type === "comment.added" && e.case_id === caseId)).toHaveLength(1);
  });

  test("unread marks and the notification feed follow the team comments", async () => {
    relay.addComment(relayId(), { id: "k1", created_at: 10, author_name: "Bea", body: "First line\nSecond line" });
    relay.addComment(relayId(), { id: "k2", created_at: 11, author_kind: "owner", author_name: "Me" });
    await sharing.refresh(caseId);
    expect(sharing.unread().cases).toEqual([{ case_id: caseId, count: 1 }]);
    expect(sharing.state(caseId).comments.map((c) => [c.id, c.unread])).toEqual([["k1", true], ["k2", false]]);
    const feed = sharing.takeNotifications().items;
    expect(feed).toEqual([{ case_id: caseId, case_title: "Which plan?", comment_id: "k1", author_name: "Bea", body: "First line\nSecond line" }]);
    // Told once.
    expect(sharing.takeNotifications().items).toEqual([]);
    // Opening the case clears the mark.
    expect(sharing.markSeen(caseId).cases).toEqual([]);
    expect(sharing.state(caseId).comments.every((c) => !c.unread)).toBe(true);
  });

  test("only the five newest unannounced comments are announced", async () => {
    for (let i = 1; i <= 8; i++) relay.addComment(relayId(), { id: `k${i}`, created_at: 10 + i, body: `c${i}` });
    await sharing.refresh(caseId);
    expect(sharing.takeNotifications().items.map((x) => x.body)).toEqual(["c4", "c5", "c6", "c7", "c8"]);
  });
});

describe("G11 and G12: replies and resolve", () => {
  beforeEach(async () => {
    relay.addComment(relayId(), { id: "k1", created_at: 10, body: "Why hourly?" });
    await sharing.refresh(caseId);
  });

  test("the owner replies, as the owner, and it is stored under the thread", async () => {
    const state = await sharing.replyAsOwner(caseId, "k1", "Every hour, by design.");
    const post = relay.calls.find((c) => c.method === "POST" && c.path.endsWith("/comments"))!;
    expect(post.body).toEqual({ parent_id: "k1", body: "Every hour, by design.", author_kind: "owner" });
    const reply = state.comments.find((c) => c.parent_id === "k1")!;
    expect(reply).toMatchObject({ author_kind: "owner", body: "Every hour, by design.", unread: false });
    // It is new for the agent, and it is no team comment.
    expect(sharing.commentsForAgent(caseId).find((c) => c.id === reply.id)!.new).toBe(true);
    expect(sharing.hasNewComments(caseId)).toBe(true); // k1 is still new
  });

  test("the owner comments on the page with no parent, on the newest round", async () => {
    const state = await sharing.commentAsOwner(caseId, "A note for the team.");
    const post = relay.calls.filter((c) => c.method === "POST" && c.path.endsWith("/comments")).pop()!;
    expect(post.body).toMatchObject({ body: "A note for the team.", author_kind: "owner" });
    expect((post.body as Record<string, unknown>).parent_id).toBeUndefined();
    expect(typeof (post.body as Record<string, unknown>).round_seq).toBe("number");
    const mine = state.comments.find((c) => c.body === "A note for the team.")!;
    expect(mine).toMatchObject({ author_kind: "owner", parent_id: null, unread: false });
  });

  test("an owner comment with no parent is refused before any call when the case is not shared", async () => {
    const before = relay.calls.length;
    await expect(sharing.commentAsOwner("c_none", "x")).rejects.toThrow("not shared");
    expect(relay.calls.length).toBe(before);
  });

  test("an owner comment with no parent gets the closed line when comments are closed", async () => {
    await sharing.closeComments(caseId, true);
    await expect(sharing.commentAsOwner(caseId, "late")).rejects.toThrow("Comments are closed.");
  });

  test("the agent replies, as the Agent, and the reply is not new for the agent", async () => {
    await sharing.replyToComment(caseId, "k1", "Fixed in round 2.", "agent");
    const post = relay.calls.find((c) => c.method === "POST" && c.path.endsWith("/comments"))!;
    expect(post.body).toMatchObject({ author_kind: "agent", parent_id: "k1" });
    const mine = sharing.commentsForAgent(caseId).find((c) => c.author_kind === "agent")!;
    expect(mine).toMatchObject({ author_name: "Agent", reply_to: "k1" });
    expect(mine.new).toBeUndefined();
  });

  test("a reply to a comment that is not on this case is refused before any call", async () => {
    const before = relay.calls.length;
    await expect(sharing.replyToComment(caseId, "nope", "x", "agent")).rejects.toThrow("not on this case");
    expect(relay.calls.length).toBe(before);
  });

  test("closed comments give a plain error line", async () => {
    await sharing.closeComments(caseId, true);
    await expect(sharing.replyAsOwner(caseId, "k1", "late")).rejects.toThrow("Comments are closed.");
  });

  test("resolve and reopen go up and show in the state", async () => {
    let state = await sharing.resolveComment(caseId, "k1", true);
    expect(state.comments[0]!.resolved_at).not.toBeNull();
    expect(relay.calls.some((c) => c.path.endsWith("/comments/k1/resolve"))).toBe(true);
    state = await sharing.resolveComment(caseId, "k1", false);
    expect(state.comments[0]!.resolved_at).toBeNull();
    expect(relay.calls.some((c) => c.path.endsWith("/comments/k1/reopen"))).toBe(true);
  });

  test("a resolve made on the page arrives with the next fetch", async () => {
    relay.cases.get(relayId())!.comments[0]!.resolved_at = 99;
    relay.cases.get(relayId())!.comments[0]!.resolved_by = "Owner";
    events.length = 0;
    await sharing.refresh(caseId);
    expect(sharing.state(caseId).comments[0]!.resolved_by).toBe("Owner");
    expect(events.some((e) => e.type === "case.updated")).toBe(true);
  });
});

describe("G13: the answer goes to the page", () => {
  const answer = (choice: string, message?: string, intent: "decision" | "discuss" = "decision") =>
    store.submitReply(caseId, { idempotency_key: `k-${Math.random()}`, choice, ...(message ? { message } : {}), intent, comments: [], captures: [] });

  test("a decision sends the chosen titles, the note and the time", async () => {
    const reply = answer("a", "Ship it on Friday");
    await until(() => patches().length === 1);
    expect(patches()[0]!.body).toEqual({
      status: "decided",
      decided: { options: ["Flag first"], note: "Ship it on Friday", at: Date.parse(reply.created_at) },
    });
    expect(relay.cases.get(relayId())!.status).toBe("decided");
    // The page is not opened again by the daemon's own ask check.
    await sharing.refresh(caseId);
    expect(relay.cases.get(relayId())!.status).toBe("decided");
    expect(patches()).toHaveLength(1);
  });

  test("keep talking decides nothing", async () => {
    answer("a", "What about cost?", "discuss");
    await new Promise((r) => setTimeout(r, 150));
    expect(patches()).toHaveLength(0);
  });

  test("a failed call is sent again by the tick, once", async () => {
    relay.failWhen = (call) => (call.method === "PATCH" ? 500 : null);
    answer("b");
    await until(() => patches().length >= 1);
    expect(relay.cases.get(relayId())!.status).toBe("open");
    relay.failWhen = null;
    t += 120_000;
    await tick(sharing);
    expect(relay.cases.get(relayId())!.status).toBe("decided");
    expect(relay.cases.get(relayId())!.decided).toMatchObject({ options: ["Cache first"] });
    const n = patches().length;
    t += 120_000;
    await tick(sharing);
    expect(patches()).toHaveLength(n);
  });

  test("with Sharing off, nothing is sent", async () => {
    // A second daemon view with Sharing off: no shares there.
    const other = newCase("Other");
    store.submitReply(other, { idempotency_key: "z", choice: "a", intent: "decision", comments: [], captures: [] });
    await new Promise((r) => setTimeout(r, 100));
    expect(patches()).toHaveLength(0);
  });
});

describe("G14: the ask stays fresh", () => {
  test("a changed need or options with no new artifact is a PATCH of the ask, not a round", async () => {
    const rounds = () => relay.cases.get(relayId())!.rounds.length;
    const before = rounds();
    store.updateCase(caseId, {
      case_id: caseId,
      message: "New idea",
      options: [
        { id: "x", title: "Third way", label: "Do a third thing" },
        { id: "y", title: "Fourth way", label: "Do a fourth thing" },
      ],
      recommendation: "x",
    });
    await until(() => patches().length === 1);
    expect((patches()[0]!.body as { ask: { options: { title: string }[] } }).ask.options.map((o) => o.title)).toEqual(["Third way", "Fourth way"]);
    // The case has one round (seq 1): the ask belongs to it.
    expect((patches()[0]!.body as { round_seq: number }).round_seq).toBe(1);
    expect(rounds()).toBe(before);
    expect((relay.cases.get(relayId())!.ask as { options: unknown[] }).options).toHaveLength(2);
  });

  test("an update that changes nothing in the ask sends nothing", async () => {
    store.updateCase(caseId, { case_id: caseId, message: "Still thinking", working: true });
    await new Promise((r) => setTimeout(r, 120));
    expect(patches()).toHaveLength(0);
  });

  test("a change that comes with a new artifact goes up with the round", async () => {
    addMarkdown(caseId, "# Plan v2");
    store.updateCase(caseId, { case_id: caseId, message: "v2", options: [{ id: "q", title: "Only way", label: "The only way" }], recommendation: "q" });
    await until(() => relay.cases.get(relayId())!.rounds.length === 2);
    await new Promise((r) => setTimeout(r, 120));
    expect(patches()).toHaveLength(0);
    expect((relay.cases.get(relayId())!.rounds[1]!.ask as { need: string }).need).toBe("Pick one");
  });
});

describe("G14: a follow-up on the same link", () => {
  test("a follow-up of a shared case goes on the same link as a new round with its ask", async () => {
    const next = newCase("Next step", { follows: caseId });
    await until(() => store.getRelayShare(next) !== null);
    expect(store.getRelayShare(next)!.url).toBe(store.getRelayShare(caseId)!.url);
    expect(store.getRelayShare(next)!.root_case_id).toBe(caseId);
    // No artifact yet: the ask goes up as a PATCH of the same link. It changes the page's question, not the
    // question of the first case's round.
    await until(() => patches().length === 1);
    expect(relay.cases.size).toBe(1);
    expect(patches()[0]!.body).toMatchObject({ round_seq: null, ask: { need: "Pick one" } });
    expect(relay.cases.get(relayId())!.rounds[0]!.ask).toEqual(expect.objectContaining({ need: "Pick one" }));
    addMarkdown(next, "# Next plan");
    await until(() => relay.cases.get(relayId())!.rounds.length === 2);
    expect((relay.cases.get(relayId())!.rounds[1]!.ask as { need: string }).need).toBe("Pick one");
    // One page, one count.
    expect(sharing.state(next).shared_count).toBe(1);
  });

  test("comments go to the case whose round they are on", async () => {
    const next = newCase("Next step", { follows: caseId });
    addMarkdown(next, "# Next plan");
    await until(() => relay.cases.get(relayId())!.rounds.length === 2);
    relay.addComment(relayId(), { id: "a1", created_at: 10, round_seq: 1 });
    relay.addComment(relayId(), { id: "b1", created_at: 11, round_seq: 2 });
    await sharing.refresh(caseId);
    await sharing.refresh(next);
    expect(sharing.state(caseId).comments.map((c) => c.id)).toEqual(["a1"]);
    expect(sharing.state(next).comments.map((c) => c.id)).toEqual(["b1"]);
  });

  test("stopping either case takes the page down for both, and the key goes once", async () => {
    const next = newCase("Next step", { follows: caseId });
    await until(() => store.getRelayShare(next) !== null);
    const rid = relayId();
    await sharing.stopSharing(next);
    expect(relay.cases.size).toBe(0);
    expect(store.getRelayShare(caseId)).toBeNull();
    expect(store.getRelayShare(next)).toBeNull();
    expect(secrets.get(`relay-owner.${rid}`)).toBeNull();
  });

  test("a follow-up of a case that is not shared is not shared", async () => {
    const lone = newCase("Lone");
    const next = newCase("Lone next", { follows: lone });
    await new Promise((r) => setTimeout(r, 100));
    expect(store.getRelayShare(next)).toBeNull();
  });

  test("with Sharing on but the first case stopped, a follow-up stays private", async () => {
    await sharing.stopSharing(caseId);
    const next = newCase("After stop", { follows: caseId });
    await new Promise((r) => setTimeout(r, 100));
    expect(store.getRelayShare(next)).toBeNull();
  });
});

describe("G10: the fetch schedule", () => {
  const gets = () => relay.calls.filter((c) => c.method === "GET" && c.path.includes("/comments")).length;

  test("every minute while the ask is open", async () => {
    const start = gets();
    await tick(sharing);
    await tick(sharing);
    expect(gets() - start).toBe(1);
    t += COMMENTS_EVERY_MS.active;
    await tick(sharing);
    expect(gets() - start).toBe(2);
  });

  test("after the answer: every minute for an hour, then every 10 minutes, then every hour after 7 days", async () => {
    store.submitReply(caseId, { idempotency_key: "z", choice: "a", intent: "decision", comments: [], captures: [] });
    await until(() => patches().length === 1);
    expect(store.getCase(caseId)!.case.status).not.toBe("needs_you");
    const updated = Date.parse(store.getCase(caseId)!.case.updated_at);
    const at = async (ms: number): Promise<number> => {
      t = ms;
      sharing.stop();
      sharing = makeSharing();
      const before = gets();
      await tick(sharing); // first tick of a fresh daemon fetches once
      return gets() - before;
    };
    expect(await at(updated + 5_000)).toBe(1);
    // Read the next due time through the schedule: after the first fetch, the next is one minute away.
    const sched = async (age: number) => {
      t = updated + age;
      sharing.stop();
      sharing = makeSharing();
      await tick(sharing);
      const g = gets();
      t += 59_000;
      await tick(sharing);
      const within = gets() - g;
      t += COMMENTS_EVERY_MS.quiet;
      await tick(sharing);
      return { within, afterQuiet: gets() - g - within };
    };
    // Updated 10 minutes ago: active. Not due at +59 s... due after 10 minutes.
    expect((await sched(10 * 60_000)).within).toBe(0);
    // Updated 3 hours ago: quiet, so not due at +9 min, due at +10 min.
    const quiet = await sched(3 * 3600_000);
    expect(quiet.within).toBe(0);
    expect(quiet.afterQuiet).toBe(1);
    // Updated 8 days ago: old, so +10 min is not enough.
    const old = await sched(8 * 86400_000);
    expect(old.afterQuiet).toBe(0);
    t += COMMENTS_EVERY_MS.old;
    const g = gets();
    await tick(sharing);
    expect(gets() - g).toBe(1);
  });

  test("keepAlive: only while the app is connected and a case is shared", async () => {
    expect(sharing.keepAlive(true)).toBe(true);
    expect(sharing.keepAlive(false)).toBe(false);
    await sharing.stopSharing(caseId);
    expect(sharing.keepAlive(true)).toBe(false);
  });
});

describe("G24: shared before", () => {
  test("a case whose link was stopped says so, and a never-shared case does not", async () => {
    expect(sharing.state(caseId).shared_before).toBe(false);
    await sharing.stopSharing(caseId);
    expect(sharing.state(caseId).shared_before).toBe(true);
    expect(sharing.state(newCase("Fresh")).shared_before).toBe(false);
  });
});

describe("G16: screenshots rounds", () => {
  test("a round of several images sends the names of all of them, in order", async () => {
    const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });
    writeFileSync(join(cwd, "a.png"), png);
    writeFileSync(join(cwd, "b.png"), png);
    store.createRevision(caseId, stageIncoming(home, cwd, { type: "screenshots", items: [{ path: "./a.png" }, { path: "./b.png" }] }));
    await until(() => relay.cases.get(relayId())!.rounds.length === 2);
    const upload = relay.calls.filter((c) => c.method === "POST" && c.path.endsWith("/rounds")).pop()!.body as { entry: string; gallery: string[] };
    expect(upload.gallery).toEqual(["01.png", "02.png"]);
    expect(upload.entry).toBe("01.png");
  });
});
