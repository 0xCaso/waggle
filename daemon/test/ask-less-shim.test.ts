import { afterEach, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { EventBus } from "../src/events";
import { startRpcServer, type RpcServer } from "../src/server";
import { Store } from "../src/store";
import pkg from "../package.json" with { type: "json" };
import { rmrf, tmpHome } from "./helpers";

// WAG-412: waggle_ask returns at once with status auto_decided when the operator's rule decided the ask.

let cleanup: Array<() => Promise<void> | void> = [];
afterEach(async () => {
  for (const fn of cleanup.splice(0).reverse()) {
    try {
      await fn();
    } catch {
      // Already closed.
    }
  }
});

async function run(askLess: boolean, category: string) {
  const home = tmpHome();
  cleanup.push(() => rmrf(home));
  const cwd = join(home, "work");
  mkdirSync(cwd, { recursive: true });
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  if (askLess) store.setAskLess({ enabled: true, rules: { naming: true, wording: false, formatting: false, tests: false } });
  const server: RpcServer = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: pkg.version });
  cleanup.push(() => server.stop());
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(import.meta.dir, "..", "src", "index.ts"), "mcp"],
    env: { KNOCK_HOME: home, CLAUDE_CODE_SESSION_ID: "sess-less", KNOCK_ASK_WAIT_MS: "300" },
    cwd,
    stderr: "pipe",
  });
  const client = new Client({ name: "knock-test", version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);
  cleanup.push(() => client.close());
  cleanup.push(() => transport.close());
  const started = Date.now();
  const result = await client.callTool({
    name: "waggle_ask",
    arguments: {
      title: "Name the helper",
      need: "What do we call the helper?",
      why: "Two names fit.",
      recommendation: "a",
      recommendation_why: "It is shorter.",
      options: [
        { id: "a", label: "Call it parseRow", title: "parseRow" },
        { id: "b", label: "Call it readRow", title: "readRow" },
      ],
      category,
    },
  });
  const text = (result.content as { type: string; text?: string }[]).map((c) => c.text ?? "").join("\n");
  return { text, elapsed: Date.now() - started, store };
}

test("a decided ask returns status auto_decided at once", async () => {
  const { text, store } = await run(true, "naming");
  const body = JSON.parse(text.split("\n").pop()!) as Record<string, string>;
  expect(body).toMatchObject({ status: "auto_decided", decided_by: "rule", category: "naming", answer: "parseRow" });
  expect(body.next).toContain("Do not wait");
  expect(store.listCases("needs_you")).toHaveLength(0);
}, 20000);

test("with the master off the same ask waits like any ask", async () => {
  const { text, store } = await run(false, "naming");
  expect(text).toContain("pending");
  expect(text).not.toContain("auto_decided");
  expect(store.listCases("needs_you")).toHaveLength(1);
}, 20000);
