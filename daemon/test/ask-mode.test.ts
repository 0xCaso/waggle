import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { DEFAULT_ASK_PREFERENCES, askAgentText, askPreferencesText, reachModeNote } from "../src/guide/asks";
import { NOT_SET_UP_TEXT, OFF_ASK_TEXT, isSetUp } from "../src/mcp/shim";
import { AskReach } from "../src/protocol/rpc";
import pkg from "../package.json" with { type: "json" };
import { rmrf, tmpHome } from "./helpers";

// HAIL-193: the Off level, the "mode changed" note, and a Mac with no finished Waggle setup.

const question = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact" },
    { id: "b", label: "Detailed" },
  ],
};

const homes: string[] = [];
const servers: RpcServer[] = [];
const clients: { client: Client; transport: StdioClientTransport }[] = [];

afterEach(async () => {
  for (const c of clients.splice(0)) {
    await c.transport.close().catch(() => {});
    await c.client.close().catch(() => {});
  }
  for (const s of servers.splice(0)) s.stop();
  for (const h of homes.splice(0)) rmrf(h);
});

function setup(opts: { setUp?: boolean } = {}) {
  const home = tmpHome(opts);
  homes.push(home);
  const cwd = join(home, "work");
  mkdirSync(cwd, { recursive: true });
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  servers.push(startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: pkg.version }));
  return { home, cwd, store };
}

async function startShim(home: string, cwd: string) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(import.meta.dir, "..", "src", "index.ts"), "mcp"],
    env: { KNOCK_HOME: home, CLAUDE_CODE_SESSION_ID: "sess-mode", KNOCK_ASK_WAIT_MS: "300" },
    cwd,
    stderr: "pipe",
  });
  const client = new Client({ name: "knock-test", version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);
  clients.push({ client, transport });
  return client;
}

type ToolResult = Awaited<ReturnType<Client["callTool"]>>;
function textOf(result: ToolResult): string {
  if (!("content" in result)) return "";
  return (result.content as { type: string; text?: string }[]).map((c) => c.text ?? "").join("\n");
}

describe("Off level", () => {
  test("the level exists, and its text tells agents to ask in the terminal", () => {
    expect(AskReach.safeParse("off").success).toBe(true);
    const text = askAgentText({ ...DEFAULT_ASK_PREFERENCES, reach: "off" });
    expect(text).toContain("Do not call waggle_ask");
    expect(text).toContain("terminal");
    expect(text).not.toContain("ASD-STE100");
    expect(askPreferencesText({ ...DEFAULT_ASK_PREFERENCES, reach: "off" })).not.toContain("Keep working");
  });

  test("waggle_ask with Off creates no case and says to ask in the terminal", async () => {
    const { home, cwd, store } = setup();
    store.setAskReach("off");
    const client = await startShim(home, cwd);
    expect(client.getInstructions()).toContain("Waggle is Off");

    const result = await client.callTool({ name: "waggle_ask", arguments: question });
    expect(result.isError).toBeFalsy();
    expect(textOf(result)).toBe(OFF_ASK_TEXT);
    expect(store.listCases("needs_you")).toHaveLength(0);
  });
});

describe("mode changed note", () => {
  test("a running session gets one note on its next call after the level changes", async () => {
    const { home, cwd, store } = setup();
    const client = await startShim(home, cwd);

    const quiet = await client.callTool({ name: "waggle_guide", arguments: {} });
    expect(textOf(quiet)).not.toContain("Waggle mode changed");

    store.setAskReach("visual");
    const first = await client.callTool({ name: "waggle_guide", arguments: {} });
    expect(textOf(first)).toContain(reachModeNote("visual"));
    expect(reachModeNote("visual")).toStartWith("Waggle mode changed: Things to look at. ");

    const second = await client.callTool({ name: "waggle_guide", arguments: {} });
    expect(textOf(second)).not.toContain("Waggle mode changed");

    store.setAskReach("off");
    const ask = await client.callTool({ name: "waggle_ask", arguments: question });
    expect(textOf(ask)).toContain(OFF_ASK_TEXT);
    expect(textOf(ask)).toContain(reachModeNote("off"));
  });

  test("a new session gets today's level in its instructions, with no note", async () => {
    const { home, cwd, store } = setup();
    store.setAskReach("written");
    const client = await startShim(home, cwd);
    expect(client.getInstructions()).toContain("Bring me asks with something to look at or to read");
    const result = await client.callTool({ name: "waggle_guide", arguments: {} });
    expect(textOf(result)).not.toContain("Waggle mode changed");
  });

  test("every level has a note", () => {
    for (const level of AskReach.options) expect(reachModeNote(level)).toStartWith("Waggle mode changed: ");
  });
});

describe("shared setups stay opt-in", () => {
  test("no onboarded marker: not set up", () => {
    const home = tmpHome({ setUp: false });
    homes.push(home);
    expect(isSetUp(home)).toBe(false);
    expect(isSetUp(tmpHome())).toBe(true);
  });

  test("a Mac with no finished setup gets one plain reply, no error, and no daemon is started", async () => {
    const home = tmpHome({ setUp: false });
    homes.push(home);
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });
    const client = await startShim(home, cwd);
    expect(client.getInstructions()).toBe(NOT_SET_UP_TEXT);

    for (const name of ["waggle_ask", "waggle_check", "waggle_guide"]) {
      const result = await client.callTool({ name, arguments: name === "waggle_check" ? { case_id: "c_x" } : question });
      expect(result.isError).toBeFalsy();
      expect(textOf(result)).toBe(NOT_SET_UP_TEXT);
    }
    expect((await client.listTools()).tools.length).toBeGreaterThan(0);
    expect(existsSync(join(home, "knock.sock"))).toBe(false);
    expect(existsSync(join(home, "knock.db"))).toBe(false);
  });
});
