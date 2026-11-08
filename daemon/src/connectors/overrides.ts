import { RELAY_BASE_URL } from "./relay";
import { defaultSecretStore, MemorySecretStore, type SecretStore } from "./secrets";
import { SLACK_BASE_URL } from "./slack";
import { TELEGRAM_BASE_URL } from "./telegram";

// Test hooks for a built daemon (HAIL-148). Evidence runs of a built app need a fake Telegram, a
// fake Slack, a fake relay (WAG-387) and an in-memory secret store. The RELEASE daemon must never read them: an
// environment variable must not be able to point the daemon at another host.
//
// The switch is a build-time constant. `bun run build` defines KNOCK_DEV_BUILD as true (the dev
// binary). `bun run build:release` (used by scripts/release.sh) does not define it, so the
// constant below is false and the env variables are ignored. Running from source, as the unit tests
// do, is also "not dev". Unit tests inject fakes in code and call connectorConfig() with
// `devBuild` set to say which build they mean.
declare const KNOCK_DEV_BUILD: boolean | undefined;

export const IS_DEV_BUILD: boolean = typeof KNOCK_DEV_BUILD !== "undefined" && KNOCK_DEV_BUILD === true;

export interface ConnectorConfig {
  telegramBaseUrl: string;
  slackBaseUrl: string;
  // The one relay host for sharing a case (WAG-387). Dev builds only may replace it.
  relayBaseUrl: string;
  // Replaces the wss address that apps.connections.open returns. Dev builds only.
  slackSocketUrl?: string;
  secrets: SecretStore;
}

export function connectorConfig(
  env: NodeJS.ProcessEnv = process.env,
  devBuild: boolean = IS_DEV_BUILD,
): ConnectorConfig {
  if (!devBuild) {
    return { telegramBaseUrl: TELEGRAM_BASE_URL, slackBaseUrl: SLACK_BASE_URL, relayBaseUrl: RELAY_BASE_URL, secrets: defaultSecretStore({}) };
  }
  const socketUrl = env.KNOCK_SLACK_SOCKET_URL?.trim();
  return {
    telegramBaseUrl: env.KNOCK_TELEGRAM_BASE_URL?.trim() || TELEGRAM_BASE_URL,
    slackBaseUrl: env.KNOCK_SLACK_BASE_URL?.trim() || SLACK_BASE_URL,
    relayBaseUrl: env.KNOCK_RELAY_BASE_URL?.trim() || RELAY_BASE_URL,
    ...(socketUrl ? { slackSocketUrl: socketUrl } : {}),
    secrets: env.KNOCK_SECRET_STORE === "memory" ? new MemorySecretStore() : defaultSecretStore({}),
  };
}
