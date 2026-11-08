import { connectorConfig } from "../../src/connectors/overrides";

// Prints what a compiled daemon would use for the connectors. The override test builds this twice.
const c = connectorConfig();
process.stdout.write(
  JSON.stringify({
    telegramBaseUrl: c.telegramBaseUrl,
    slackBaseUrl: c.slackBaseUrl,
    slackSocketUrl: c.slackSocketUrl ?? null,
    memoryStore: c.secrets.constructor.name === "MemorySecretStore",
  }),
);
