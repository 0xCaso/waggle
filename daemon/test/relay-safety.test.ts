import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { KEY_MISSING, MAX_EMAILS, RelaySharing } from "../src/connectors/relay";
import { MemorySecretStore } from "../src/connectors/secrets";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { FakeRelay } from "./fake-relay";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

// WAG-391: safe stop and delete, errors that say why, one bad round never blocks the rest, retried shares.

let home: string;
let relay: FakeRelay;
let store: Store;
let secrets: MemorySecretStore;
let sharing: RelaySharing;
let caseId: string;
let t: number;

function makeSharing(over: { fetch?: typeof fetch } = {}): RelaySharing {
  return new RelaySharing({
    store,
    bus: new EventBus(),
    secrets,
    baseUrl: relay.baseUrl,
    retryMs: 60_000,
    now: () => t,
    log: () => {},
    ...over,
  });
}

function newCase(title: string): string {
  const task = store.createTask({ name: title, project: "waggle" });
  return store.createCase(task.id, { kind: "question", title, need: "Pick one", why: "w", recommendation: "A", recommendation_why: "r" }).id;
}

function addMarkdown(id: string, text: string, name?: string): void {
  const cwd = join(home, "work");
  mkdirSync(cwd, { recursive: true });
  writeFileSync(join(cwd, "plan.md"), text);
  const staged = stageIncoming(home, cwd, { type: "markdown", path: "./plan.md" });
  store.createRevision(id, name ? { ...staged, name } : staged);
}

function addBundle(id: string, files: Record<string, string | Buffer>): void {
  const cwd = join(home, "work");
  const dir = join(cwd, `b${Math.random().toString(36).slice(2, 8)}`);
  mkdirSync(dir, { recursive: true });
  for (const [name, body] of Object.entries(files)) writeFileSync(join(dir, name), body);
  store.createRevision(id, stageIncoming(home, cwd, { type: "html_bundle", dir: dir.slice(cwd.length + 1), entry: "index.html" }));
}

const relayId = () => store.getRelayShare(caseId)!.relay_id;
const tick = (s: RelaySharing) => (s as unknown as { tick(): Promise<void> }).tick();

beforeEach(() => {
  home = tmpHome();
  relay = new FakeRelay();
  store = new Store(new Database(join(home, "knock.db")), home, new EventBus());
  secrets = new MemorySecretStore();
  secrets.set("relay-device", relay.issueToken());
  t = 1_000_000;
  sharing = makeSharing();
  sharing.setEnabled(true);
  caseId = newCase("Which plan?");
});

afterEach(() => {
  sharing.stop();
  relay.stop();
  rmrf(home);
});

describe("G4: Stop sharing keeps the team's comments", () => {
  test("the app state and the agent still have them, with their revision", async () => {
    addMarkdown(caseId, "# One");
    await sharing.share(caseId, "link");
    relay.addComment(relayId(), { id: "c1", created_at: 5000, body: "Ship it", round_seq: 1 });
    await sharing.refresh(caseId);
    expect(sharing.state(caseId).comments.map((c) => c.body)).toEqual(["Ship it"]);

    const state = await sharing.stopSharing(caseId);
    expect(state.share).toBeNull();
    expect(state.comments.map((c) => [c.body, c.revision])).toEqual([["Ship it", 1]]);
    expect(sharing.commentsForAgent(caseId).map((c) => [c.body, c.revision])).toEqual([["Ship it", 1]]);
    expect(relay.cases.size).toBe(0);
  });

  test("sharing again later keeps the old comments and gets new ones", async () => {
    addMarkdown(caseId, "# One");
    await sharing.share(caseId, "link");
    relay.addComment(relayId(), { id: "c1", created_at: 5000, round_seq: 1 });
    await sharing.refresh(caseId);
    await sharing.stopSharing(caseId);
    await sharing.share(caseId, "link");
    relay.addComment(relayId(), { id: "c2", created_at: 6000, round_seq: 1, body: "New one" });
    await sharing.refresh(caseId);
    expect(sharing.state(caseId).comments.map((c) => c.id)).toEqual(["c1", "c2"]);
  });
});

describe("G5: deleting a shared case stops sharing", () => {
  function resolve(): void {
    store.dismissCase(caseId);
  }

  test("takes the page down and removes the key when the relay answers", async () => {
    await sharing.share(caseId, "link");
    const rid = relayId();
    resolve();
    expect(store.purgeResolvedCases().purged_cases).toBe(1);
    // The note is in the store at once, so the switch is blocked until the page is gone.
    expect(sharing.state().shared_count).toBe(1);
    await sharing.flushPendingStops();
    expect(relay.cases.size).toBe(0);
    expect(secrets.get(`relay-owner.${rid}`)).toBeNull();
    expect(sharing.state().shared_count).toBe(0);
    expect(() => sharing.setEnabled(false)).not.toThrow();
  });

  test("keeps a pending stop when the relay fails, counts it, and the tick finishes it", async () => {
    await sharing.share(caseId, "link");
    const rid = relayId();
    resolve();
    store.purgeResolvedCases();
    relay.failWith = 503;
    await sharing.flushPendingStops();
    expect(relay.cases.size).toBe(1);
    expect(secrets.get(`relay-owner.${rid}`)).not.toBeNull();
    expect(sharing.state().shared_count).toBe(1);
    expect(() => sharing.setEnabled(false)).toThrow("Stop sharing the shared case first");

    // Inside the retry window the tick makes no call.
    relay.failWith = null;
    const before = relay.calls.length;
    await tick(sharing);
    expect(relay.calls.length).toBe(before);
    // After it, the tick takes the page down.
    t += 61_000;
    await tick(sharing);
    expect(relay.cases.size).toBe(0);
    expect(sharing.state().shared_count).toBe(0);
    expect(secrets.get(`relay-owner.${rid}`)).toBeNull();
  });

  test("drops the note when this Mac has no key, and says so in the log", async () => {
    await sharing.share(caseId, "link");
    secrets.delete(`relay-owner.${relayId()}`);
    resolve();
    store.purgeResolvedCases();
    await sharing.flushPendingStops();
    expect(sharing.state().shared_count).toBe(0);
  });

  test("an unshared case leaves no note", () => {
    resolve();
    store.purgeResolvedCases();
    expect(store.listPendingRelayStops()).toEqual([]);
  });
});

describe("G6: a missing owner key is never a quiet stop", () => {
  test("keeps the share, marks it as not stoppable and says why", async () => {
    await sharing.share(caseId, "link");
    expect(sharing.state(caseId).share?.stoppable).toBe(true);
    secrets.delete(`relay-owner.${relayId()}`);
    // Still signed in: the device token can stop it.
    expect(sharing.state(caseId).share?.stoppable).toBe(true);
    secrets.delete("relay-device");
    const before = relay.calls.length;
    await expect(sharing.stopSharing(caseId)).rejects.toThrow(KEY_MISSING);
    expect(KEY_MISSING).toBe("This Mac no longer has the key for this link.");
    expect(relay.calls.length).toBe(before);
    const state = sharing.state(caseId);
    expect(state.share).toMatchObject({ stoppable: false });
    expect(state.error).toBe(KEY_MISSING);
    expect(state.shared_count).toBe(1);
    expect(() => sharing.setEnabled(false)).toThrow();
  });
});

describe("G19: the relay's words reach the error line", () => {
  test("shows the relay's error text", async () => {
    relay.failWith = 400;
    relay.failError = "List at least one email";
    await expect(sharing.share(caseId, "link")).rejects.toThrow("The sharing service said: List at least one email.");
  });

  test("falls back to the status when the relay sends no words", async () => {
    relay.failWith = 502;
    await expect(sharing.share(caseId, "link")).rejects.toThrow("The sharing service answered 502");
  });

  test("caps the email list at 50 with a plain message, before any call", async () => {
    const many = Array.from({ length: MAX_EMAILS + 1 }, (_, i) => `p${i}@example.com`);
    await expect(sharing.share(caseId, "emails", many)).rejects.toThrow("50 emails at most.");
    expect(relay.calls).toHaveLength(0);
    await sharing.share(caseId, "emails", many.slice(0, MAX_EMAILS));
    expect(relay.cases.get(relayId())!.emails).toHaveLength(MAX_EMAILS);
  });
});

describe("G20: one bad round does not block the rest", () => {
  test("skips a too-big round with a reason and uploads the others", async () => {
    addMarkdown(caseId, "# One");
    addBundle(caseId, { "index.html": "<p>big</p>", "huge.bin": Buffer.alloc(1_100_000, 1) });
    addMarkdown(caseId, "# Three");
    const state = await sharing.share(caseId, "link");
    expect(relay.cases.get(relayId())!.rounds.map((r) => r.seq)).toEqual([1, 2]);
    expect(state.skipped).toHaveLength(1);
    expect(state.skipped[0]!.revision).toBe(2);
    expect(state.skipped[0]!.reason).toContain("huge.bin");
    expect(state.skipped[0]!.reason).toContain("over 1 MB");
    expect(state.error).toBeNull();
    // The skipped round is not tried again, and a later round still goes up.
    const rounds = () => relay.calls.filter((c) => c.path.endsWith("/rounds")).length;
    const n = rounds();
    await sharing.refresh(caseId);
    expect(rounds()).toBe(n);
    addMarkdown(caseId, "# Four");
    await sharing.refresh(caseId);
    expect(relay.cases.get(relayId())!.rounds).toHaveLength(3);
  });

  test("skips a round the relay refuses (too many files) with the relay's words", async () => {
    const files: Record<string, string> = { "index.html": "<p>x</p>" };
    for (let i = 0; i < 200; i++) files[`f${i}.txt`] = "x";
    addBundle(caseId, files);
    addMarkdown(caseId, "# Two");
    const state = await sharing.share(caseId, "link");
    expect(state.skipped[0]!.reason).toContain("more than 200 files");
    expect(relay.cases.get(relayId())!.rounds).toHaveLength(1);
  });

  test("a failure on one case holds back that case only", async () => {
    const other = newCase("Other");
    addMarkdown(caseId, "# A1");
    addMarkdown(other, "# B1");
    await sharing.share(caseId, "link");
    await sharing.share(other, "link");
    const a = store.getRelayShare(caseId)!.relay_id;
    const b = store.getRelayShare(other)!.relay_id;
    relay.failWhen = (c) => (c.path.includes(`/${a}/`) ? 503 : null);
    addMarkdown(caseId, "# A2");
    addMarkdown(other, "# B2");
    await (sharing as unknown as { syncRounds(c: string, o: { background: boolean }): Promise<void> }).syncRounds(caseId, { background: true });
    expect(sharing.state(caseId).error).toContain("503");
    // Case A is in its retry window. Case B still goes up, at once.
    await (sharing as unknown as { syncRounds(c: string, o: { background: boolean }): Promise<void> }).syncRounds(other, { background: true });
    expect(relay.cases.get(b)!.rounds).toHaveLength(2);
    expect(relay.cases.get(a)!.rounds).toHaveLength(1);
    const calls = relay.calls.length;
    await (sharing as unknown as { syncRounds(c: string, o: { background: boolean }): Promise<void> }).syncRounds(caseId, { background: true });
    expect(relay.calls.length).toBe(calls);
  });
});

describe("G23: the artifact name is the round label", () => {
  test("sends the name, and nothing when the agent gave none", async () => {
    addMarkdown(caseId, "# One", "Pricing plan");
    addMarkdown(caseId, "# Two");
    await sharing.share(caseId, "link");
    expect(relay.cases.get(relayId())!.rounds.map((r) => r.label)).toEqual(["Pricing plan", ""]);
  });
});

describe("G26: a retried share and the comment cursor", () => {
  test("a lost answer to the first create does not leave a second relay case", async () => {
    let lose = true;
    const lossy: typeof fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const res = await fetch(input, init);
      if (lose && String(input).endsWith("/api/cases")) {
        lose = false;
        throw new Error("connection reset");
      }
      return res;
    }) as typeof fetch;
    sharing.stop();
    sharing = makeSharing({ fetch: lossy });
    await expect(sharing.share(caseId, "link")).rejects.toThrow("could not reach");
    expect(relay.cases.size).toBe(1);
    const state = await sharing.share(caseId, "link");
    expect(state.share).not.toBeNull();
    expect(relay.cases.size).toBe(1);
    const sent = relay.calls.filter((c) => c.path === "/api/cases").map((c) => c.body!.request_id);
    expect(sent[0]).toBe(sent[1]);
  });

  test("a second comment in the same millisecond is not skipped", async () => {
    await sharing.share(caseId, "link");
    relay.addComment(relayId(), { id: "aaa", created_at: 7000 });
    await sharing.refresh(caseId);
    relay.addComment(relayId(), { id: "bbb", created_at: 7000, body: "Same ms" });
    await sharing.refresh(caseId);
    expect(sharing.state(caseId).comments.map((c) => c.id)).toEqual(["aaa", "bbb"]);
    expect(store.getRelayShare(caseId)).toMatchObject({ since: 7000, since_id: "bbb" });
    const last = relay.calls[relay.calls.length - 1]!;
    expect(last.path).toContain("after=aaa");
  });
});
