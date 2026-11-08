import { afterAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { rmSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConnectorManager } from "../src/connectors/manager";
import { connectorConfig, IS_DEV_BUILD } from "../src/connectors/overrides";
import { MemorySecretStore } from "../src/connectors/secrets";
import { isAppToken, isBotToken, SlackConnector, SlackError, wrongFieldMessage, type SlackSocket } from "../src/connectors/slack";
import { TelegramConnector, telegramTokenProblem } from "../src/connectors/telegram";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { FakeSlack } from "./fake-slack";
import { FakeTelegram } from "./fake-telegram";

// HAIL-148: the guided connect flow. Overrides, token shapes, wrong-field handling, error words,
// and the ids the Settings deep links need.

const ENV = {
  KNOCK_TELEGRAM_BASE_URL: "http://127.0.0.1:9",
  KNOCK_SLACK_BASE_URL: "http://127.0.0.1:8",
  KNOCK_SLACK_SOCKET_URL: "ws://127.0.0.1:7/link",
  KNOCK_SECRET_STORE: "memory",
} as NodeJS.ProcessEnv;

describe("connector overrides", () => {
  test("a release build ignores every fake-service variable", () => {
    const c = connectorConfig(ENV, false);
    expect(c.telegramBaseUrl).toBe("https://api.telegram.org");
    expect(c.slackBaseUrl).toBe("https://slack.com");
    expect(c.slackSocketUrl).toBeUndefined();
    expect(c.secrets).not.toBeInstanceOf(MemorySecretStore);
  });

  test("a dev build honours them", () => {
    const c = connectorConfig(ENV, true);
    expect(c.telegramBaseUrl).toBe("http://127.0.0.1:9");
    expect(c.slackBaseUrl).toBe("http://127.0.0.1:8");
    expect(c.slackSocketUrl).toBe("ws://127.0.0.1:7/link");
    expect(c.secrets).toBeInstanceOf(MemorySecretStore);
  });

  test("running from source counts as a release build", () => {
    expect(IS_DEV_BUILD).toBe(false);
  });

  describe("compiled binaries", () => {
    const dir = mkdtempSync(join(tmpdir(), "knock-ovr-"));
    afterAll(() => rmSync(dir, { recursive: true, force: true }));
    const build = (name: string, define: boolean): string => {
      const out = join(dir, name);
      const args = ["bun", "build", "test/fixtures/print-connector-config.ts", "--compile", "--outfile", out];
      if (define) args.push("--define", "KNOCK_DEV_BUILD=true");
      const r = Bun.spawnSync(args, { cwd: join(import.meta.dir, ".."), stdout: "pipe", stderr: "pipe" });
      expect(r.exitCode).toBe(0);
      return out;
    };
    const run = (bin: string) =>
      JSON.parse(
        Bun.spawnSync([bin], { env: { ...(ENV as Record<string, string>), PATH: process.env.PATH ?? "" }, stdout: "pipe" }).stdout.toString(),
      ) as { telegramBaseUrl: string; slackBaseUrl: string; slackSocketUrl: string | null; memoryStore: boolean };

    test("the release binary ignores the env, the dev binary reads it", () => {
      const release = run(build("release", false));
      expect(release).toEqual({
        telegramBaseUrl: "https://api.telegram.org",
        slackBaseUrl: "https://slack.com",
        slackSocketUrl: null,
        memoryStore: false,
      });
      const dev = run(build("dev", true));
      expect(dev.telegramBaseUrl).toBe("http://127.0.0.1:9");
      expect(dev.slackSocketUrl).toBe("ws://127.0.0.1:7/link");
      expect(dev.memoryStore).toBe(true);
    }, 60_000);
  });

  test("package.json: build is the dev build, build:release and release.sh leave the flag out", async () => {
    const pkg = (await Bun.file(join(import.meta.dir, "../package.json")).json()) as { scripts: Record<string, string> };
    expect(pkg.scripts.build).toContain("KNOCK_DEV_BUILD=true");
    expect(pkg.scripts["build:release"]).not.toContain("KNOCK_DEV_BUILD");
    const release = await Bun.file(join(import.meta.dir, "../../scripts/release.sh")).text();
    expect(release).toContain("bun run build:release");
    expect(release).not.toMatch(/bun run build$/m);
  });
});

describe("token shape", () => {
  test("Telegram tokens", () => {
    expect(telegramTokenProblem("123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw")).toBeNull();
    expect(telegramTokenProblem("abc")).toContain("does not look like a bot token");
    expect(telegramTokenProblem("123456789")).toContain("does not look like a bot token");
    expect(telegramTokenProblem("xoxb-111-222")).toContain("Slack token");
  });

  test("Slack prefixes", () => {
    expect(isAppToken("xapp-1-A")).toBe(true);
    expect(isBotToken("xoxb-1-A")).toBe(true);
    expect(isAppToken("xoxb-1")).toBe(false);
  });

  test("wrong-field messages name the field", () => {
    expect(wrongFieldMessage("xapp-1", "xoxb-1")).toBeNull();
    expect(wrongFieldMessage("xoxb-1", "xoxb-2")).toContain("Put it in the bot token box");
    expect(wrongFieldMessage("xapp-1", "xapp-2")).toContain("Put it in the app-level box");
    expect(wrongFieldMessage("nope", "xoxb-2")).toContain("starts with xapp-");
    expect(wrongFieldMessage("xapp-1", "nope")).toContain("starts with xoxb-");
  });
});

describe("Telegram guided errors", () => {
  test("a bad shape is refused before any call, a rejected token and no network read plainly", async () => {
    const fake = new FakeTelegram();
    try {
      const db = new Database(":memory:");
      const bus = new EventBus();
      const store = new Store(db, "/tmp/knock-test", bus);
      let calls = 0;
      const make = (baseUrl: string) =>
        new TelegramConnector({
          store,
          secrets: new MemorySecretStore(),
          host: new ConnectorManager(store, bus, [], () => {}),
          baseUrl,
          fetch: ((...a: Parameters<typeof fetch>) => {
            calls++;
            return fetch(...a);
          }) as typeof fetch,
          log: () => {},
        });
      const tg = make(fake.baseUrl);
      await expect(tg.checkToken("hello")).rejects.toThrow("does not look like a bot token");
      expect(calls).toBe(0);
      await expect(tg.checkToken("999:nope-nope")).rejects.toThrow("did not accept that token");
      const dead = make("http://127.0.0.1:1");
      await expect(dead.checkToken("999:nope-nope")).rejects.toThrow("Could not reach Telegram");
      // The saved setting is untouched by every failure.
      expect(tg.status().state).toBe("off");
    } finally {
      fake.stop();
    }
  });
});

describe("Slack guided flow", () => {
  function setup(fake: FakeSlack) {
    const db = new Database(":memory:");
    const bus = new EventBus();
    const store = new Store(db, "/tmp/knock-test", bus);
    const secrets = new MemorySecretStore();
    const manager = new ConnectorManager(store, bus, [], () => {});
    const slack = new SlackConnector({
      store,
      secrets,
      host: manager,
      baseUrl: fake.baseUrl,
      webSocket: (url) => new WebSocket(url) as unknown as SlackSocket,
      retryDelayMs: 20,
      reconnectDelayMs: 10,
      helloTimeoutMs: 150,
      log: () => {},
    });
    manager.add(slack);
    manager.start();
    return { slack, secrets };
  }

  test("tokens pasted in each other's box are swapped and accepted", async () => {
    const fake = new FakeSlack();
    try {
      const { slack, secrets } = setup(fake);
      const s = await slack.checkTokens(fake.validBotToken, fake.validAppToken);
      expect(s.state).toBe("token_checked");
      expect(secrets.get("slack-app-token")).toBe(fake.validAppToken);
      expect(secrets.get("slack-bot-token")).toBe(fake.validBotToken);
    } finally {
      fake.stop();
    }
  });

  test("a bot token in both boxes is refused with a message naming the field", async () => {
    const fake = new FakeSlack();
    try {
      const { slack } = setup(fake);
      const err = (await slack.checkTokens(fake.validBotToken, fake.validBotToken).catch((e: Error) => e)) as SlackError;
      expect(err).toBeInstanceOf(SlackError);
      expect(err.message).toContain("Put it in the bot token box");
      expect(fake.calls).toHaveLength(0);
    } finally {
      fake.stop();
    }
  });

  test("a good check carries the ids the Settings links need", async () => {
    const fake = new FakeSlack();
    try {
      const { slack } = setup(fake);
      const s = await slack.checkTokens(fake.validAppToken, fake.validBotToken);
      expect(s.app_id).toBe("A0KNOCK");
      expect(s.team_id).toBe("T0ACME");
      expect(s.bot_user_id).toBe("UBOT");
      // The ids survive start_pairing.
      const p = slack.startPairing();
      expect(p.app_id).toBe("A0KNOCK");
      expect(p.team_id).toBe("T0ACME");
      slack.stop();
    } finally {
      fake.stop();
    }
  });

  test("look_up_app gives the app id from the bot token alone and saves nothing", async () => {
    const fake = new FakeSlack();
    try {
      const { slack, secrets } = setup(fake);
      expect(slack.status().app_id).toBeNull();
      const s = await slack.lookUpApp(fake.validBotToken);
      expect(s.app_id).toBe("A0KNOCK");
      expect(s.state).toBe("off");
      expect(secrets.get("slack-bot-token")).toBeNull();
      await expect(slack.lookUpApp("xapp-1-x")).rejects.toThrow("Put it in the app-level box");
      await expect(slack.lookUpApp("xoxb-wrong-wrong")).rejects.toThrow("did not accept that token");
    } finally {
      fake.stop();
    }
  });

  test("an unreachable Slack reads plainly", async () => {
    const fake = new FakeSlack();
    const { slack } = setup(fake);
    fake.stop();
    await expect(slack.checkTokens(fake.validAppToken, fake.validBotToken)).rejects.toThrow("Could not reach Slack");
  });
});
