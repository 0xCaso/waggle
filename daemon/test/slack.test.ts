import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { ConnectorManager } from "../src/connectors/manager";
import { MemorySecretStore } from "../src/connectors/secrets";
import { SlackConnector, SlackError, slackManifest, type SlackSocket } from "../src/connectors/slack";
import type { KnockAskInput } from "../src/protocol";
import { Store } from "../src/store";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeSlack } from "./fake-slack";
import { rmrf, stageIncoming, tmpHome } from "./helpers";
import { until } from "./fake-telegram";

// HAIL-145: the Slack connector against a fake Slack (Web API + Socket Mode) in this process.

const ask: KnockAskInput = {
  kind: "question",
  title: "Which rules should the agent follow?",
  need: "**Pick** the rules <!channel>\nSecond line the chat never shows",
  why: "Needs a decision",
  recommendation: "a",
  recommendation_why: "It is the safe default",
  options: [
    { id: "a", label: "Approval rules for every change", title: "Approval rules" },
    { id: "b", label: "Trust the agent", title: "Trust" },
  ],
};

let fake: FakeSlack;
let db: Database;
let store: Store;
let bus: EventBus;
let secrets: MemorySecretStore;
let manager: ConnectorManager;
let slack: SlackConnector;
let fetchCalls = 0;
let socketsMade = 0;

// `restart` keeps the database and the secret store, like a daemon that starts again.
function build(opts: { restart?: boolean; home?: string } = {}): void {
  if (!opts.restart) {
    db = new Database(":memory:");
    bus = new EventBus();
    store = new Store(db, opts.home ?? "/tmp/knock-test", bus);
    secrets = new MemorySecretStore();
  }
  manager = new ConnectorManager(store, bus, [], () => {});
  slack = new SlackConnector({
    store,
    secrets,
    host: manager,
    baseUrl: fake.baseUrl,
    fetch: ((...a: Parameters<typeof fetch>) => {
      fetchCalls++;
      return fetch(...a);
    }) as typeof fetch,
    webSocket: (url) => {
      socketsMade++;
      return new WebSocket(url) as unknown as SlackSocket;
    },
    retryDelayMs: 20,
    reconnectDelayMs: 10,
    helloTimeoutMs: 150,
    log: () => {},
  });
  manager.add(slack);
  manager.start();
}

// Runs the whole connect handshake.
async function connect(): Promise<void> {
  await slack.checkTokens(fake.validAppToken, fake.validBotToken);
  const { code } = slack.startPairing();
  // The check's own short socket is `opened` once; the pairing socket is the second.
  await until(() => fake.opened >= 2 && fake.connections === 1);
  fake.dm(code!);
  await until(() => slack.status().state === "connected");
}

function newCase(input: KnockAskInput = ask): string {
  const task = store.createTask({ name: "checkout", project: "knock" });
  return store.createCase(task.id, input).id;
}

async function sentAsk(): Promise<{ caseId: string; ts: string }> {
  await connect();
  const caseId = newCase();
  await until(() => store.findConnectorMessage("slack", caseId) !== null);
  const ts = (store.findConnectorMessage("slack", caseId)!.ref as { ts: string }).ts;
  return { caseId, ts };
}

beforeEach(() => {
  fake = new FakeSlack();
  fetchCalls = 0;
  socketsMade = 0;
  build();
});

afterEach(() => {
  manager.stop();
  fake.stop();
});

describe("connect handshake", () => {
  test("checks both tokens, shows workspace and bot, pairs on a DM code, saves user and DM", async () => {
    expect(slack.status().state).toBe("off");
    const checked = await slack.checkTokens(fake.validAppToken, fake.validBotToken);
    expect(checked).toMatchObject({ state: "token_checked", workspace: "Acme Inc", bot_name: "knock" });
    expect(fake.called("auth.test")).toHaveLength(1);
    expect(fake.called("apps.connections.open")).toHaveLength(1);
    // The check opened a Socket Mode connection and closed it again.
    expect(fake.opened).toBe(1);
    await until(() => fake.connections === 0);

    const waiting = slack.startPairing();
    expect(waiting.state).toBe("waiting_for_start");
    expect(waiting.code).toMatch(/^[A-Z2-9]{6}$/);
    await until(() => fake.opened === 2 && fake.connections === 1);

    // A wrong code, a wrong person and a group message do nothing.
    fake.dm("WRONG1");
    fake.dm(`${waiting.code} and more`);
    fake.dm(waiting.code!, { extra: { channel_type: "channel" } });
    fake.dm(waiting.code!, { extra: { bot_id: "B1" } });
    await until(() => fake.acks.length >= 4);
    expect(slack.status().state).toBe("waiting_for_start");

    fake.dm(waiting.code!);
    await until(() => slack.status().state === "connected");
    expect(slack.status()).toMatchObject({ state: "connected", user_label: "Sam", code: null });
    expect(fake.called("conversations.open")).toHaveLength(1);
    expect(fake.posted.at(-1)!.body.channel).toBe(fake.dmChannel);
  });

  test("a bad token is refused in plain words and nothing is saved", async () => {
    await expect(slack.checkTokens(fake.validAppToken, "xoxb-wrong-wrong")).rejects.toThrow(
      "Slack did not accept that token",
    );
    await expect(slack.checkTokens("xapp-wrong-wrong", fake.validBotToken)).rejects.toThrow(
      "Slack did not accept that token",
    );
    await expect(slack.checkTokens(fake.validBotToken, fake.validBotToken)).rejects.toThrow("starts with xapp-");
    await expect(slack.checkTokens(fake.validAppToken, fake.validAppToken)).rejects.toThrow("starts with xoxb-");
    expect(slack.status().state).toBe("off");
    expect(secrets.get("slack-app-token")).toBeNull();
    expect(secrets.get("slack-bot-token")).toBeNull();
  });

  test("a Socket Mode that never says hello fails the check in plain words", async () => {
    fake.sayHello = false;
    await expect(slack.checkTokens(fake.validAppToken, fake.validBotToken)).rejects.toThrow("Socket Mode");
    expect(slack.status().state).toBe("off");
  });

  test("the saved state survives a daemon restart and the socket resumes", async () => {
    await connect();
    manager.stop();
    await until(() => fake.connections === 0);
    build({ restart: true });
    expect(slack.status()).toMatchObject({ state: "connected", workspace: "Acme Inc" });
    await until(() => fake.connections === 1);
    const id = newCase();
    await until(() => fake.posted.some((p) => String(p.body.text).includes("Which rules")));
    expect(store.findConnectorMessage("slack", id)).not.toBeNull();
  });

  test("disconnect drops both tokens and the chat", async () => {
    await connect();
    await slack.disconnect();
    expect(slack.status().state).toBe("off");
    expect(secrets.get("slack-app-token")).toBeNull();
    expect(secrets.get("slack-bot-token")).toBeNull();
    await until(() => fake.connections === 0);
    build({ restart: true });
    expect(slack.status().state).toBe("off");
  });

  test("send a test posts to the saved DM", async () => {
    await connect();
    await slack.sendTest();
    expect(String(fake.posted.at(-1)!.body.text)).toContain("Waggle test");
    expect(fake.posted.at(-1)!.body.channel).toBe(fake.dmChannel);
  });

  test("the manifest turns on Socket Mode, interactivity, the scopes and message.im", () => {
    const m = JSON.parse(slackManifest());
    expect(m.settings.socket_mode_enabled).toBe(true);
    expect(m.settings.interactivity.is_enabled).toBe(true);
    expect(m.settings.event_subscriptions.bot_events).toContain("message.im");
    expect(m.oauth_config.scopes.bot).toEqual(expect.arrayContaining(["chat:write", "im:write", "im:history"]));
    expect(slack.status().manifest).toBe(slackManifest());
  });
});

describe("ask sent", () => {
  test("one Block Kit message: title, need first line, recommendation, one button per option, more detail", async () => {
    await connect();
    const caseId = newCase();
    await until(() => store.findConnectorMessage("slack", caseId) !== null);
    const body = fake.posted.at(-1)!.body as { blocks: any[]; text: string; parse: string; mrkdwn: boolean };
    expect(body.parse).toBe("none");
    expect(body.mrkdwn).toBe(false);
    expect(body.blocks[0]).toMatchObject({ type: "header", text: { type: "plain_text", text: "Which rules should the agent follow?" } });
    expect(body.blocks[1]).toMatchObject({ type: "context", elements: [{ type: "plain_text", text: "Knock · Claude Code" }] });
    // Plain text only, markers stripped, and only the first line.
    expect(body.blocks[2].text).toEqual({ type: "plain_text", text: "Pick the rules <!channel>", emoji: false });
    expect(JSON.stringify(body)).not.toContain("Second line");
    expect(JSON.stringify(body)).not.toContain('"type":"mrkdwn"');
    expect(body.blocks[3].text.text).toBe("Recommended: Approval rules. It is the safe default");
    const actions = body.blocks.find((b) => b.type === "actions");
    expect(actions.elements.map((e: any) => e.text.text)).toEqual(["Approval rules", "Trust", "Ask for more detail"]);
    expect(actions.elements[0]).toMatchObject({ action_id: "o:0", value: `${caseId}:0` });
  });

  test("an ask with an artifact says to open Waggle on the Mac", async () => {
    manager.stop();
    const home = tmpHome();
    build({ home });
    await connect();
    const task = store.createTask({ name: "t", project: "p" });
    writeFileSync(join(home, "plan.md"), "# plan");
    const artifact = stageIncoming(home, home, { type: "markdown", path: "plan.md" });
    const c = store.createCase(task.id, { ...ask, artifact });
    await until(() => store.findConnectorMessage("slack", c.id) !== null);
    expect(JSON.stringify(fake.posted.at(-1)!.body)).toContain("Open Waggle on your Mac to see the write-up.");
    rmrf(home);
  });
});

describe("replies", () => {
  test("a button press becomes a reply.submit with that choice and source slack, acked at once", async () => {
    const { caseId, ts } = await sentAsk();
    const env = fake.press(ts, "o:0", `${caseId}:0`);
    await until(() => store.getCase(caseId)!.case.latest_reply_id !== null);
    const c = store.getCase(caseId)!.case;
    expect(c).toMatchObject({ status: "waiting_on_agent", latest_reply_choice: "a", latest_reply_source: "slack" });
    const reply = store.getReply(c.latest_reply_id!)!;
    expect(reply.source).toBe("slack");
    expect(reply.idempotency_key).toBe(`slack:cb:${caseId}:0`);
    // The ack can land just after the reply is stored: wait for it.
    await until(() => fake.acks.some((a) => a.id === env));
    const ack = fake.acks.find((a) => a.id === env);
    expect(ack).toBeDefined();
  });

  test("a double press makes one reply", async () => {
    const { caseId, ts } = await sentAsk();
    fake.press(ts, "o:1", `${caseId}:1`);
    fake.press(ts, "o:1", `${caseId}:1`);
    await until(() => fake.acks.length >= 2);
    await Bun.sleep(60);
    expect(store.getCase(caseId)!.case.latest_reply_choice).toBe("b");
    expect((store.getCase(caseId)!.replies ?? []).length).toBe(1);
  });

  test("a press on another option after the first is refused in the thread", async () => {
    const { caseId, ts } = await sentAsk();
    fake.press(ts, "o:0", `${caseId}:0`);
    await until(() => store.getCase(caseId)!.case.latest_reply_id !== null);
    const before = fake.posted.length;
    fake.press(ts, "o:1", `${caseId}:1`);
    await until(() => fake.posted.length > before);
    expect(fake.posted.at(-1)!.body).toMatchObject({ text: "That decision is already answered.", thread_ts: ts });
    expect(store.getCase(caseId)!.case.latest_reply_choice).toBe("a");
  });

  test("Ask for more detail becomes a more_detail reply", async () => {
    const { caseId, ts } = await sentAsk();
    fake.press(ts, "d", caseId);
    await until(() => store.getCase(caseId)!.case.latest_reply_id !== null);
    expect(store.getCase(caseId)!.case).toMatchObject({ latest_reply_intent: "more_detail", latest_reply_source: "slack" });
  });

  test("a thread reply becomes a free-text reply", async () => {
    const { caseId, ts } = await sentAsk();
    fake.dm("Use approval rules, but only for deploys", { thread: ts });
    await until(() => store.getCase(caseId)!.case.latest_reply_id !== null);
    const c = store.getCase(caseId)!.case;
    expect(c).toMatchObject({ latest_reply_message: "Use approval rules, but only for deploys", latest_reply_source: "slack" });
  });

  test("a DM that is not in a thread of an ask is ignored", async () => {
    const { caseId } = await sentAsk();
    fake.dm("hello there");
    fake.dm("a reply to nothing", { thread: "1.1" });
    await until(() => fake.acks.length >= 2);
    await Bun.sleep(40);
    expect(store.getCase(caseId)!.case.latest_reply_id).toBeNull();
  });

  test("events from another user or another channel are ignored", async () => {
    const { caseId, ts } = await sentAsk();
    fake.press(ts, "o:0", `${caseId}:0`, { user: "UEVIL" });
    fake.press(ts, "o:0", `${caseId}:0`, { channel: "DOTHER" });
    fake.dm("sneaky", { thread: ts, user: "UEVIL" });
    fake.dm("sneaky", { thread: ts, channel: "DOTHER" });
    await until(() => fake.acks.length >= 4);
    await Bun.sleep(40);
    expect(store.getCase(caseId)!.case.latest_reply_id).toBeNull();
    // Still open: the right person can answer.
    fake.press(ts, "o:0", `${caseId}:0`);
    await until(() => store.getCase(caseId)!.case.latest_reply_id !== null);
  });
});

describe("outcome update", () => {
  test("a press updates the message to Answered: <option title> and drops the buttons", async () => {
    const { caseId, ts } = await sentAsk();
    fake.press(ts, "o:0", `${caseId}:0`);
    await until(() => fake.called("chat.update").length === 1);
    const update = fake.called("chat.update")[0]!.body as { ts: string; blocks: any[]; channel: string };
    expect(update.ts).toBe(ts);
    expect(update.channel).toBe(fake.dmChannel);
    expect(update.blocks.map((b) => b.type)).toEqual(["header", "section"]);
    expect(update.blocks[1].text.text).toBe("Answered: Approval rules");
  });

  test("a thread reply updates the message too", async () => {
    const { ts } = await sentAsk();
    fake.dm("my own words", { thread: ts });
    await until(() => fake.called("chat.update").length === 1);
    expect(JSON.stringify(fake.called("chat.update")[0]!.body)).toContain("Answered: my own words");
  });

  test("an answer from the Mac updates the message to Answered on your Mac, once", async () => {
    const { caseId } = await sentAsk();
    store.submitReply(caseId, { idempotency_key: "mac-1", choice: "b", comments: [], captures: [] });
    await until(() => fake.called("chat.update").length === 1);
    expect(JSON.stringify(fake.called("chat.update")[0]!.body)).toContain("Answered on your Mac");
    await Bun.sleep(80);
    expect(fake.called("chat.update")).toHaveLength(1);
  });
});

describe("reconnect", () => {
  test("after a drop the connector opens a new socket and keeps working", async () => {
    const { caseId, ts } = await sentAsk();
    const before = fake.opened;
    fake.drop();
    await until(() => fake.opened > before && fake.connections === 1);
    fake.press(ts, "o:0", `${caseId}:0`);
    await until(() => store.getCase(caseId)!.case.latest_reply_id !== null);
  });

  test("a refresh request opens a new socket at once", async () => {
    await connect();
    const before = fake.opened;
    fake.refresh();
    await until(() => fake.opened > before && fake.connections === 1);
  });

  test("while Slack is down the connector backs off, then recovers", async () => {
    await connect();
    fake.sayHello = false;
    fake.drop();
    await until(() => fake.opened >= 4);
    expect(slack.status().error).toContain("trying again");
    fake.sayHello = true;
    await until(() => slack.status().error === null, 5000);
  });
});

describe("secrets and the network", () => {
  test("both tokens are in the secret store and never in knock.db", async () => {
    await connect();
    newCase();
    const raw = Buffer.from(db.serialize()).toString("latin1");
    expect(secrets.get("slack-app-token")).toBe(fake.validAppToken);
    expect(secrets.get("slack-bot-token")).toBe(fake.validBotToken);
    expect(raw).not.toContain("TEST-app-token");
    expect(raw).not.toContain("TEST-bot-token");
  });

  test("an error never carries a token", async () => {
    fake.stop();
    const err = await slack.checkTokens(fake.validAppToken, fake.validBotToken).catch((e: Error) => e);
    expect(err).toBeInstanceOf(SlackError);
    expect((err as Error).message).toBe("Could not reach Slack. Check your connection.");
    fake = new FakeSlack();
  });

  test("a socket address that is not slack.com is refused", async () => {
    const real = new SlackConnector({
      store,
      secrets,
      host: manager,
      fetch: (async () => Response.json({ ok: true, team: "T", user: "u", url: "wss://evil.example.com/link" })) as unknown as typeof fetch,
      webSocket: () => {
        throw new Error("must not open");
      },
      log: () => {},
    });
    await expect(real.checkTokens(fake.validAppToken, fake.validBotToken)).rejects.toThrow("does not trust");
  });

  test("with the connector off the daemon makes no network call", async () => {
    const id = newCase();
    store.submitReply(id, { idempotency_key: "k", choice: "a", comments: [], captures: [] });
    await Bun.sleep(100);
    expect(fetchCalls).toBe(0);
    expect(socketsMade).toBe(0);
    expect(fake.calls).toHaveLength(0);
    expect(fake.opened).toBe(0);
    expect(manager.keepAlive()).toBe(false);
  });
});

describe("daemon lifetime", () => {
  test("keepAlive is true only while the connector is on and an ask is open", async () => {
    await connect();
    expect(manager.keepAlive()).toBe(false);
    const caseId = newCase();
    expect(manager.keepAlive()).toBe(true);
    store.submitReply(caseId, { idempotency_key: "x", choice: "a", comments: [], captures: [] });
    expect(manager.keepAlive()).toBe(false);
  });
});
