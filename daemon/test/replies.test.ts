import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { DETAIL_FORMAT_LINES, Store } from "../src/store";
import type { Event, KnockAskInput, Reply } from "../src/protocol";
import { rpcConnect, rmrf, tmpHome, type RpcClient } from "./helpers";

// KNOCK-05: reply.submit / reply.retry. Store-level tests cover the state
// machine (queued -> delivered / failed) and idempotency; RPC-level tests cover
// routing and the exact reply payload through case.wait.

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const FAKE_PNG = Buffer.concat([PNG_SIG, Buffer.from("annotated png")]).toString("base64");

const question: KnockAskInput = {
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

const capture = {
  id: "cap-1",
  revision: 2,
  png_base64: FAKE_PNG,
  annotated_png_base64: FAKE_PNG,
  taken_at: "2026-09-26T00:00:00.000Z",
};

const comments = [
  {
    id: "cmt-1",
    capture_id: "cap-1",
    n: 1,
    rect: { x: 0.12, y: 0.31, w: 0.76, h: 0.06 },
    text: "Default this to Monthly.",
  },
  {
    id: "cmt-2",
    capture_id: "cap-1",
    n: 2,
    rect: { x: 0.06, y: 0.88, w: 0.88, h: 0.07 },
    text: "Keep the pay button above the fold.",
  },
];

function newStore(): { store: Store; db: Database; bus: EventBus } {
  const db = new Database(":memory:");
  const bus = new EventBus();
  const store = new Store(db, "/tmp/knock-test", bus);
  return { store, db, bus };
}

// Creates a task, a live session and one case, and returns the three ids.
function seedSessionCase(store: Store, sessionId = "sess-1") {
  const task = store.createTask({ name: "checkout", project: "knock" });
  store.createSession(task.id, { id: sessionId, cwd: "/work", branch: null, pid: 4242 });
  const caseId = store.createCase(task.id, question).id;
  return { taskId: task.id, sessionId, caseId };
}

describe("Store replies", () => {
  test("submitReply stores the reply and moves the case to waiting_on_agent", () => {
    const { store } = newStore();
    const { caseId } = seedSessionCase(store);

    const reply = store.submitReply(caseId, {
      idempotency_key: "key-1",
      choice: "a",
      message: "Go with A.",
      comments,
      captures: [capture],
    });

    expect(reply.state).toBe("queued");
    expect(reply.choice).toBe("a");
    expect(reply.message).toBe("Go with A.");
    expect(reply.comments.map((c) => c.n)).toEqual([1, 2]);
    expect(reply.captures).toHaveLength(1);
    expect(store.getCase(caseId)!.case.status).toBe("waiting_on_agent");
  });

  test("the same idempotency key returns the same reply and creates only one", () => {
    const { store, bus } = newStore();
    const { caseId } = seedSessionCase(store);
    const events: Event[] = [];
    bus.subscribe((e) => events.push(e));

    const first = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });
    const second = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });

    expect(second.id).toBe(first.id);
    expect(second).toEqual(first);
    expect(store.getCase(caseId)!.replies).toHaveLength(1);
    expect(events.filter((e) => e.type === "reply.state_changed")).toHaveLength(1);
  });

  test("a second submit after delivery returns the delivered reply, no second delivery", () => {
    const { store } = newStore();
    const { caseId } = seedSessionCase(store);

    const reply = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });
    store.markReplyDelivered(reply.id);

    const again = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });
    expect(again.id).toBe(reply.id);
    expect(again.state).toBe("delivered");
    expect(store.getCase(caseId)!.replies).toHaveLength(1);
  });

  test("a reply submitted while its session is ended is failed", () => {
    const { store } = newStore();
    const { sessionId, caseId } = seedSessionCase(store);
    store.setSessionState(sessionId, "ended");

    const reply = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });
    expect(reply.state).toBe("failed");
    expect(reply.reason).toBe("session_unreachable");
  });

  test("a queued reply fails when its session ends", () => {
    const { store } = newStore();
    const { sessionId, caseId } = seedSessionCase(store);

    const reply = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });
    expect(reply.state).toBe("queued");

    store.setSessionState(sessionId, "ended");
    const failed = store.getCase(caseId)!.replies[0];
    expect(failed.state).toBe("failed");
    expect(failed.reason).toBe("session_unreachable");
  });

  test("retry on a failed reply changes nothing while the session is gone (HAIL-192)", () => {
    const { store, bus } = newStore();
    const { sessionId, caseId } = seedSessionCase(store);
    const events: Event[] = [];
    bus.subscribe((e) => events.push(e));

    const reply = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });
    store.setSessionState(sessionId, "ended");

    const retried = store.retryReply(reply.id)!;
    expect(retried.id).toBe(reply.id);
    expect(retried.state).toBe("failed");
    expect(retried.reason).toBe("session_unreachable");
    expect(store.getCase(caseId)!.replies).toHaveLength(1);

    // queued (submit), failed (session ended); the retry adds nothing
    const replyEvents = events.filter((e) => e.type === "reply.state_changed");
    expect(replyEvents).toHaveLength(2);
    expect(replyEvents.every((e) => e.reply_id === reply.id)).toBe(true);
  });

  test("retry stays queued when the session returns", () => {
    const { store } = newStore();
    const { sessionId, caseId } = seedSessionCase(store);

    const reply = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });
    store.setSessionState(sessionId, "ended");
    expect(store.getCase(caseId)!.replies[0].state).toBe("failed");

    store.setSessionState(sessionId, "live");
    const retried = store.retryReply(reply.id)!;
    expect(retried.id).toBe(reply.id);
    expect(retried.state).toBe("queued");
  });

  test("retry on a non-failed reply returns it unchanged", () => {
    const { store } = newStore();
    const { caseId } = seedSessionCase(store);

    const reply = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });
    const retried = store.retryReply(reply.id)!;
    expect(retried.state).toBe("queued");
  });

  test("every reply state change emits reply.state_changed", () => {
    const { store, bus } = newStore();
    const { caseId } = seedSessionCase(store);
    const events: Event[] = [];
    bus.subscribe((e) => events.push(e));

    const reply = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });
    store.markReplyDelivered(reply.id);

    const replyEvents = events.filter((e) => e.type === "reply.state_changed");
    expect(replyEvents.map((e) => e.reply_id)).toEqual([reply.id, reply.id]);
  });

  // KNOCK-13 fold, Amendment 1: a case's own row denormalizes its latest
  // reply so a relaunched app can show Delivered/Failed (and retry a failed
  // reply) from cases.list/cases.get alone, with no per-row extra call.
  test("a case denormalizes its latest reply id/state/at, queued then delivered", () => {
    const { store } = newStore();
    const { caseId } = seedSessionCase(store);

    const before = store.getCase(caseId)!.case;
    expect(before.latest_reply_id).toBeNull();
    expect(before.latest_reply_state).toBeNull();
    expect(before.latest_reply_at).toBeNull();

    const reply = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });

    const queued = store.getCase(caseId)!.case;
    expect(queued.latest_reply_id).toBe(reply.id);
    expect(queued.latest_reply_state).toBe("queued");
    expect(queued.latest_reply_at).toBe(reply.created_at);
    expect(store.listCases("waiting_on_agent")[0].latest_reply_state).toBe("queued");

    store.markReplyDelivered(reply.id);
    const delivered = store.getCase(caseId)!.case;
    expect(delivered.latest_reply_id).toBe(reply.id);
    expect(delivered.latest_reply_state).toBe("delivered");
    // HAIL-64: the pickup time is stored and survives a re-read.
    expect(queued.latest_reply_delivered_at).toBeNull();
    expect(delivered.latest_reply_delivered_at).not.toBeNull();
    expect(Date.parse(delivered.latest_reply_delivered_at!)).toBeGreaterThanOrEqual(Date.parse(reply.created_at));
    expect(store.listCases("waiting_on_agent")[0].latest_reply_delivered_at).toBe(delivered.latest_reply_delivered_at);
  });

  test("a case denormalizes its latest reply as failed, with the id retry needs", () => {
    const { store } = newStore();
    const { sessionId, caseId } = seedSessionCase(store);

    const reply = store.submitReply(caseId, { idempotency_key: "key-1", comments: [], captures: [] });
    store.setSessionState(sessionId, "ended");

    const failed = store.getCase(caseId)!.case;
    expect(failed.latest_reply_id).toBe(reply.id);
    expect(failed.latest_reply_state).toBe("failed");
    expect(store.listCases("waiting_on_agent")[0].latest_reply_id).toBe(reply.id);
  });

  test("a case denormalizes the latest reply's choice/message, and the first reply's submitted_at", () => {
    const { store } = newStore();
    const { caseId } = seedSessionCase(store);

    const before = store.getCase(caseId)!.case;
    expect(before.latest_reply_choice).toBeNull();
    expect(before.latest_reply_message).toBeNull();
    expect(before.first_reply_submitted_at).toBeNull();

    const reply = store.submitReply(caseId, {
      idempotency_key: "key-1",
      choice: "a",
      message: "Go with A.",
      comments: [],
      captures: [],
    });

    const after = store.getCase(caseId)!.case;
    expect(after.latest_reply_choice).toBe("a");
    expect(after.latest_reply_message).toBe("Go with A.");
    expect(after.first_reply_submitted_at).toBe(reply.created_at);
  });

  describe("replaceReply", () => {
    test("changes choice/message/comments/captures in place, keeping the same id and created_at", () => {
      const { store } = newStore();
      const { caseId } = seedSessionCase(store);

      const reply = store.submitReply(caseId, {
        idempotency_key: "key-1",
        choice: "a",
        message: "Go with A.",
        comments: [],
        captures: [],
      });

      const replaced = store.replaceReply(reply.id, {
        idempotency_key: reply.idempotency_key,
        choice: "b",
        message: "Actually, go with B.",
        comments,
        captures: [capture],
      });

      expect(replaced!.id).toBe(reply.id);
      expect(replaced!.created_at).toBe(reply.created_at);
      expect(replaced!.choice).toBe("b");
      expect(replaced!.message).toBe("Actually, go with B.");
      expect(replaced!.comments.map((c) => c.n)).toEqual([1, 2]);
      expect(replaced!.captures).toHaveLength(1);
      expect(replaced!.replaced_at).toBeDefined();
      expect(store.getCase(caseId)!.replies).toHaveLength(1);
    });

    test("dropped captures/comments never linger after a replace", () => {
      const { store } = newStore();
      const { caseId } = seedSessionCase(store);

      const reply = store.submitReply(caseId, {
        idempotency_key: "key-1",
        comments,
        captures: [capture],
      });
      expect(reply.captures).toHaveLength(1);

      const replaced = store.replaceReply(reply.id, {
        idempotency_key: reply.idempotency_key,
        choice: "b",
        comments: [],
        captures: [],
      })!;

      expect(replaced.captures).toHaveLength(0);
      expect(replaced.comments).toHaveLength(0);
    });

    test("keeps the FIRST submit time for the case's first_reply_submitted_at", () => {
      const { store } = newStore();
      const { caseId } = seedSessionCase(store);

      const reply = store.submitReply(caseId, { idempotency_key: "key-1", choice: "a", comments: [], captures: [] });
      const firstSubmittedAt = store.getCase(caseId)!.case.first_reply_submitted_at;

      store.replaceReply(reply.id, { idempotency_key: reply.idempotency_key, choice: "b", comments: [], captures: [] });

      expect(store.getCase(caseId)!.case.first_reply_submitted_at).toBe(firstSubmittedAt);
      expect(store.getCase(caseId)!.case.latest_reply_choice).toBe("b");
    });

    test("throws ReplyNotQueuedError once the reply is delivered", async () => {
      const { store } = newStore();
      const { caseId } = seedSessionCase(store);

      const reply = store.submitReply(caseId, { idempotency_key: "key-1", choice: "a", comments: [], captures: [] });
      store.markReplyDelivered(reply.id);

      const { ReplyNotQueuedError } = await import("../src/store");
      expect(() =>
        store.replaceReply(reply.id, { idempotency_key: reply.idempotency_key, choice: "b", comments: [], captures: [] }),
      ).toThrow(ReplyNotQueuedError);
    });

    test("throws ReplyNotQueuedError once the reply has failed", async () => {
      const { store } = newStore();
      const { sessionId, caseId } = seedSessionCase(store);

      const reply = store.submitReply(caseId, { idempotency_key: "key-1", choice: "a", comments: [], captures: [] });
      store.setSessionState(sessionId, "ended");
      expect(store.getCase(caseId)!.replies[0].state).toBe("failed");

      const { ReplyNotQueuedError } = await import("../src/store");
      expect(() =>
        store.replaceReply(reply.id, { idempotency_key: reply.idempotency_key, choice: "b", comments: [], captures: [] }),
      ).toThrow(ReplyNotQueuedError);
    });

    test("returns null for an unknown reply", () => {
      const { store } = newStore();
      expect(
        store.replaceReply("reply_missing", { idempotency_key: "k", comments: [], captures: [] }),
      ).toBeNull();
    });
  });

  // HAIL-33: reply.submit's intent, "decision" (default) or "more_detail".
  describe("intent", () => {
    test("defaults to decision when omitted, and round-trips more_detail", () => {
      const { store } = newStore();
      const { caseId } = seedSessionCase(store);

      const decision = store.submitReply(caseId, {
        idempotency_key: "key-decision",
        choice: "a",
        comments: [],
        captures: [],
      });
      expect(decision.intent).toBe("decision");

      const { caseId: caseId2 } = seedSessionCase(store, "sess-2");
      const detail = store.submitReply(caseId2, {
        idempotency_key: "key-detail",
        message: "Show me the trade-offs",
        intent: "more_detail",
        comments: [],
        captures: [],
      });
      expect(detail.intent).toBe("more_detail");
      expect(detail.choice).toBeUndefined();
    });

    test("a case denormalizes the latest reply's intent", () => {
      const { store } = newStore();
      const { caseId } = seedSessionCase(store);

      expect(store.getCase(caseId)!.case.latest_reply_intent).toBeNull();

      store.submitReply(caseId, {
        idempotency_key: "key-detail",
        message: "Show me a prototype",
        intent: "more_detail",
        comments: [],
        captures: [],
      });

      expect(store.getCase(caseId)!.case.latest_reply_intent).toBe("more_detail");
      expect(store.listCases("waiting_on_agent")[0].latest_reply_intent).toBe("more_detail");
    });

    test("buildReplyPayload for a more_detail reply starts with the fixed phrase and the question", () => {
      const { store } = newStore();
      const { caseId } = seedSessionCase(store);

      const reply = store.submitReply(caseId, {
        idempotency_key: "key-detail",
        message: "Why don't we make the button blue?",
        intent: "more_detail",
        comments: [],
        captures: [],
      });

      const payload = store.buildReplyPayload(reply.id)!;
      expect(payload.content).toHaveLength(1);
      const text = payload.content[0].type === "text" ? payload.content[0].text : "";
      expect(text.startsWith("The human wants more detail before deciding:")).toBe(true);
      expect(text).toContain("Why don't we make the button blue?");
      expect(text).toContain("waggle_update");
      expect(text).toContain("markdown for reasoning");
      expect(text).toContain("html_bundle for a prototype or a chart");
      expect(text).toContain("waggle_check to wait for the decision");
      expect(text).not.toContain("Reply to ");
      expect(text).not.toContain("Choice:");
    });

    test("buildReplyPayload for a more_detail reply with no message still starts with the fixed phrase", () => {
      const { store } = newStore();
      const { caseId } = seedSessionCase(store);

      const reply = store.submitReply(caseId, {
        idempotency_key: "key-detail-no-message",
        intent: "more_detail",
        comments: [],
        captures: [],
      });

      const payload = store.buildReplyPayload(reply.id)!;
      const text = payload.content[0].type === "text" ? payload.content[0].text : "";
      expect(text.startsWith("The human wants more detail before deciding:")).toBe(true);
    });
  });

  // HAIL-139: a more_detail reply may carry a format ("eli5" | "diagram" |
  // "page"). Stored on the reply, denormalized onto the case, and one extra
  // line in the agent's payload. A detail request without one is unchanged.
  describe("format", () => {
    test("a more_detail reply round-trips its format, and defaults to absent", () => {
      const { store } = newStore();
      const { caseId } = seedSessionCase(store);

      const withFormat = store.submitReply(caseId, {
        idempotency_key: "key-fmt",
        message: "Why blue?",
        intent: "more_detail",
        format: "diagram",
        comments: [],
        captures: [],
      });
      expect(withFormat.intent).toBe("more_detail");
      expect(withFormat.format).toBe("diagram");

      const { caseId: caseId2 } = seedSessionCase(store, "sess-2");
      const withoutFormat = store.submitReply(caseId2, {
        idempotency_key: "key-nofmt",
        intent: "more_detail",
        comments: [],
        captures: [],
      });
      expect(withoutFormat.format).toBeUndefined();
    });

    test("a case denormalizes the latest reply's format", () => {
      const { store } = newStore();
      const { caseId } = seedSessionCase(store);

      expect(store.getCase(caseId)!.case.latest_reply_format).toBeNull();

      store.submitReply(caseId, {
        idempotency_key: "key-fmt",
        intent: "more_detail",
        format: "page",
        comments: [],
        captures: [],
      });

      expect(store.getCase(caseId)!.case.latest_reply_format).toBe("page");
      expect(store.listCases("waiting_on_agent")[0].latest_reply_format).toBe("page");
    });

    test("buildReplyPayload puts each format line before the message", () => {
      for (const format of ["eli5", "diagram", "page"] as const) {
        const { store } = newStore();
        const { caseId } = seedSessionCase(store);

        const reply = store.submitReply(caseId, {
          idempotency_key: `key-${format}`,
          message: "Why don't we make the button blue?",
          intent: "more_detail",
          format,
          comments: [],
          captures: [],
        });

        const payload = store.buildReplyPayload(reply.id)!;
        expect(payload.content).toHaveLength(1);
        const text = payload.content[0].type === "text" ? payload.content[0].text : "";
        expect(text.startsWith("The human wants more detail before deciding:")).toBe(true);
        expect(text).toContain(DETAIL_FORMAT_LINES[format]);
        expect(text.indexOf(DETAIL_FORMAT_LINES[format])).toBeLessThan(
          text.indexOf("Why don't we make the button blue?"),
        );
        expect(text).toContain("waggle_update");
      }
    });

    test("a detail request without a format keeps the message inline and adds no format line", () => {
      const { store } = newStore();
      const { caseId } = seedSessionCase(store);

      const reply = store.submitReply(caseId, {
        idempotency_key: "key-nofmt",
        message: "Show me the numbers",
        intent: "more_detail",
        comments: [],
        captures: [],
      });

      const payload = store.buildReplyPayload(reply.id)!;
      const text = payload.content[0].type === "text" ? payload.content[0].text : "";
      expect(text.startsWith("The human wants more detail before deciding: Show me the numbers")).toBe(true);
      expect(text).not.toContain("Explain it again like I'm five");
      expect(text).not.toContain("Explain it as a diagram");
      expect(text).not.toContain("Explain it as a short interactive page");
    });
  });

  test("buildReplyPayload formats the text and one annotated image per captured comment", () => {
    const { store } = newStore();
    const { caseId } = seedSessionCase(store);

    const reply = store.submitReply(caseId, {
      idempotency_key: "key-1",
      choice: "a",
      message: "Go with A. Two fixes:",
      comments,
      captures: [capture],
    });

    const payload = store.buildReplyPayload(reply.id)!;
    expect(payload.reply_id).toBe(reply.id);
    expect(payload.content[0]).toMatchObject({ type: "text" });
    const text = payload.content[0].type === "text" ? payload.content[0].text : "";
    expect(text).toContain(`Reply to "Pick a layout" (case ${caseId})`);
    expect(text).toContain("Choice: a (Compact)");
    expect(text).toContain("Message: Go with A. Two fixes:");
    expect(text).toContain("Comments on revision 2, capture 1:");
    expect(text).toContain(
      "[1] (region x=0.12 y=0.31 w=0.76 h=0.06) Default this to Monthly.",
    );
    expect(text).toContain(
      "[2] (region x=0.06 y=0.88 w=0.88 h=0.07) Keep the pay button above the fold.",
    );
    expect(payload.content[1]).toMatchObject({ type: "image", data: FAKE_PNG, mimeType: "image/png" });
  });

  // HAIL-40: a screenshots case's capture carries its screen number and
  // caption in `note` (set by the app's ReplyPayloadBuilder - each image of
  // a screenshots artifact is its own capture); the label uses it verbatim
  // instead of "revision N, capture M".
  test("buildReplyPayload uses a capture's note as its label when present", () => {
    const { store } = newStore();
    const { caseId } = seedSessionCase(store);

    const reply = store.submitReply(caseId, {
      idempotency_key: "key-note",
      choice: "a",
      comments,
      captures: [{ ...capture, note: "Screen 2 · Verify email" }],
    });

    const payload = store.buildReplyPayload(reply.id)!;
    const text = payload.content[0].type === "text" ? payload.content[0].text : "";
    expect(text).toContain("Comments on Screen 2 · Verify email:");
    expect(text).not.toContain("Comments on revision 2, capture 1:");
  });

  // HAIL-150: text comments have no capture and add no image block.
  test("buildReplyPayload lists text comments with their quote and no image", () => {
    const { store } = newStore();
    const { caseId } = seedSessionCase(store);
    const long = "start of a long quote " + "middle ".repeat(40) + "end of the quote";
    const reply = store.submitReply(caseId, {
      idempotency_key: "key-text",
      choice: "a",
      comments: [
        { id: "t1", n: 1, text: "Too vague.", anchor: { kind: "text", revision: 1, quote: "the quoted text", start: 4, end: 19 } },
        { id: "t2", n: 2, text: "Cut this.", anchor: { kind: "text", revision: 1, quote: long, start: 30, end: 30 + long.length } },
      ],
      captures: [],
    });
    expect(reply.comments.map((c) => c.anchor?.quote)).toEqual(["the quoted text", long]);
    const payload = store.buildReplyPayload(reply.id)!;
    expect(payload.content).toHaveLength(1);
    const text = payload.content[0].type === "text" ? payload.content[0].text : "";
    expect(text).toContain('Comments on the explanation (v1):\n[1] "the quoted text" - Too vague.');
    const line = text.split("\n").find((l) => l.startsWith("[2]"))!;
    expect(line).toMatch(/^\[2\] "start of a long quote.*\.\.\..*end of the quote" - Cut this\.$/);
    expect(line.length).toBeLessThan(200);
  });

  test("text comments survive reply.replace and sit beside capture comments", () => {
    const { store } = newStore();
    const { caseId } = seedSessionCase(store);
    const reply = store.submitReply(caseId, { idempotency_key: "k", choice: "a", comments: [], captures: [] });
    const replaced = store.replaceReply(reply.id, {
      choice: "a",
      comments: [
        comments[0],
        { id: "t1", n: 2, text: "Note.", anchor: { kind: "text", revision: 1, quote: "x", start: 0, end: 1 } },
      ],
      captures: [capture],
    })!;
    expect(replaced.comments.map((c) => [c.n, c.capture_id ?? null, c.anchor?.kind ?? null])).toEqual([
      [1, "cap-1", null],
      [2, null, "text"],
    ]);
    const again = store.replaceReply(reply.id, { choice: "a", comments: [], captures: [] })!;
    expect(again.comments).toEqual([]);
  });
});

describe("reply RPC", () => {
  let home: string;
  let socketPath: string;
  let server: RpcServer;
  let store: Store;
  let clients: RpcClient[] = [];

  beforeAll(() => {
    home = tmpHome();
    socketPath = join(home, "knock.sock");
    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    store = new Store(db, home, bus);
    server = startRpcServer({ socketPath, store, bus, version: "0.1.0" });
  });

  afterAll(() => {
    for (const client of clients.splice(0)) {
      try {
        client.close();
      } catch {
        // Already closed.
      }
    }
    server.stop();
    rmrf(home);
  });

  async function connect(): Promise<RpcClient> {
    const client = await rpcConnect(socketPath);
    clients.push(client);
    return client;
  }

  async function helloAndCreateCase(
    sessionId: string,
  ): Promise<{ client: RpcClient; sessionId: string; caseId: string }> {
    const client = await connect();
    const hello = await client.request("session.hello", {
      session_id: sessionId,
      cwd: join(home, "work"),
      parent_pid: 4242,
    });
    const created = await client.request("case.create", { ...question, need: `${question.need} ${sessionId}` });
    return {
      client,
      sessionId,
      caseId: (created.result as { id: string }).id,
    };
  }

  test("reply.submit returns a queued reply and is idempotent over the socket", async () => {
    const { caseId } = await helloAndCreateCase("sess-submit");
    const app = await connect();

    const params = {
      case_id: caseId,
      idempotency_key: "key-rpc-1",
      choice: "a",
      message: "Go with A.",
      comments: [],
      captures: [],
    };
    const first = await app.request("reply.submit", params);
    expect((first.result as Reply).state).toBe("queued");

    const second = await app.request("reply.submit", params);
    expect(second.result).toEqual(first.result);
    expect(store.getCase(caseId)!.replies).toHaveLength(1);
  });

  test("reply.submit on an unknown case is -32001", async () => {
    const app = await connect();
    const res = await app.request("reply.submit", {
      case_id: "c_missing",
      idempotency_key: "key-missing",
      comments: [],
      captures: [],
    });
    expect(res.error?.code).toBe(-32001);
  });

  test("a reply stays queued until the shim acks, then delivered", async () => {
    const { client, caseId } = await helloAndCreateCase("sess-ack");
    const app = await connect();

    const submitted = await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "key-ack",
      choice: "a",
      message: "Go with A.",
      comments: [],
      captures: [],
    });
    const replyId = (submitted.result as Reply).id;
    expect(store.getCase(caseId)!.replies[0].state).toBe("queued");

    const ack = await client.request("reply.ack", { reply_id: replyId });
    expect((ack.result as Reply).state).toBe("delivered");
    expect(store.getCase(caseId)!.replies[0].state).toBe("delivered");
  });

  test("reply.retry leaves a failed reply failed while the session is gone", async () => {
    const { sessionId, caseId } = await helloAndCreateCase("sess-retry");
    const app = await connect();

    const submitted = await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "key-retry",
      comments: [],
      captures: [],
    });
    const replyId = (submitted.result as Reply).id;

    store.setSessionState(sessionId, "ended");
    expect(store.getCase(caseId)!.replies[0].state).toBe("failed");

    const retried = await app.request("reply.retry", { reply_id: replyId });
    expect((retried.result as Reply).id).toBe(replyId);
    expect((retried.result as Reply).state).toBe("failed");
    expect((retried.result as Reply).reason).toBe("session_unreachable");
    expect(store.getCase(caseId)!.replies).toHaveLength(1);
  });

  test("reply.retry on an unknown reply is -32001", async () => {
    const app = await connect();
    const res = await app.request("reply.retry", { reply_id: "reply_missing" });
    expect(res.error?.code).toBe(-32001);
  });

  test("reply.replace changes a queued reply's answer and keeps its id", async () => {
    const { caseId } = await helloAndCreateCase("sess-replace");
    const app = await connect();

    const submitted = await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "key-replace",
      choice: "a",
      message: "Go with A.",
      comments: [],
      captures: [],
    });
    const replyId = (submitted.result as Reply).id;

    const replaced = await app.request("reply.replace", {
      reply_id: replyId,
      choice: "b",
      message: "Actually B.",
      comments: [],
      captures: [],
    });
    expect((replaced.result as Reply).id).toBe(replyId);
    expect((replaced.result as Reply).choice).toBe("b");
    expect((replaced.result as Reply).message).toBe("Actually B.");
    expect(store.getCase(caseId)!.replies).toHaveLength(1);
  });

  test("reply.replace once delivered is a clear error, not -32603", async () => {
    const { client, caseId } = await helloAndCreateCase("sess-replace-locked");
    const app = await connect();

    const submitted = await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "key-replace-locked",
      choice: "a",
      comments: [],
      captures: [],
    });
    const replyId = (submitted.result as Reply).id;
    await client.request("reply.ack", { reply_id: replyId });

    const res = await app.request("reply.replace", {
      reply_id: replyId,
      choice: "b",
      comments: [],
      captures: [],
    });
    expect(res.error?.code).toBe(-32006);
    expect(res.error?.message).not.toBe("Internal error");
  });

  test("reply.replace on an unknown reply is -32001", async () => {
    const app = await connect();
    const res = await app.request("reply.replace", {
      reply_id: "reply_missing",
      comments: [],
      captures: [],
    });
    expect(res.error?.code).toBe(-32001);
  });

  // HAIL-44: a queued reply whose case was withdrawn by a later replaces is
  // superseded, not queued; reply.replace on it is rejected the same way it
  // rejects a delivered or failed one, with its own clear message.
  test("reply.replace once its ask was replaced is a clear error, not -32603", async () => {
    const { client, caseId } = await helloAndCreateCase("sess-replace-superseded");
    const app = await connect();

    const submitted = await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "key-replace-superseded",
      choice: "a",
      comments: [],
      captures: [],
    });
    const replyId = (submitted.result as Reply).id;

    await client.request("case.create", { ...question, replaces: caseId });
    expect(store.getCase(caseId)!.replies[0].state).toBe("delivered");

    const res = await app.request("reply.replace", {
      reply_id: replyId,
      choice: "b",
      comments: [],
      captures: [],
    });
    expect(res.error?.code).toBe(-32006);
    expect(res.error?.message).toBe("Can't change this answer: the agent already picked it up.");
  });

  test("the owning session receives the exact payload through case.wait", async () => {
    const { client, caseId } = await helloAndCreateCase("sess-payload");
    const app = await connect();

    await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "key-payload",
      choice: "a",
      message: "Go with A. Two fixes:",
      comments,
      captures: [capture],
    });

    const wait = await client.request("case.wait", { case_id: caseId, wait_ms: 2000 });
    const payload = wait.result as { reply_id: string; content: { type: string; text?: string; data?: string }[] };
    const text = payload.content.find((c) => c.type === "text")?.text ?? "";
    expect(text).toContain(`Reply to "Pick a layout" (case ${caseId})`);
    expect(text).toContain("Choice: a (Compact)");
    expect(text).toContain(
      "[1] (region x=0.12 y=0.31 w=0.76 h=0.06) Default this to Monthly.",
    );
    expect(payload.content.filter((c) => c.type === "image")).toHaveLength(1);
  });

  test("reply.submit with intent more_detail delivers the fixed-phrase payload through case.wait", async () => {
    const { client, caseId } = await helloAndCreateCase("sess-detail");
    const app = await connect();

    const submitted = await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "key-detail-rpc",
      message: "Show me the numbers",
      intent: "more_detail",
      comments: [],
      captures: [],
    });
    expect((submitted.result as Reply).intent).toBe("more_detail");

    const wait = await client.request("case.wait", { case_id: caseId, wait_ms: 2000 });
    const payload = wait.result as { content: { type: string; text?: string }[] };
    const text = payload.content.find((c) => c.type === "text")?.text ?? "";
    expect(text.startsWith("The human wants more detail before deciding: Show me the numbers")).toBe(true);
  });

  test("reply.submit with no intent defaults to decision over the socket", async () => {
    const { caseId } = await helloAndCreateCase("sess-decision-default");
    const app = await connect();

    const submitted = await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "key-decision-default",
      choice: "a",
      comments: [],
      captures: [],
    });
    expect((submitted.result as Reply).intent).toBe("decision");
  });

  test("three concurrent sessions each receive only their own reply", async () => {
    const sessions = await Promise.all([
      helloAndCreateCase("sess-c1"),
      helloAndCreateCase("sess-c2"),
      helloAndCreateCase("sess-c3"),
    ]);

    const waitPromises = sessions.map((s) =>
      s.client.request("case.wait", { case_id: s.caseId, wait_ms: 4000 }, []),
    );

    // Replies land in a scrambled order.
    const app = await connect();
    const shuffled = [...sessions].sort(() => Math.random() - 0.5);
    for (const s of shuffled) {
      const res = await app.request("reply.submit", {
        case_id: s.caseId,
        idempotency_key: `key-${s.caseId}`,
        message: `reply for ${s.caseId}`,
        comments: [],
        captures: [],
      });
      expect((res.result as Reply).state).toBe("queued");
    }

    const results = await Promise.all(waitPromises);
    for (let i = 0; i < sessions.length; i++) {
      const result = results[i];
      expect(result.error).toBeUndefined();
      const payload = result.result as { content: { type: string; text?: string }[] };
      const text = payload.content.find((c) => c.type === "text")?.text ?? "";
      expect(text).toContain(`reply for ${sessions[i].caseId}`);
      for (let j = 0; j < sessions.length; j++) {
        if (j !== i) expect(text).not.toContain(`reply for ${sessions[j].caseId}`);
      }
    }
  });
});
