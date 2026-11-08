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
import { FakeSlack, } from "./fake-slack";
import { until } from "./fake-telegram";
import { rmrf, rpcConnect, tmpHome, type RpcClient } from "./helpers";

// HAIL-145: the connectors.slack.* socket methods.

let home: string;
let fake: FakeSlack;
let server: RpcServer;
let manager: ConnectorManager;
let client: RpcClient;

beforeAll(async () => {
  home = tmpHome();
  fake = new FakeSlack();
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  manager = new ConnectorManager(store, bus, [], () => {});
  const secrets = new MemorySecretStore();
  manager.add(new TelegramConnector({ store, secrets, host: manager, log: () => {} }));
  manager.add(
    new SlackConnector({
      store,
      secrets,
      host: manager,
      baseUrl: fake.baseUrl,
      retryDelayMs: 20,
      reconnectDelayMs: 10,
      log: () => {},
    }),
  );
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

describe("connectors.slack.* over the socket", () => {
  test("starts off, with the manifest to copy", async () => {
    const res = await client.request("connectors.status", {});
    const slack = (res.result as { slack: { state: string; manifest: string } }).slack;
    expect(slack.state).toBe("off");
    expect(JSON.parse(slack.manifest).settings.socket_mode_enabled).toBe(true);
  });

  test("a bad token answers with plain words", async () => {
    const res = await client.request("connectors.slack.check_tokens", {
      app_token: fake.validAppToken,
      bot_token: "xoxb-0000-wrong-token",
    });
    expect(res.error?.code).toBe(-32010);
    expect(res.error?.message).toContain("Slack did not accept that token");
  });

  test("the full connect flow, and no result holds a token", async () => {
    const checked = await client.request("connectors.slack.check_tokens", {
      app_token: fake.validAppToken,
      bot_token: fake.validBotToken,
    });
    expect(checked.result).toMatchObject({ state: "token_checked", workspace: "Acme Inc", bot_name: "knock" });
    const paired = await client.request("connectors.slack.start_pairing", {});
    const code = (paired.result as { code: string }).code;
    expect(code).toMatch(/^[A-Z2-9]{6}$/);
    await until(() => fake.connections === 1 && fake.opened >= 2);
    fake.dm(code);
    await until(() => (manager.get("slack") as SlackConnector).status().state === "connected");
    const test = await client.request("connectors.slack.send_test", {});
    expect(test.result).toEqual({ ok: true });
    const status = await client.request("connectors.status", {});
    expect(JSON.stringify(status.result)).not.toContain("TEST-");
    const off = await client.request("connectors.slack.disconnect", {});
    expect((off.result as { state: string }).state).toBe("off");
  });
});
