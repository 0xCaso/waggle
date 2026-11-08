import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { ConnectorManager } from "../src/connectors/manager";
import { MemorySecretStore } from "../src/connectors/secrets";
import { SlackConnector } from "../src/connectors/slack";
import { TelegramConnector } from "../src/connectors/telegram";
import { EventBus } from "../src/events";
import { startRpcServer, type RpcServer } from "../src/server";
import { Store } from "../src/store";
import { FakeTelegram, until } from "./fake-telegram";
import { rmrf, rpcConnect, tmpHome, type RpcClient } from "./helpers";

// HAIL-144: the connectors.* socket methods, and the reply source on reply.submit.

let home: string;
let fake: FakeTelegram;
let server: RpcServer;
let manager: ConnectorManager;
let store: Store;
let client: RpcClient;

beforeAll(async () => {
  home = tmpHome();
  fake = new FakeTelegram();
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  store = new Store(db, home, bus);
  manager = new ConnectorManager(store, bus, [], () => {});
  manager.add(
    new TelegramConnector({
      store,
      secrets: new MemorySecretStore(),
      host: manager,
      baseUrl: fake.baseUrl,
      pollTimeoutS: 1,
      idleDelayMs: 5,
      log: () => {},
    }),
  );
  // connectors.status reports Slack too (HAIL-145), so the daemon always has both.
  manager.add(new SlackConnector({ store, secrets: new MemorySecretStore(), host: manager, log: () => {} }));
  manager.start();
  server = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0", connectors: manager });
  client = await rpcConnect(join(home, "knock.sock"));
});

afterAll(() => {
  client.close();
  server.stop();
  manager.stop();
  fake.stop();
  rmrf(home);
});

describe("connectors.* over the socket", () => {
  test("starts off", async () => {
    const res = await client.request("connectors.status", {});
    expect((res.result as { telegram: { state: string } }).telegram.state).toBe("off");
  });

  test("a bad token answers with plain words", async () => {
    const res = await client.request("connectors.telegram.check_token", { token: "000000:wrong-token" });
    expect(res.error?.code).toBe(-32010);
    expect(res.error?.message).toContain("did not accept that token");
  });

  test("the full connect flow, and the result never holds the token", async () => {
    const checked = await client.request("connectors.telegram.check_token", { token: fake.validToken });
    expect(JSON.stringify(checked.result)).not.toContain("TEST-token");
    expect(checked.result).toMatchObject({ state: "token_checked", bot_name: "Waggle Test Bot" });

    const pairing = await client.request("connectors.telegram.start_pairing", {});
    const code = (pairing.result as { code: string }).code;
    expect(pairing.result).toMatchObject({ state: "waiting_for_start" });
    fake.sendText(42, `/start ${code}`);
    await until(() => store.getConnectorSetting("telegram", { safeParse: (v: unknown) => ({ success: true, data: v }) }) !== null && manager.get("telegram")!.isActive());

    const status = await client.request("connectors.status", {});
    expect((status.result as { telegram: unknown }).telegram).toMatchObject({ state: "connected", chat_label: "Sam" });

    const test = await client.request("connectors.telegram.send_test", {});
    expect(test.result).toEqual({ ok: true });

    const gone = await client.request("connectors.telegram.disconnect", {});
    expect(gone.result).toMatchObject({ state: "off", bot_name: null });
  });

  test("reply.submit without a source is a Mac reply", async () => {
    const task = store.createTask({ name: "t", project: "p" });
    const c = store.createCase(task.id, {
      kind: "question",
      title: "T",
      need: "N",
      why: "W",
      recommendation: "a",
      recommendation_why: "R",
      options: [{ id: "a", label: "A" }],
    });
    const res = await client.request("reply.submit", {
      case_id: c.id,
      idempotency_key: "mac-key",
      choice: "a",
      comments: [],
      captures: [],
    });
    expect((res.result as { source: string }).source).toBe("mac");
    expect(store.getCase(c.id)!.case.latest_reply_source).toBe("mac");
  });
});
