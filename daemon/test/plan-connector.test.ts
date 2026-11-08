import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { ConnectorManager, askMessageFor, planStageLine } from "../src/connectors/manager";
import { MemorySecretStore } from "../src/connectors/secrets";
import { TelegramConnector } from "../src/connectors/telegram";
import { KnockAskInput, KnockUpdateInput } from "../src/protocol";
import { Store } from "../src/store";
import { FakeTelegram, until } from "./fake-telegram";

// HAIL-151: a plan round goes to the phone like a normal ask, one message per round.

const ask = KnockAskInput.parse({
  kind: "plan",
  stage: { name: "questions", step: 1, total: 5, total_is_estimate: true },
  title: "Plan: onboarding",
  need: "Who is the first user?",
  why: "It decides the first screen.",
  recommendation: "a",
  recommendation_why: "Most users are new.",
  options: [
    { id: "a", title: "New users", label: "People who just installed Waggle" },
    { id: "b", title: "Teams", label: "Teams who share a queue" },
  ],
});

let fake: FakeTelegram;
let store: Store;
let manager: ConnectorManager;
let tg: TelegramConnector;

beforeEach(() => {
  fake = new FakeTelegram();
  const bus = new EventBus();
  store = new Store(new Database(":memory:"), "/tmp/knock-test", bus);
  manager = new ConnectorManager(store, bus, [], () => {});
  tg = new TelegramConnector({
    store,
    secrets: new MemorySecretStore(),
    host: manager,
    baseUrl: fake.baseUrl,
    pollTimeoutS: 1,
    idleDelayMs: 5,
    retryDelayMs: 20,
    log: () => {},
  });
  manager.add(tg);
  manager.start();
});

afterEach(() => {
  manager.stop();
  fake.stop();
});

describe("planStageLine", () => {
  test("reads the stage in plain words", () => {
    expect(planStageLine({ name: "questions", step: 3, total: 5, total_is_estimate: true })).toBe("Brainstorm · question 3 of ~5");
    expect(planStageLine({ name: "questions", step: 2, total: 4 })).toBe("Brainstorm · question 2 of 4");
    expect(planStageLine({ name: "questions" })).toBe("Brainstorm");
    expect(planStageLine({ name: "approaches" })).toBe("Approaches · pick one");
    expect(planStageLine({ name: "design", step: 1, total: 3 })).toBe("Design · section 1 of 3");
    expect(planStageLine({ name: "spec" })).toBe("Spec · ready for review");
  });
});

describe("plan ask on the phone", () => {
  test("shows the stage line, then one new message for the next round", async () => {
    await tg.checkToken(fake.validToken);
    const { code } = tg.startPairing();
    fake.sendText(777, `/start ${code}`);
    await until(() => tg.status().state === "connected");

    const task = store.createTask({ name: "checkout", project: "knock" });
    const created = store.createCase(task.id, ask);
    await until(() => fake.called("sendMessage").some((c) => String(c.body.text).includes("Brainstorm")));
    const first = fake.called("sendMessage").at(-1)!.body;
    expect(String(first.text)).toContain("Brainstorm · question 1 of ~5 · Plan: onboarding");
    expect(String(first.text)).toContain("Who is the first user?");

    const messageId = fake.sent.at(-1)!.message_id;
    fake.tap(777, messageId, `o:${created.id}:1`);
    await until(() => store.getCase(created.id)!.case.latest_reply_id !== null);
    expect(store.getCase(created.id)!.plan_rounds![0]!.answer?.choice).toBe("b");

    store.updateCase(
      created.id,
      KnockUpdateInput.parse({
        case_id: created.id,
        message: "Which approach fits?",
        stage: { name: "approaches" },
        options: [
          { id: "x", title: "Wizard", label: "A wizard" },
          { id: "y", title: "Checklist", label: "A checklist" },
        ],
        recommendation: "x",
        recommendation_why: "Shortest path.",
      }),
    );
    await until(() => fake.called("sendMessage").some((c) => String(c.body.text).includes("Approaches · pick one")));
    const second = String(fake.called("sendMessage").at(-1)!.body.text);
    expect(second).toContain("Which approach fits?");
    expect(second).not.toContain("Who is the first user?");
    expect(store.listCases()).toHaveLength(1);
  });

  test("an ordinary ask keeps its plain title", () => {
    const task = store.createTask({ name: "t", project: "p" });
    const { stage: _s, kind: _k, ...rest } = ask;
    const c = store.createCase(task.id, KnockAskInput.parse({ ...rest, kind: "question" }));
    expect(askMessageFor(c).title).toBe("Plan: onboarding");
  });
});
