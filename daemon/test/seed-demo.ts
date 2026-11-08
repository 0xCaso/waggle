// seed-demo.ts — creates demo asks through the real `waggle mcp` shim, for manual evidence runs.
// Usage: KNOCK_HOME=<dir> bun test/seed-demo.ts   (a daemon must be running on KNOCK_HOME)
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { mkdtempSync, writeFileSync, cpSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
);
async function ask(session: string, cwd: string, input: Record<string, unknown>) {
  const transport = new StdioClientTransport({
    command: "bun",
    args: [join(import.meta.dir, "..", "src", "index.ts"), "mcp"],
    env: { ...process.env, CLAUDE_CODE_SESSION_ID: session, KNOCK_ASK_WAIT_MS: "300" } as Record<string, string>,
    cwd,
  });
  const client = new Client({ name: "seed", version: "0" });
  await client.connect(transport);
  const r = await client.callTool({ name: "waggle_ask", arguments: input });
  console.log(session, JSON.stringify(r).slice(0, 120));
  return client; // keep the session live
}
const base = mkdtempSync(join(tmpdir(), "knock-seed-"));
const mk = (name: string) => { const d = join(base, name); cpSync(join(import.meta.dir, "fixtures", "checkout-proto"), join(d, "proto"), { recursive: true }); writeFileSync(join(d, "shot.png"), png); return d; };
const clients = [
  await ask("s-card", mk("weekend-league"), { kind: "question", title: "Rarity weights for the first pack",
    need: "Pick the rarity split for pack 1.", why: "It changes how rare legendaries feel; a product call.",
    recommendation: "a", recommendation_why: "It matches the playtest's pull rates and keeps legendaries rare.",
    options: [{ id: "a", label: "70 / 25 / 5" }, { id: "b", label: "60 / 30 / 10" }, { id: "c", label: "80 / 15 / 5" }] }),
  await ask("s-checkout", mk("omea-web"), { kind: "review", title: "Checkout layout: compact or detailed?",
    need: "Pick A or B, or tell me what to change.", why: "Both meet the spec. This is a product call, not a technical one.",
    recommendation: "a", recommendation_why: "68% of checkouts are returning members, and speed matters more than explanation.",
    options: [{ id: "a", label: "A · Compact" }, { id: "b", label: "B · Detailed" }],
    artifact: { type: "html_bundle", dir: "./proto", entry: "index.html" } }),
  await ask("s-writ", mk("writ"), { kind: "review", title: "Freewrite mode typography pass",
    need: "Tell me if the spacing reads well.", why: "Typography is a taste call.",
    recommendation: "ship as is", recommendation_why: "The diff only touches spacing tokens.",
    artifact: { type: "screenshot", path: "./shot.png" } }),
];
console.log("seeded 3 asks; sessions stay live until Ctrl-C");
await new Promise(() => {});
void clients;
