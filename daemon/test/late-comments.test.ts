import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { RelaySharing } from "../src/connectors/relay";
import { MemorySecretStore } from "../src/connectors/secrets";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { FakeRelay } from "./fake-relay";
import { rmrf, tmpHome } from "./helpers";

// WAG-401: late comments (a team comment after the last decide answer). Count, given, and the page open while the
// owner changes the answer. Against a fake relay on localhost.

let home: string;
let relay: FakeRelay;
let store: Store;
let sharing: RelaySharing;
let caseId: string;

const relayId = () => store.getRelayShare(caseId)!.relay_id;
const patches = () => relay.calls.filter((c) => c.method === "PATCH");
const answer = (choice: string, intent: "decision" | "discuss" = "decision") =>
  store.submitReply(caseId, { idempotency_key: `k-${Math.random()}`, choice, intent, ...(intent === "discuss" ? { message: "What about cost?" } : {}), comments: [], captures: [] });
const late = () => Date.now() + 60_000;

async function until(fn: () => boolean, ms = 3000): Promise<void> {
  const start = Date.now();
  while (!fn()) {
    if (Date.now() - start > ms) throw new Error("condition not met in time");
    await new Promise((r) => setTimeout(r, 10));
  }
}

beforeEach(async () => {
  home = tmpHome();
  relay = new FakeRelay();
  const bus = new EventBus();
  store = new Store(new Database(join(home, "knock.db")), home, bus);
  const secrets = new MemorySecretStore();
  secrets.set("relay-device", relay.issueToken());
  sharing = new RelaySharing({ store, bus, secrets, baseUrl: relay.baseUrl, pollMs: 3_600_000, retryMs: 60_000, log: () => {} });
  sharing.setEnabled(true);
  const taskId = store.createTask({ name: "t", project: "waggle" }).id;
  caseId = store.createCase(taskId, {
    kind: "question",
    title: "Which plan?",
    need: "Pick one",
    why: "w",
    recommendation: "a",
    recommendation_why: "r",
    options: [
      { id: "a", title: "Flag first", label: "Flag the page first" },
      { id: "b", title: "Cache first", label: "Cache the page first" },
    ],
  }).id;
  await sharing.share(caseId, "link");
  sharing.start();
});

afterEach(() => {
  sharing.stop();
  relay.stop();
  rmrf(home);
});

describe("the late count", () => {
  test("is zero on an open case, even with team comments", async () => {
    relay.addComment(relayId(), { id: "k1", created_at: late() });
    await sharing.refresh(caseId);
    expect(sharing.state(caseId).late_comments).toEqual({ count: 0, new: 0 });
  });

  test("counts team comments after the decision, not before, not the owner's", async () => {
    relay.addComment(relayId(), { id: "k0", created_at: 10, body: "Early" });
    answer("a");
    relay.addComment(relayId(), { id: "k1", created_at: late(), body: "Late" });
    relay.addComment(relayId(), { id: "k2", created_at: late() + 1, body: "Late too", author_kind: "member", author_name: "Bea" });
    relay.addComment(relayId(), { id: "k3", created_at: late() + 2, body: "Mine", author_kind: "owner", author_name: "Me" });
    await sharing.refresh(caseId);
    expect(sharing.state(caseId).late_comments).toEqual({ count: 2, new: 2 });
    expect(sharing.hasNewEarlyComments(caseId)).toBe(true);
  });

  test("keep talking is not a decision", async () => {
    answer("a", "discuss");
    relay.addComment(relayId(), { id: "k1", created_at: late() });
    await sharing.refresh(caseId);
    expect(sharing.state(caseId).late_comments.count).toBe(0);
  });

  test("a changed answer moves the line: older late comments are no longer late", async () => {
    const reply = answer("a");
    relay.addComment(relayId(), { id: "k1", created_at: Date.now() + 100 });
    await sharing.refresh(caseId);
    expect(sharing.state(caseId).late_comments.count).toBe(1);
    await new Promise((r) => setTimeout(r, 150));
    store.replaceReply(reply.id, { choice: "b", comments: [], captures: [] });
    expect(sharing.state(caseId).late_comments.count).toBe(0);
  });

  test("mark_late_given keeps the count and clears new; waggle_check data still lists them as new before", async () => {
    answer("a");
    relay.addComment(relayId(), { id: "k1", created_at: late(), body: "Late" });
    await sharing.refresh(caseId);
    expect(sharing.commentsForAgent(caseId).map((c) => [c.id, c.new])).toEqual([["k1", true]]);
    const after = sharing.markLateGiven(caseId);
    expect(after.late_comments).toEqual({ count: 1, new: 0 });
    expect(sharing.commentsForAgent(caseId)[0]!.new).toBeUndefined();
  });
});

describe("the page while the owner changes the answer", () => {
  test("shows open on begin, decided again on cancel, and the new answer as the new decision", async () => {
    answer("a");
    await until(() => relay.cases.get(relayId())!.status === "decided");
    await sharing.reopen(caseId, true);
    expect(relay.cases.get(relayId())!.status).toBe("open");
    // The tick must not decide the page again while the owner changes the answer.
    await sharing.refresh(caseId);
    expect(relay.cases.get(relayId())!.status).toBe("open");
    await sharing.reopen(caseId, false);
    expect(relay.cases.get(relayId())!.status).toBe("decided");
    expect(relay.cases.get(relayId())!.decided).toMatchObject({ options: ["Flag first"] });

    await sharing.reopen(caseId, true);
    expect(relay.cases.get(relayId())!.status).toBe("open");
    const reply = store.getCase(caseId)!.replies[0]!;
    store.replaceReply(reply.id, { choice: "b", comments: [], captures: [] });
    await until(() => relay.cases.get(relayId())!.status === "decided");
    expect(relay.cases.get(relayId())!.decided).toMatchObject({ options: ["Cache first"] });
    expect(patches().length).toBeGreaterThan(3);
  });
});
