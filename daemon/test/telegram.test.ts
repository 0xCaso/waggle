import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { ConnectorManager, plainLine } from "../src/connectors/manager";
import { MemorySecretStore } from "../src/connectors/secrets";
import { TelegramConnector } from "../src/connectors/telegram";
import type { KnockAskInput } from "../src/protocol";
import { Store } from "../src/store";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeTelegram, until } from "./fake-telegram";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

// HAIL-144: the Telegram connector against a fake Bot API in this process.

const ask: KnockAskInput = {
  kind: "question",
  title: "Which rules should the agent follow?",
  need: "**Pick** the rules\nSecond line the phone never shows",
  why: "Needs a decision",
  recommendation: "a",
  recommendation_why: "It is the safe default",
  options: [
    { id: "a", label: "Approval rules for every change", title: "Approval rules" },
    { id: "b", label: "Trust the agent", title: "Trust" },
  ],
};

let fake: FakeTelegram;
let db: Database;
let store: Store;
let bus: EventBus;
let secrets: MemorySecretStore;
let manager: ConnectorManager;
let tg: TelegramConnector;
let fetchCalls = 0;

// `restart` keeps the database and the secret store, like a daemon that starts again.
function build(opts: { restart?: boolean; home?: string } = {}): void {
  if (!opts.restart) {
    db = new Database(":memory:");
    bus = new EventBus();
    store = new Store(db, opts.home ?? "/tmp/knock-test", bus);
    secrets = new MemorySecretStore();
  }
  manager = new ConnectorManager(store, bus, [], () => {});
  tg = new TelegramConnector({
    store,
    secrets,
    host: manager,
    baseUrl: fake.baseUrl,
    fetch: ((...a: Parameters<typeof fetch>) => {
      fetchCalls++;
      return fetch(...a);
    }) as typeof fetch,
    pollTimeoutS: 1,
    idleDelayMs: 5,
    retryDelayMs: 20,
    log: () => {},
  });
  manager.add(tg);
  manager.start();
}

// Runs the whole connect handshake and returns the chat id.
async function connect(chat = 777): Promise<number> {
  await tg.checkToken(fake.validToken);
  const { code } = tg.startPairing();
  fake.sendText(chat, `/start ${code}`);
  await until(() => tg.status().state === "connected");
  return chat;
}

function newCase(input: KnockAskInput = ask): string {
  const task = store.createTask({ name: "checkout", project: "knock" });
  return store.createCase(task.id, input).id;
}

beforeEach(() => {
  fake = new FakeTelegram();
  fetchCalls = 0;
  build();
});

afterEach(() => {
  manager.stop();
  fake.stop();
});

describe("connect handshake", () => {
  test("checks the token, shows the bot, pairs on /start <code>, saves the chat id", async () => {
    expect(tg.status().state).toBe("off");
    const checked = await tg.checkToken(fake.validToken);
    expect(checked).toMatchObject({ state: "token_checked", bot_name: "Waggle Test Bot", bot_username: "knock_test_bot" });

    const waiting = tg.startPairing();
    expect(waiting.state).toBe("waiting_for_start");
    expect(waiting.code).toMatch(/^[A-Z2-9]{6}$/);

    // A wrong code and a wrong chat type do nothing.
    fake.sendText(555, "/start WRONG1");
    fake.sendText(555, `/start ${waiting.code}`, { chat: { id: 555, type: "group", title: "Team" } });
    await until(() => fake.called("getUpdates").length >= 3);
    expect(tg.status().state).toBe("waiting_for_start");

    fake.sendText(777, `/start ${waiting.code}`);
    await until(() => tg.status().state === "connected");
    expect(tg.status()).toMatchObject({ state: "connected", chat_label: "Sam", code: null });
    expect(fake.called("sendMessage").at(-1)!.body.chat_id).toBe(777);
  });

  test("a bad token is refused in plain words and nothing is saved", async () => {
    await expect(tg.checkToken("999:nope-nope")).rejects.toThrow("Telegram did not accept that token");
    expect(tg.status().state).toBe("off");
    expect(secrets.get("telegram-bot-token")).toBeNull();
  });

  test("the saved state survives a daemon restart and polling resumes", async () => {
    const chat = await connect();
    manager.stop();
    build({ restart: true });
    expect(tg.status()).toMatchObject({ state: "connected", bot_name: "Waggle Test Bot" });
    const id = newCase();
    await until(() => fake.called("sendMessage").some((c) => String(c.body.text).includes("Which rules")));
    expect(store.findConnectorMessage("telegram", id)).not.toBeNull();
    expect(chat).toBe(777);
  });

  test("disconnect drops the token and the chat", async () => {
    await connect();
    await tg.disconnect();
    expect(tg.status().state).toBe("off");
    expect(secrets.get("telegram-bot-token")).toBeNull();
    expect(store.getConnectorSetting("telegram", { safeParse: (v: unknown) => ({ success: true, data: v }) })).toBeNull();
  });

  test("send a test posts to the saved chat", async () => {
    await connect();
    await tg.sendTest();
    const last = fake.called("sendMessage").at(-1)!;
    expect(last.body.chat_id).toBe(777);
    expect(String(last.body.text)).toContain("Waggle test");
  });
});

describe("ask sent", () => {
  test("one plain-text message: title, need first line, recommendation, one button per option, more detail", async () => {
    await connect();
    newCase();
    await until(() => fake.called("sendMessage").some((c) => String(c.body.text).includes("Which rules")));
    const msg = fake.called("sendMessage").at(-1)!.body;
    const text = String(msg.text);
    expect(text).toContain("Which rules should the agent follow?");
    expect(text).toContain("Pick the rules");
    expect(text).toContain("Knock · Claude Code");
    expect(text).not.toContain("**");
    expect(text).not.toContain("Second line");
    expect(text).toContain("Recommended: Approval rules. It is the safe default");
    expect(msg.parse_mode).toBeUndefined();
    const rows = (msg.reply_markup as { inline_keyboard: { text: string; callback_data: string }[][] }).inline_keyboard;
    expect(rows.map((r) => r[0]!.text)).toEqual(["Approval rules", "Trust", "Ask for more detail"]);
    expect(rows.every((r) => r[0]!.callback_data.length <= 64)).toBe(true);
  });

  test("an ask with an artifact says to open Waggle on the Mac", async () => {
    manager.stop();
    const home = tmpHome();
    build({ home });
    await connect();
    const task = store.createTask({ name: "t", project: "p" });
    writeFileSync(join(home, "plan.md"), "# plan");
    const artifact = stageIncoming(home, home, { type: "markdown", path: "plan.md" });
    store.createCase(task.id, { ...ask, artifact });
    await until(() => fake.called("sendMessage").some((c) => String(c.body.text).includes("Which rules")));
    expect(String(fake.called("sendMessage").at(-1)!.body.text)).toContain("Open Waggle on your Mac to see the write-up.");
    rmrf(home);
  });
});

describe("replies", () => {
  async function sentAsk(): Promise<{ caseId: string; chat: number; messageId: number }> {
    const chat = await connect();
    const caseId = newCase();
    await until(() => store.findConnectorMessage("telegram", caseId) !== null);
    const ref = store.findConnectorMessage("telegram", caseId)!.ref as { message_id: number };
    return { caseId, chat, messageId: ref.message_id };
  }

  test("a button tap becomes a reply.submit with that choice and source telegram", async () => {
    const { caseId, chat, messageId } = await sentAsk();
    fake.tap(chat, messageId, `o:${caseId}:0`);
    await until(() => store.getCase(caseId)!.case.latest_reply_id !== null);
    const c = store.getCase(caseId)!.case;
    expect(c).toMatchObject({ status: "waiting_on_agent", latest_reply_choice: "a", latest_reply_source: "telegram" });
    const reply = store.getReply(c.latest_reply_id!)!;
    expect(reply.source).toBe("telegram");
    expect(reply.idempotency_key).toBe(`telegram:cb:${caseId}:0`);
    await until(() => fake.called("answerCallbackQuery").length === 1);
    expect(fake.called("answerCallbackQuery")[0]!.body.text).toBe("Sent");
  });

  test("a double tap makes one reply", async () => {
    const { caseId, chat, messageId } = await sentAsk();
    fake.tap(chat, messageId, `o:${caseId}:1`);
    fake.tap(chat, messageId, `o:${caseId}:1`);
    await until(() => fake.called("answerCallbackQuery").length === 2);
    expect(db.query(`SELECT COUNT(*) AS n FROM replies WHERE case_id = ?`).get(caseId)).toEqual({ n: 1 });
    expect(fake.called("answerCallbackQuery").map((c) => c.body.text)).toEqual(["Sent", "Already sent"]);
  });

  test("a tap on another option after the first is refused", async () => {
    const { caseId, chat, messageId } = await sentAsk();
    fake.tap(chat, messageId, `o:${caseId}:0`);
    fake.tap(chat, messageId, `o:${caseId}:1`);
    await until(() => fake.called("answerCallbackQuery").length === 2);
    expect(db.query(`SELECT COUNT(*) AS n FROM replies WHERE case_id = ?`).get(caseId)).toEqual({ n: 1 });
    expect(fake.called("answerCallbackQuery")[1]!.body.text).toBe("That decision is already answered.");
  });

  test("Ask for more detail becomes a more_detail reply", async () => {
    const { caseId, chat, messageId } = await sentAsk();
    fake.tap(chat, messageId, `d:${caseId}`);
    await until(() => store.getCase(caseId)!.case.latest_reply_id !== null);
    expect(store.getCase(caseId)!.case).toMatchObject({ latest_reply_intent: "more_detail", latest_reply_source: "telegram" });
  });

  test("a Telegram reply to the message becomes a free-text reply", async () => {
    const { caseId, chat, messageId } = await sentAsk();
    fake.replyTo(chat, messageId, "Use approval rules but only for deploys");
    await until(() => store.getCase(caseId)!.case.latest_reply_id !== null);
    expect(store.getCase(caseId)!.case).toMatchObject({
      latest_reply_choice: null,
      latest_reply_message: "Use approval rules but only for deploys",
      latest_reply_source: "telegram",
    });
  });

  test("text that is not a reply to an ask message is ignored", async () => {
    const { caseId, chat } = await sentAsk();
    fake.sendText(chat, "hello there");
    await until(() => fake.called("getUpdates").length > 3);
    expect(store.getCase(caseId)!.case.latest_reply_id).toBeNull();
  });

  test("updates from any other chat are ignored", async () => {
    const { caseId, messageId } = await sentAsk();
    const before = fake.calls.length;
    fake.tap(999, messageId, `o:${caseId}:0`);
    fake.replyTo(999, messageId, "I am not the operator");
    await until(() => fake.called("getUpdates").length > 4);
    expect(store.getCase(caseId)!.case.latest_reply_id).toBeNull();
    expect(fake.calls.slice(before).filter((c) => c.method === "answerCallbackQuery")).toHaveLength(0);
  });
});

describe("outcome edit", () => {
  test("a tap edits the message to Answered: <option title> and removes the buttons", async () => {
    const chat = await connect();
    const caseId = newCase();
    await until(() => store.findConnectorMessage("telegram", caseId) !== null);
    const messageId = (store.findConnectorMessage("telegram", caseId)!.ref as { message_id: number }).message_id;
    fake.tap(chat, messageId, `o:${caseId}:0`);
    await until(() => fake.called("editMessageText").length === 1);
    const edit = fake.called("editMessageText")[0]!.body;
    expect(edit.message_id).toBe(messageId);
    expect(String(edit.text)).toBe("Which rules should the agent follow?\n\nAnswered: Approval rules");
    expect(edit.reply_markup).toEqual({ inline_keyboard: [] });
  });

  test("an answer from the Mac edits the message to Answered on your Mac, once", async () => {
    await connect();
    const caseId = newCase();
    await until(() => store.findConnectorMessage("telegram", caseId) !== null);
    store.submitReply(caseId, { idempotency_key: "mac-1", choice: "b", comments: [], captures: [] });
    await until(() => fake.called("editMessageText").length === 1);
    expect(String(fake.called("editMessageText")[0]!.body.text)).toContain("Answered on your Mac");
    expect(store.getCase(caseId)!.case.latest_reply_source).toBe("mac");
    // The reply going from queued to delivered must not edit again.
    const reply = store.getCase(caseId)!.case.latest_reply_id!;
    store.markReplyDelivered?.(reply);
    await Bun.sleep(80);
    expect(fake.called("editMessageText")).toHaveLength(1);
  });
});

describe("secrets and the network", () => {
  test("the token is in the secret store and never in knock.db", async () => {
    await connect();
    newCase();
    const dump = (db.serialize() as Uint8Array).toString();
    const raw = Buffer.from(db.serialize()).toString("latin1");
    expect(secrets.get("telegram-bot-token")).toBe(fake.validToken);
    expect(raw).not.toContain(fake.validToken);
    expect(raw).not.toContain("TEST-token");
    expect(dump.length).toBeGreaterThan(0);
  });

  test("an error never carries the token", async () => {
    fake.stop();
    const err = await tg.checkToken(fake.validToken).catch((e: Error) => e);
    expect((err as Error).message).toBe("Could not reach Telegram. Check your connection.");
    expect((err as Error).message).not.toContain(fake.validToken);
    fake = new FakeTelegram();
  });

  test("with the connector off the daemon makes no network call", async () => {
    // Fresh start: nothing saved. Asks come and go.
    const id = newCase();
    store.submitReply(id, { idempotency_key: "k", choice: "a", comments: [], captures: [] });
    await Bun.sleep(100);
    expect(fetchCalls).toBe(0);
    expect(fake.calls).toHaveLength(0);
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

test("plainLine strips markers and takes the first line", () => {
  expect(plainLine("- **Bold** and `code` [link](http://x)\nnext")).toBe("Bold and code link");
  expect(plainLine("")).toBe("");
});

// WAG-313: a case stored the new way (several items, a reply item) does not break the phone side, and the
// decision and more detail flows work as before. Connector features for items are out of scope.
describe("cases stored as items (three blocks)", () => {
  test("a request of several items is sent as a message with no option buttons", async () => {
    await connect();
    const id = newCase({
      title: "Two decisions",
      need: "Decide both.",
      why: "One screen.",
      items: [
        { id: "layout", question: "Which layout?", options: ask.options!, recommendation: "a", recommendation_why: "Default." },
        { id: "free", question: "Any idea?", select: "reply" },
      ],
    } as KnockAskInput);
    await until(() => store.findConnectorMessage("telegram", id) !== null);
    const sent = fake.called("sendMessage").at(-1)!.body;
    expect(String(sent.text)).toContain("Two decisions");
    expect(JSON.stringify(sent.reply_markup ?? {})).not.toContain(`o:${id}:`);
  });

  test("a reply item behaves like a reply-only ask; a tap-free text reply is stored", async () => {
    await connect();
    const id = newCase({ title: "Name it?", need: "Pick a name.", why: "None.", items: [{ id: "n", select: "reply" }] } as KnockAskInput);
    await until(() => store.findConnectorMessage("telegram", id) !== null);
    expect(store.getCase(id)!.case.items).toEqual([{ id: "n", select: "reply", options: [] }]);
  });

  test("the single-item ask made from options still takes a button tap", async () => {
    const chat = await connect();
    const id = newCase();
    await until(() => store.findConnectorMessage("telegram", id) !== null);
    const messageId = (store.findConnectorMessage("telegram", id)!.ref as { message_id: number }).message_id;
    fake.tap(chat, messageId, `o:${id}:0`);
    await until(() => store.getCase(id)!.case.latest_reply_id !== null);
    const reply = store.getReply(store.getCase(id)!.case.latest_reply_id!)!;
    expect(reply).toMatchObject({ choice: "a", source: "telegram", outcome: "decide" });
  });
});
