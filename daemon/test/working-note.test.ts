import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { ConnectorManager } from "../src/connectors/manager";
import type { AskMessage, Connector } from "../src/connectors/types";
import { EventBus } from "../src/events";
import { KnockUpdateInput, MCP_TOOLS } from "../src/protocol";
import type { KnockAskInput } from "../src/protocol";
import { canonicalToolName } from "../src/protocol/legacy-aliases";
import { Store } from "../src/store";
import { getGuide } from "../src/guide";

// WAG-377: waggle_update with working: true is a progress note. The case stays with the agent
// (waiting_on_agent), no needs_you alert goes out, and the next real round restores normal behaviour.

const question: KnockAskInput = {
  kind: "question",
  title: "Which version?",
  need: "Which version?",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is ready",
  options: [
    { id: "a", label: "Version one" },
    { id: "b", label: "Version two" },
  ],
};

function setup() {
  const bus = new EventBus();
  const store = new Store(new Database(":memory:"), "/tmp/knock-test", bus);
  const sent: AskMessage[] = [];
  const connector: Connector = {
    id: "telegram",
    isActive: () => true,
    start() {},
    stop() {},
    disconnect: async () => {},
    sendAsk: async (ask) => {
      sent.push(ask);
      return null;
    },
    updateOutcome: async () => {},
  };
  const manager = new ConnectorManager(store, bus, [connector], () => {});
  manager.start();
  const task = store.createTask({ name: "WAG-377", project: "app" });
  const caseId = store.createCase(task.id, question).id;
  return { store, bus, caseId, sent };
}

const base = { case_id: "c1", message: "I am drawing a second version now." };
const tick = () => new Promise((r) => setTimeout(r, 20));

describe("KnockUpdateInput working", () => {
  test("working parses and is optional", () => {
    expect(KnockUpdateInput.parse({ ...base, working: true }).working).toBe(true);
    expect(KnockUpdateInput.parse(base).working).toBeUndefined();
  });

  test.each([
    ["done", { done: true }],
    ["items", { items: [{ id: "x", question: "Q?", options: [{ id: "a", label: "A" }] }] }],
    ["options", { options: [{ id: "x", label: "X" }], recommendation: "x" }],
    ["artifact", { artifact: { type: "markdown", content: "# hi" } }],
    ["stage", { stage: { name: "design", index: 3, total: 4 } }],
  ])("working with %s is rejected with a clear error", (word, extra) => {
    const r = KnockUpdateInput.safeParse({ ...base, working: true, ...extra });
    expect(r.success).toBe(false);
    expect(JSON.stringify(r.error?.issues)).toContain(`cannot carry ${word}`);
  });

  test("working false with options still parses", () => {
    expect(
      KnockUpdateInput.safeParse({ ...base, working: false, options: [{ id: "x", label: "X" }], recommendation: "x" }).success,
    ).toBe(true);
  });

  test("the tool description, the schema, the legacy alias and the guide tell agents about working", () => {
    const tool = MCP_TOOLS.find((t) => t.name === "waggle_update")!;
    expect(tool.description).toContain("working: true");
    expect(JSON.stringify(tool.inputSchema)).toContain('"working"');
    expect(canonicalToolName("knock_update")).toBe("waggle_update");
    expect(getGuide("after-the-reply")).toContain("working: true");
  });
});

describe("Store working update", () => {
  test("the case moves to waiting_on_agent, shows the note and counts no needs_you case", () => {
    const { store, caseId } = setup();
    expect(store.countNeedsYouCases()).toBe(1);
    store.updateCase(caseId, { case_id: caseId, message: base.message, working: true });
    const c = store.getCase(caseId)!;
    expect(c.case.status).toBe("waiting_on_agent");
    expect(c.case.working_note).toBe(base.message);
    expect(c.case.done_at).toBeNull();
    expect(store.countNeedsYouCases()).toBe(0);
    expect(c.messages.at(-1)?.text).toBe(base.message);
  });

  test("each progress note keeps its working flag after the next one, and other messages have none", () => {
    const { store, caseId } = setup();
    store.updateCase(caseId, { case_id: caseId, message: "Reading the screens", working: true });
    store.updateCase(caseId, { case_id: caseId, message: "Running the tests", working: true });
    store.updateCase(caseId, { case_id: caseId, message: "Done." });
    const msgs = store.getCase(caseId)!.messages.slice(-3);
    expect(msgs.map((m) => m.working)).toEqual([true, true, undefined]);
    expect("working" in msgs[2]!).toBe(false);
  });

  test("a note with no working flag is still a needs_you update", () => {
    const { store, caseId } = setup();
    store.updateCase(caseId, { case_id: caseId, message: "Plain answer." });
    const c = store.getCase(caseId)!.case;
    expect(c.status).toBe("needs_you");
    expect(c.working_note).toBeNull();
  });

  test("no ask goes to a connector for a progress note", async () => {
    const { store, caseId, sent } = setup();
    await tick();
    const before = sent.length;
    store.updateCase(caseId, { case_id: caseId, message: base.message, working: true });
    await tick();
    expect(sent.length).toBe(before);
  });

  test("a dismissed case stays resolved", () => {
    const { store, caseId } = setup();
    store.dismissCase(caseId);
    store.updateCase(caseId, { case_id: caseId, message: base.message, working: true });
    const c = store.getCase(caseId)!.case;
    expect(c.status).toBe("resolved");
    expect(c.working_note).toBeNull();
  });

  test("a human reply ends the working note", () => {
    const { store, caseId } = setup();
    store.updateCase(caseId, { case_id: caseId, message: base.message, working: true });
    store.submitReply(caseId, { idempotency_key: "k1", message: "Take your time", comments: [], captures: [] });
    expect(store.getCase(caseId)!.case.working_note).toBeNull();
  });

  test("the next real round restores needs_you and clears the note", () => {
    const { store, caseId } = setup();
    store.updateCase(caseId, { case_id: caseId, message: base.message, working: true });
    // A message without working.
    store.updateCase(caseId, { case_id: caseId, message: "Here it is." });
    let c = store.getCase(caseId)!.case;
    expect(c.status).toBe("needs_you");
    expect(c.working_note).toBeNull();
    // New items after a note.
    store.updateCase(caseId, { case_id: caseId, message: "Still on it.", working: true });
    expect(store.getCase(caseId)!.case.status).toBe("waiting_on_agent");
    store.updateCase(caseId, {
      case_id: caseId,
      message: "Which one?",
      options: [{ id: "x", label: "X" }, { id: "y", label: "Y" }],
      recommendation: "x",
    });
    c = store.getCase(caseId)!.case;
    expect(c.status).toBe("needs_you");
    expect(c.working_note).toBeNull();
    // Done after a note.
    store.updateCase(caseId, { case_id: caseId, message: "Working again.", working: true });
    store.updateCase(caseId, { case_id: caseId, message: "Done.", done: true });
    c = store.getCase(caseId)!.case;
    expect(c.status).toBe("waiting_on_agent");
    expect(c.done_at).not.toBeNull();
    expect(c.working_note).toBeNull();
  });

  test("the options of the earlier round stay stored while the note shows", () => {
    const { store, caseId } = setup();
    store.updateCase(caseId, { case_id: caseId, message: base.message, working: true });
    expect(store.getCase(caseId)!.case.options.map((o) => o.id)).toEqual(["a", "b"]);
  });
});
