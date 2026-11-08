import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { FollowsCaseError, ReplacesCaseError, Store } from "../src/store";
import type { Event, KnockAskInput } from "../src/protocol";

const question: KnockAskInput = {
  kind: "question",
  title: "Checkout layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "Compact",
  recommendation_why: "It fits on one line",
};

const review: KnockAskInput = {
  kind: "review",
  title: "Checkout layout",
  need: "Approve the layout",
  why: "It needs a human eye",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact" },
    { id: "b", label: "Detailed" },
  ],
};

function newStore(): { store: Store; db: Database; bus: EventBus } {
  const db = new Database(":memory:");
  const bus = new EventBus();
  const store = new Store(db, "/tmp/knock-test", bus);
  return { store, db, bus };
}

describe("Store", () => {
  test("createCase + listCases round-trips a case with its options", () => {
    const { store } = newStore();
    const task = store.createTask({ name: "checkout", project: "knock" });
    const created = store.createCase(task.id, review);

    const listed = store.listCases();
    expect(listed).toHaveLength(1);
    expect(listed[0]).toMatchObject({
      id: created.id,
      task_id: task.id,
      kind: "review",
      title: review.title,
      status: "needs_you",
      has_artifact: false,
    });
    expect(listed[0].options).toEqual(review.options ?? []);
  });

  test("createCase stores an option title and returns it from cases.get (HAIL-85)", () => {
    const { store } = newStore();
    const task = store.createTask({ name: "checkout", project: "knock" });
    const options = [{ id: "a", label: "Compact: one screen", title: "Compact" }, { id: "b", label: "Detailed" }];
    const created = store.createCase(task.id, { ...review, options });
    expect(store.listCases()[0].options).toEqual(options);
    expect(created.options).toEqual(options);
  });

  test("createCase defaults runtime to claude, and denormalizes an explicit one (KNOCK-20)", () => {
    const { store } = newStore();
    const task = store.createTask({ name: "checkout", project: "knock" });

    const defaulted = store.createCase(task.id, question);
    expect(defaulted.runtime).toBe("claude");
    expect(store.getCase(defaulted.id)!.case.runtime).toBe("claude");

    const codexCase = store.createCase(task.id, question, "codex");
    expect(codexCase.runtime).toBe("codex");
    expect(store.listCases().find((c) => c.id === codexCase.id)?.runtime).toBe("codex");
  });

  test("createSession defaults runtime to claude, and stores an explicit one (KNOCK-20)", () => {
    const { store } = newStore();
    const task = store.createTask({ name: "checkout", project: "knock" });

    const defaulted = store.createSession(task.id, { id: "s1", cwd: "/work", branch: null, pid: 1 });
    expect(defaulted.runtime).toBe("claude");
    expect(store.findSession("s1")?.runtime).toBe("claude");

    const codex = store.createSession(task.id, {
      id: "s2",
      cwd: "/work",
      branch: null,
      pid: 2,
      runtime: "codex",
    });
    expect(codex.runtime).toBe("codex");
    expect(store.findSession("s2")?.runtime).toBe("codex");
  });

  test("listCases filters by status", () => {
    const { store } = newStore();
    const task = store.createTask({ name: "checkout", project: "knock" });
    store.createCase(task.id, question);
    expect(store.listCases("needs_you")).toHaveLength(1);
    expect(store.listCases("waiting_on_agent")).toHaveLength(0);
  });

  test("getCase returns the case with its task", () => {
    const { store } = newStore();
    const task = store.createTask({ name: "checkout", project: "knock" });
    const created = store.createCase(task.id, question);

    const detail = store.getCase(created.id)!;
    expect(detail.case.id).toBe(created.id);
    expect(detail.task).toEqual({ id: task.id, name: task.name, project: task.project });
    expect(detail.messages).toEqual([]);
    expect(detail.revisions).toEqual([]);
  });

  test("getCase returns null for an unknown id", () => {
    const { store } = newStore();
    expect(store.getCase("c_missing")).toBeNull();
  });

  test("serviceStatus reports version, root, exec path and zero counters", () => {
    const { store } = newStore();
    expect(store.serviceStatus("1.2.3", "/real/knock")).toEqual({
      version: "1.2.3",
      data_root: "/tmp/knock-test",
      sessions_live: 0,
      cases_open: 0,
      exec_path: "/real/knock",
    });
  });

  test("createCase emits case.created and appends a monotonic event", () => {
    const { store, db, bus } = newStore();
    const received: Event[] = [];
    bus.subscribe((e) => received.push(e));

    const task = store.createTask({ name: "checkout", project: "knock" });
    const a = store.createCase(task.id, question);
    const b = store.createCase(task.id, question);

    expect(received.map((e) => e.type)).toEqual(["case.created", "case.created"]);
    expect(received[0].case_id).toBe(a.id);

    const seqs = db.query("SELECT seq, case_id FROM events ORDER BY seq").all() as {
      seq: number;
      case_id: string;
    }[];
    expect(seqs.map((r) => r.seq)).toEqual([1, 2]);
    expect(seqs.map((r) => r.case_id)).toEqual([a.id, b.id]);
  });

  // HAIL-33 amendment: waggle_ask's optional follows.
  describe("createCase follows", () => {
    test("a case with no follows has a null follows_case_id (column round trip)", () => {
      const { store } = newStore();
      const task = store.createTask({ name: "checkout", project: "knock" });
      const created = store.createCase(task.id, question);
      expect(created.follows_case_id).toBeNull();
      expect(store.getCase(created.id)!.case.follows_case_id).toBeNull();
    });

    test("follows an existing case from the same task, and round-trips through cases.list/get", () => {
      const { store } = newStore();
      const task = store.createTask({ name: "checkout", project: "knock" });
      const earlier = store.createCase(task.id, question);

      const followUp = store.createCase(task.id, { ...question, follows: earlier.id });
      expect(followUp.follows_case_id).toBe(earlier.id);
      expect(store.getCase(followUp.id)!.case.follows_case_id).toBe(earlier.id);
      expect(store.listCases().find((c) => c.id === followUp.id)?.follows_case_id).toBe(earlier.id);
    });

    test("rejects an unknown follows id and creates no case", () => {
      const { store } = newStore();
      const task = store.createTask({ name: "checkout", project: "knock" });

      expect(() =>
        store.createCase(task.id, { ...question, follows: "c_missing" }),
      ).toThrow(FollowsCaseError);
      expect(store.listCases()).toHaveLength(0);
    });

    test("rejects a follows naming a case from another task and creates no case", () => {
      const { store } = newStore();
      const taskA = store.createTask({ name: "checkout", project: "knock" });
      const taskB = store.createTask({ name: "onboarding", project: "knock" });
      const otherTaskCase = store.createCase(taskB.id, question);

      expect(() =>
        store.createCase(taskA.id, { ...question, follows: otherTaskCase.id }),
      ).toThrow(FollowsCaseError);
      expect(store.listCases()).toHaveLength(1);
    });
  });

  // HAIL-44: waggle_ask's optional replaces withdraws the named case in the
  // same write, superseding any reply still queued on it.
  describe("createCase replaces", () => {
    test("a case with no replaces has a null replaces_case_id (column round trip)", () => {
      const { store } = newStore();
      const task = store.createTask({ name: "checkout", project: "knock" });
      const created = store.createCase(task.id, question);
      expect(created.replaces_case_id).toBeNull();
      expect(created.withdrawn_at).toBeNull();
      expect(created.replaced_answer_note).toBeNull();
      expect(store.getCase(created.id)!.case.replaces_case_id).toBeNull();
    });

    test("replaces an existing case: withdraws it, and round-trips through cases.list/get", () => {
      const { store } = newStore();
      const task = store.createTask({ name: "checkout", project: "knock" });
      const earlier = store.createCase(task.id, question);

      const replacement = store.createCase(task.id, { ...question, replaces: earlier.id });
      expect(replacement.replaces_case_id).toBe(earlier.id);
      expect(replacement.replaced_answer_note).toBeNull();
      expect(store.getCase(replacement.id)!.case.replaces_case_id).toBe(earlier.id);
      expect(store.listCases().find((c) => c.id === replacement.id)?.replaces_case_id).toBe(earlier.id);

      const withdrawn = store.getCase(earlier.id)!.case;
      expect(withdrawn.status).toBe("resolved");
      expect(withdrawn.withdrawn_at).not.toBeNull();
    });

    test("withdrawing a case with a queued reply closes it, marks the reply delivered and returns the answer as a note", () => {
      const { store } = newStore();
      const task = store.createTask({ name: "checkout", project: "knock" });
      const earlier = store.createCase(task.id, question);
      store.createReply(earlier.id, { idempotency_key: "key-1", choice: "Compact", comments: [], captures: [] });

      const replacement = store.createCase(task.id, { ...question, replaces: earlier.id });
      expect(replacement.replaced_answer_note).toBe(
        "Note: the human answered the ask you replaced: Compact. Take it into account.",
      );

      const reply = store.getCase(earlier.id)!.replies[0];
      expect(reply.state).toBe("delivered");
      expect(reply.delivered_at).not.toBeNull();
      const closed = store.getCase(earlier.id)!.case;
      expect(closed.status).toBe("resolved");
      expect(closed.withdrawn_at).not.toBeNull();
    });

    test("withdrawing a case with no queued reply returns no note", () => {
      const { store } = newStore();
      const task = store.createTask({ name: "checkout", project: "knock" });
      const earlier = store.createCase(task.id, question);

      const replacement = store.createCase(task.id, { ...question, replaces: earlier.id });
      expect(replacement.replaced_answer_note).toBeNull();
    });

    test("withdrawing a case with a delivered reply leaves that reply delivered, not superseded", () => {
      const { store } = newStore();
      const task = store.createTask({ name: "checkout", project: "knock" });
      const earlier = store.createCase(task.id, question);
      const reply = store.createReply(earlier.id, {
        idempotency_key: "key-1",
        choice: "Compact",
        comments: [],
        captures: [],
      });
      store.markReplyDelivered(reply.id);

      const replacement = store.createCase(task.id, { ...question, replaces: earlier.id });
      expect(replacement.replaced_answer_note).toBeNull();
      expect(store.getCase(earlier.id)!.replies[0].state).toBe("delivered");
    });

    // HAIL-130: dismissing the replacement closes the case it replaced when still open.
    test("dismissing a replacement closes a still-open replaced case", () => {
      const { store } = newStore();
      const task = store.createTask({ name: "checkout", project: "knock" });
      const earlier = store.createCase(task.id, question);
      store.createReply(earlier.id, { idempotency_key: "key-1", choice: "Compact", comments: [], captures: [] });
      const replacement = store.createCase(task.id, { ...question, replaces: earlier.id });
      // Reopen the replaced case the way a stale daemon state could leave it.
      store["db"].query(`UPDATE cases SET status = 'waiting_on_agent', withdrawn_at = NULL WHERE id = ?`).run(earlier.id);

      store.dismissCase(replacement.id);
      const closed = store.getCase(earlier.id)!.case;
      expect(closed.status).toBe("resolved");
      expect(closed.withdrawn_at).not.toBeNull();
    });

    test("dismissing a case that replaced nothing touches no other case", () => {
      const { store } = newStore();
      const task = store.createTask({ name: "checkout", project: "knock" });
      const other = store.createCase(task.id, question);
      const dismissed = store.createCase(task.id, question);
      store.dismissCase(dismissed.id);
      expect(store.getCase(other.id)!.case.status).toBe("needs_you");
    });

    test("rejects an unknown replaces id and creates no case, withdraws nothing", () => {
      const { store } = newStore();
      const task = store.createTask({ name: "checkout", project: "knock" });

      expect(() =>
        store.createCase(task.id, { ...question, replaces: "c_missing" }),
      ).toThrow(ReplacesCaseError);
      expect(store.listCases()).toHaveLength(0);
    });

    test("rejects a replaces naming a case from another task and creates no case", () => {
      const { store } = newStore();
      const taskA = store.createTask({ name: "checkout", project: "knock" });
      const taskB = store.createTask({ name: "onboarding", project: "knock" });
      const otherTaskCase = store.createCase(taskB.id, question);

      expect(() =>
        store.createCase(taskA.id, { ...question, replaces: otherTaskCase.id }),
      ).toThrow(ReplacesCaseError);
      expect(store.listCases()).toHaveLength(1);
      expect(store.getCase(otherTaskCase.id)!.case.status).toBe("needs_you");
    });
  });

  test("recordEvent publishes to every subscriber and is read back by eventsAfter", () => {
    const { store, bus } = newStore();
    const seen: Event[] = [];
    bus.subscribe((e) => seen.push(e));
    bus.subscribe((e) => seen.push(e));

    store.recordEvent("session.state_changed", { session_id: "s_1" });
    expect(seen).toHaveLength(2);
    expect(seen.every((e) => e.type === "session.state_changed")).toBe(true);

    const events = store.eventsAfter(0);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ type: "session.state_changed", session_id: "s_1" });
    expect(store.eventsAfter(1)).toHaveLength(0);
  });
});
