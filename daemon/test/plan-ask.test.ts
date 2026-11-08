import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { EventBus } from "../src/events";
import { migrate } from "../src/schema";
import { startRpcServer, type RpcServer } from "../src/server";
import { Store } from "../src/store";
import { Case, CaseDetail, KnockAskInput, KnockUpdateInput, MCP_TOOLS, PlanStage } from "../src/protocol";
import { getGuide, guideTopics } from "../src/guide";
import pkg from "../package.json" with { type: "json" };
import { rmrf, tmpHome } from "./helpers";

// HAIL-151: a plan ask is one case that walks the brainstorming stages. Each later round is a
// waggle_update with a stage; the daemon keeps the history and the app folds it into "N answered".

const planAsk = {
  kind: "plan" as const,
  stage: { name: "questions" as const, step: 1, total: 5, total_is_estimate: true },
  title: "Plan: onboarding flow",
  need: "Who is the first user of onboarding?",
  why: "It decides the first screen.",
  recommendation: "a",
  recommendation_why: "Most of your users are new.",
  options: [
    { id: "a", title: "New users", label: "People who just installed Waggle" },
    { id: "b", title: "Teams", label: "Teams who share a queue" },
  ],
};

const nextRound = {
  message: "Which approach fits?",
  stage: { name: "approaches" as const },
  options: [
    { id: "x", title: "Wizard", label: "A step by step wizard" },
    { id: "y", title: "Checklist", label: "One checklist page" },
  ],
  recommendation: "x",
  recommendation_why: "It is the shortest path.",
};

function setup(): { store: Store; taskId: string } {
  const store = new Store(new Database(":memory:"), "/tmp/knock-test", new EventBus());
  const task = store.createTask({ name: "HAIL-151", project: "app" });
  return { store, taskId: task.id };
}

describe("plan ask protocol", () => {
  test("a plan ask with a stage parses, round-trips and keeps the open input schema", () => {
    const parsed = KnockAskInput.parse(planAsk);
    expect(PlanStage.parse(parsed.stage)).toEqual(planAsk.stage);
    const tool = MCP_TOOLS.find((t) => t.name === "waggle_ask")!;
    const props = (tool.inputSchema as { properties: Record<string, { enum?: string[] }> }).properties;
    expect(props.kind!.enum).toEqual(["question", "review", "plan"]);
    expect(props.stage).toBeDefined();
    expect(tool.inputSchema.additionalProperties).toBe(true);
  });

  // WAG-312 (operator decision Q6): a stage label is allowed on any ask. Only kind plan needs one.
  test("a plan ask without a stage is rejected, and a stage on a question is accepted", () => {
    const { stage: _stage, ...noStage } = planAsk;
    expect(KnockAskInput.safeParse(noStage).success).toBe(false);
    expect(KnockAskInput.safeParse({ ...planAsk, kind: "question" }).success).toBe(true);
  });

  test("a stage name outside the four stages is rejected", () => {
    expect(PlanStage.safeParse({ name: "polish" }).success).toBe(false);
    expect(PlanStage.safeParse({ name: "design", step: 0 }).success).toBe(false);
  });

  // WAG-312 (spec 2.2): a stage alone relabels the round. Options still need a recommendation.
  test("a waggle_update with a stage needs no options, but options need a recommendation", () => {
    expect(KnockUpdateInput.safeParse({ case_id: "c1", ...nextRound }).success).toBe(true);
    const { options: _o, recommendation: _r, recommendation_why: _w, ...noOptions } = nextRound;
    expect(KnockUpdateInput.safeParse({ case_id: "c1", ...noOptions }).success).toBe(true);
    const { recommendation: _r2, ...noRecommendation } = nextRound;
    expect(KnockUpdateInput.safeParse({ case_id: "c1", ...noRecommendation }).success).toBe(false);
  });
});

describe("plan ask rounds", () => {
  test("a plan ask is a question on the wire with a plan field", () => {
    const { store, taskId } = setup();
    const created = store.createCase(taskId, KnockAskInput.parse(planAsk));
    expect(created.kind).toBe("question");
    expect(created.plan).toEqual({ stage: planAsk.stage, rounds: 1, answered: 0 });
    const listed = store.listCases().find((c) => c.id === created.id)!;
    expect(listed.kind).toBe("question");
    expect(Case.parse(listed).plan?.stage.name).toBe("questions");
  });

  test("an ordinary question has no plan field", () => {
    const { store, taskId } = setup();
    const { kind: _k, stage: _s, ...rest } = planAsk;
    const created = store.createCase(taskId, KnockAskInput.parse({ ...rest, kind: "question" }));
    expect(store.getCase(created.id)!.case.plan).toBeUndefined();
    expect(store.getCase(created.id)!.plan_rounds).toBeUndefined();
  });

  test("rounds stay on one case and the history records each answer", () => {
    const { store, taskId } = setup();
    const { id } = store.createCase(taskId, KnockAskInput.parse(planAsk));
    store.createReply(id, { idempotency_key: "k1", choice: "b", comments: [], captures: [] });
    expect(store.getCase(id)!.case.status).toBe("waiting_on_agent");
    expect(store.getCase(id)!.case.plan).toEqual({ stage: planAsk.stage, rounds: 1, answered: 1 });

    const updated = store.updateCase(id, KnockUpdateInput.parse({ case_id: id, ...nextRound }))!;
    expect(updated.status).toBe("needs_you");
    expect(updated.plan).toEqual({ stage: { name: "approaches" }, rounds: 2, answered: 1 });
    expect(updated.options.map((o) => o.id)).toEqual(["x", "y"]);
    expect(store.listCases().filter((c) => c.id === id)).toHaveLength(1);

    const detail = CaseDetail.parse(store.getCase(id));
    const rounds = detail.plan_rounds!;
    expect(rounds.map((r) => r.stage.name)).toEqual(["questions", "approaches"]);
    expect(rounds[0]!.question).toBe(planAsk.need);
    expect(rounds[0]!.answer?.choice).toBe("b");
    expect(rounds[0]!.options.map((o) => o.id)).toEqual(["a", "b"]);
    expect(rounds[1]!.question).toBe("Which approach fits?");
    expect(rounds[1]!.answer).toBeNull();
  });

  test("a more-detail reply does not count as an answer", () => {
    const { store, taskId } = setup();
    const { id } = store.createCase(taskId, KnockAskInput.parse(planAsk));
    store.createReply(id, { idempotency_key: "k1", intent: "more_detail", comments: [], captures: [] });
    expect(store.getCase(id)!.case.plan?.answered).toBe(0);
    expect(store.getCase(id)!.plan_rounds![0]!.answer).toBeNull();
  });

  test("an update with options but no stage stays at the same stage as a new round", () => {
    const { store, taskId } = setup();
    const { id } = store.createCase(taskId, KnockAskInput.parse(planAsk));
    const { stage: _s, ...noStage } = nextRound;
    store.updateCase(id, KnockUpdateInput.parse({ case_id: id, ...noStage }));
    const plan = store.getCase(id)!.case.plan!;
    expect(plan.stage.name).toBe("questions");
    expect(plan.rounds).toBe(2);
  });

  // WAG-313 (spec 2.2, operator decision Q6): this rule reversed. The old test expected a refusal.
  test("a stage on a case that is not a plan ask starts the track", () => {
    const { store, taskId } = setup();
    const { kind: _k, stage: _s, ...rest } = planAsk;
    const { id } = store.createCase(taskId, KnockAskInput.parse({ ...rest, kind: "question" }));
    expect(store.getCase(id)!.case.plan).toBeUndefined();
    store.updateCase(id, KnockUpdateInput.parse({ case_id: id, ...nextRound }));
    const detail = store.getCase(id)!;
    expect(detail.case.plan?.stage.name).toBe("approaches");
    expect(detail.plan_rounds).toHaveLength(1);
    expect(detail.rounds!.map((r) => r.stage?.name)).toEqual([undefined, "approaches"]);
  });

  test("a stage alone relabels the current round", () => {
    const { store, taskId } = setup();
    const { id } = store.createCase(taskId, KnockAskInput.parse(planAsk));
    store.updateCase(id, KnockUpdateInput.parse({ case_id: id, message: "Moving on.", stage: { name: "design", step: 2 } }));
    const detail = store.getCase(id)!;
    expect(detail.case.plan?.stage).toEqual({ name: "design", step: 2 });
    expect(detail.rounds).toHaveLength(1);
    expect(detail.case.options.map((o) => o.id)).toEqual(["a", "b"]);
  });

  test("the reply payload of a plan ask tells the agent to keep using the case", () => {
    const { store, taskId } = setup();
    const { id } = store.createCase(taskId, KnockAskInput.parse(planAsk));
    const reply = store.createReply(id, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    const payload = store.buildReplyPayload(reply.id)!;
    const last = payload.content[payload.content.length - 1]!;
    expect(last.type === "text" && last.text).toContain(`waggle_update on this case`);
    expect(last.type === "text" && last.text).toContain("Do not ask in the terminal");
  });

  test("the reply payload of an ordinary question is unchanged", () => {
    const { store, taskId } = setup();
    const { kind: _k, stage: _s, ...rest } = planAsk;
    const { id } = store.createCase(taskId, KnockAskInput.parse({ ...rest, kind: "question" }));
    const reply = store.createReply(id, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    const payload = store.buildReplyPayload(reply.id)!;
    expect(payload.content).toHaveLength(1);
  });

  test("a database from before the plan columns migrates and keeps its cases", () => {
    const db = new Database(":memory:");
    migrate(db);
    db.exec(`PRAGMA user_version = 24`);
    db.exec(`ALTER TABLE option_sets DROP COLUMN stage_json; ALTER TABLE option_sets DROP COLUMN question; ALTER TABLE replies DROP COLUMN plan_round;`);
    migrate(db);
    const store = new Store(db, "/tmp/knock-test", new EventBus());
    const task = store.createTask({ name: "t", project: "p" });
    const created = store.createCase(task.id, KnockAskInput.parse(planAsk));
    expect(store.getCase(created.id)!.plan_rounds).toHaveLength(1);
  });
});

describe("plan guide", () => {
  test("waggle_guide has a plan topic with a ready template", () => {
    expect(guideTopics()).toContain("plan");
    const text = getGuide("plan");
    expect(text).not.toContain('kind: "plan"');
    expect(text).toContain('stage: { name: "questions"');
    expect(text).toContain("waggle_update");
    expect(text).toContain("approaches");
    expect(text).toContain("Never ask these in the terminal");
  });
});

// The shim: a plan ask through the real `waggle mcp`.
const homes: string[] = [];
const servers: RpcServer[] = [];
const clients: { client: Client; transport: StdioClientTransport }[] = [];
afterEach(async () => {
  for (const c of clients.splice(0)) {
    await c.transport.close().catch(() => {});
    await c.client.close().catch(() => {});
  }
  for (const s of servers.splice(0)) s.stop();
  for (const h of homes.splice(0)) rmrf(h);
});

describe("waggle mcp with a plan ask", () => {
  test("waggle_ask kind plan, then waggle_update with a stage, keep one case", async () => {
    const home = tmpHome();
    homes.push(home);
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });
    const bus = new EventBus();
    const store = new Store(new Database(join(home, "knock.db")), home, bus);
    servers.push(startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: pkg.version }));
    const transport = new StdioClientTransport({
      command: process.execPath,
      args: [join(import.meta.dir, "..", "src", "index.ts"), "mcp"],
      env: { KNOCK_HOME: home, CLAUDE_CODE_SESSION_ID: "sess-plan", KNOCK_ASK_WAIT_MS: "300" },
      cwd,
      stderr: "pipe",
    });
    const client = new Client({ name: "knock-test", version: "0.0.0" }, { capabilities: {} });
    await client.connect(transport);
    clients.push({ client, transport });

    const first = await client.callTool({ name: "waggle_ask", arguments: planAsk });
    expect(first.isError).toBeFalsy();
    const caseId = store.listCases()[0]!.id;
    expect(store.getCase(caseId)!.case.plan?.stage.name).toBe("questions");

    store.createReply(caseId, { idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    const update = await client.callTool({
      name: "waggle_update",
      arguments: { case_id: caseId, ...nextRound },
    });
    expect(update.isError).toBeFalsy();
    expect(store.listCases()).toHaveLength(1);
    expect(store.getCase(caseId)!.case.plan).toEqual({ stage: { name: "approaches" }, rounds: 2, answered: 1 });

    const bad = await client.callTool({
      name: "waggle_ask",
      arguments: { ...planAsk, stage: undefined },
    });
    expect(bad.isError).toBe(true);
    expect(store.listCases()).toHaveLength(1);
  });
});

// WAG-313 (spec 2.8): a plan round is answered by a reply that decides, not by a reply that only comments.
describe("plan round answer", () => {
  test("a comments-only reply keeps the round open; a decision answers it; kind plan is stored as question", () => {
    const { store, taskId } = setup();
    const created = store.createCase(taskId, KnockAskInput.parse(planAsk));
    expect(created.kind).toBe("question");
    store.createReply(created.id, { idempotency_key: "c1", message: "Change the wording.", comments: [], captures: [] });
    expect(store.getCase(created.id)!.case.plan).toMatchObject({ rounds: 1, answered: 0 });
    store.createReply(created.id, { idempotency_key: "c2", choice: "a", comments: [], captures: [] });
    const detail = store.getCase(created.id)!;
    expect(detail.case.plan).toMatchObject({ rounds: 1, answered: 1 });
    expect(detail.plan_rounds![0]!.answer).toMatchObject({ choice: "a" });
    expect(detail.rounds![0]).toMatchObject({ stage: planAsk.stage, talk_count: 1 });
  });
});

