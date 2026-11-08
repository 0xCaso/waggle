#!/usr/bin/env bun
// Keeps an old `waggle mcp` shim alive across an update (HAIL-27). Spawns the
// shim binary given as the first argument, sends one blocking ask (knock_ask by default: the shim under test is the old build; SHIM_ASK_TOOL overrides) so the
// shim holds its case.wait open, then stays up so update-e2e.sh can assert the
// daemon the shim reconnects to is the new one from the installed path.
//
// The environment is passed through: update-e2e.sh sets KNOCK_HOME to the temp
// data root, HOME to a temp dir whose Applications/Knock.app/.../knock is a
// symlink to the installed app's binary, and KNOCK_ASK_WAIT_MS long enough to
// outlive the update.
// Load the SDK from the daemon's installed node_modules, not by bare name:
// this file has no node_modules beside it, so Bun would auto-install the
// newest SDK into its global cache, and 1.31.0 there fails on `zod/v3`.
const sdk = new URL("../../daemon/node_modules/@modelcontextprotocol/sdk/dist/esm/client/", import.meta.url);
const { Client } = await import(new URL("index.js", sdk).href);
const { StdioClientTransport } = await import(new URL("stdio.js", sdk).href);

const shimBin = process.argv[2];
if (!shimBin) {
  process.stderr.write("usage: shim-ask.mjs <shim-binary>\n");
  process.exit(2);
}

const transport = new StdioClientTransport({
  command: shimBin,
  args: ["mcp"],
  env: process.env,
});
const client = new Client({ name: "update-e2e", version: "0.0.0" }, { capabilities: {} });
await client.connect(transport);
process.stdout.write("shim-ask: connected\n");

// Blocking: the shim creates one case and waits in case.wait until a reply or
// the KNOCK_ASK_WAIT_MS timeout. While it waits, the shim holds its daemon
// connection open, so when the app restarts the daemon after the update the
// shim reconnects (and, with HAIL-27, starts the new binary from the stable
// path). The MCP request timeout must outlast the whole update; the SDK default
// is 60s, which would kill the shim mid-update.
try {
  await client.callTool(
    {
      name: process.env.SHIM_ASK_TOOL || "knock_ask",
      arguments: {
        kind: "question",
        title: "Update shim keepalive",
        need: "Keep this session open across the update.",
        why: "The e2e test keeps an old shim alive through Sparkle.",
        recommendation: "a",
        recommendation_why: "It is the only option.",
        options: [{ id: "a", label: "OK" }],
      },
    },
    undefined,
    { timeout: 900_000 },
  );
  process.stdout.write("shim-ask: ask returned\n");
} catch (err) {
  process.stdout.write(`shim-ask: ask errored: ${err?.message ?? String(err)}\n`);
}

// Hold the transport open so the shim stays alive until the test kills this
// process.
await new Promise(() => {});
