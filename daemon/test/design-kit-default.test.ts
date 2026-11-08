import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { EventBus } from "../src/events";
import { DESIGN_KIT_CUT_NOTE, DESIGN_KIT_MAX_BYTES, defaultKitMarkdown, withDesignKit } from "../src/guide/design-kit";
import { DESIGN_SYSTEM_MAX_BYTES } from "../src/protocol/design-kit";
import { DesignKitSetParams, EMPTY_DESIGN_KIT, KnockSettingsParams, MCP_TOOLS } from "../src/protocol";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { rmrf, rpcConnect, tmpHome } from "./helpers";
import pkg from "../package.json" with { type: "json" };

// HAIL-166: the default design kit (design_kit.* RPCs), the guide that carries it, and waggle_settings.

const homes: string[] = [];
const servers: RpcServer[] = [];
const transports: StdioClientTransport[] = [];

afterEach(async () => {
  for (const t of transports.splice(0)) await t.close().catch(() => {});
  for (const s of servers.splice(0)) s.stop();
  for (const h of homes.splice(0)) rmrf(h);
});

function setup() {
  const home = tmpHome();
  homes.push(home);
  const cwd = join(home, "work");
  mkdirSync(cwd, { recursive: true });
  const bus = new EventBus();
  const store = new Store(new Database(join(home, "knock.db")), home, bus);
  const socketPath = join(home, "knock.sock");
  servers.push(startRpcServer({ socketPath, store, bus, version: pkg.version }));
  return { home, cwd, store, socketPath };
}

async function startShim(home: string, cwd: string, sessionId = "sess-kit"): Promise<Client> {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(import.meta.dir, "..", "src", "index.ts"), "mcp"],
    env: { KNOCK_HOME: home, CLAUDE_CODE_SESSION_ID: sessionId },
    cwd,
    stderr: "pipe",
  });
  const client = new Client({ name: "knock-test", version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);
  transports.push(transport);
  return client;
}

function textOf(result: Awaited<ReturnType<Client["callTool"]>>): string {
  if (!("content" in result)) return "";
  return (result.content as { type: string; text?: string }[]).map((c) => c.text ?? "").join("\n");
}

describe("default kit storage", () => {
  test("starts off and empty; set records who, undo restores the previous kit", () => {
    const { store } = setup();
    expect(store.getDesignKit()).toEqual(EMPTY_DESIGN_KIT);
    expect(store.canUndoDesignKit()).toBe(false);

    store.setDesignKit({ design_system: "Mine", tone: "Warm" }, "you");
    const agent = store.setDesignKit({ design_system: "Agent text", enabled: true }, "claude:s1");
    expect(agent.updated_by).toBe("claude:s1");
    expect(agent.enabled).toBe(true);
    expect(store.canUndoDesignKit()).toBe(true);

    const restored = store.undoDesignKit()!;
    expect(restored.design_system).toBe("Mine");
    expect(restored.enabled).toBe(false);
    expect(restored.tone).toBe("Warm");
    expect(restored.updated_by).toBe("you");
    expect(store.canUndoDesignKit()).toBe(false);
    expect(store.undoDesignKit()).toBeNull();
  });

  test("a set that changes nothing keeps the previous version", () => {
    const { store } = setup();
    store.setDesignKit({ tone: "A" }, "you");
    store.setDesignKit({ tone: "B" }, "claude:s1");
    store.setDesignKit({ tone: "B" }, "you");
    expect(store.getDesignKit().updated_by).toBe("claude:s1");
    expect(store.undoDesignKit()!.tone).toBe("A");
  });
});

describe("design_kit RPCs", () => {
  test("get, set, undo round trip over the socket", async () => {
    const { socketPath } = setup();
    const client = await rpcConnect(socketPath);
    const first = await client.request("design_kit.get", {});
    expect(first.result).toEqual({ kit: EMPTY_DESIGN_KIT, can_undo: false });

    const set = await client.request("design_kit.set", { design_system: "# DS", pen_file: "/a/b.pen" });
    const kit = (set.result as { kit: { updated_by: string; design_system: string }; can_undo: boolean });
    expect(kit.kit.updated_by).toBe("you");
    expect(kit.kit.design_system).toBe("# DS");

    const agent = await client.request("design_kit.set", { tone: "Plain", updated_by: "claude:abc" });
    expect((agent.result as { kit: { updated_by: string } }).kit.updated_by).toBe("claude:abc");
    const undone = await client.request("design_kit.undo", {});
    expect((undone.result as { kit: { tone: string; updated_by: string } }).kit).toMatchObject({ tone: "", updated_by: "you" });
    expect((await client.request("design_kit.undo", {})).error).toBeDefined();
    client.close();
  });

  test("validation: size, path, empty change, unknown field", async () => {
    const big = "x".repeat(DESIGN_SYSTEM_MAX_BYTES + 1);
    const over = DesignKitSetParams.safeParse({ design_system: big });
    expect(over.success).toBe(false);
    expect(JSON.stringify(over.error?.issues)).toContain("design_system is 1048577 bytes; the maximum is 1048576");
    expect(DesignKitSetParams.safeParse({ design_system: "x".repeat(DESIGN_SYSTEM_MAX_BYTES) }).success).toBe(true);
    expect(DesignKitSetParams.safeParse({ pen_file: "relative/x.pen" }).success).toBe(false);
    expect(DesignKitSetParams.safeParse({ pen_file: "" }).success).toBe(true);
    expect(DesignKitSetParams.safeParse({}).success).toBe(false);
    expect(DesignKitSetParams.safeParse({ updated_by: "x" }).success).toBe(false);
    expect(DesignKitSetParams.safeParse({ brand: "x" }).success).toBe(false);
  });
});

describe("guide: none, default only, project only, both", () => {
  const dflt = defaultKitMarkdown({ design_system: "DEFAULT DS", pen_file: "/d.pen", tone: "Calm" });

  test("default kit uses the project kit's markdown shape; empty fields are skipped", () => {
    expect(dflt).toBe("# Design kit\n\n## Design system\nDEFAULT DS\n\n## Pen file\n/d.pen\n\n## Tone of copy\nCalm");
    expect(defaultKitMarkdown({ design_system: " ", pen_file: "", tone: "Calm" })).toBe("# Design kit\n\n## Tone of copy\nCalm");
    expect(defaultKitMarkdown({ design_system: "", pen_file: "", tone: "" })).toBeNull();
  });

  test("agents get the first 8 KB, cut at a line break, then the note", () => {
    const lines = Array.from({ length: 2000 }, (_, i) => `line ${i} of the design system`);
    const md = defaultKitMarkdown({ design_system: lines.join("\n"), pen_file: "/d.pen", tone: "Calm" })!;
    const ds = md.split("## Design system\n")[1]!.split("\n\n## Pen file")[0]!;
    expect(ds.endsWith(`\n${DESIGN_KIT_CUT_NOTE}`)).toBe(true);
    const body = ds.slice(0, -(DESIGN_KIT_CUT_NOTE.length + 1));
    expect(new TextEncoder().encode(body).length).toBeLessThanOrEqual(DESIGN_KIT_MAX_BYTES);
    expect(lines.join("\n").startsWith(body + "\n")).toBe(true);
    expect(md).toContain("## Pen file\n/d.pen");
    expect(md).toContain("## Tone of copy\nCalm");
    // Multi-byte text is cut on a character edge; text at or under 8 KB has no note.
    const wide = defaultKitMarkdown({ design_system: "é".repeat(8000), pen_file: "", tone: "" })!;
    expect(wide).not.toContain("\uFFFD");
    expect(wide).toContain(DESIGN_KIT_CUT_NOTE);
    expect(defaultKitMarkdown({ design_system: "x".repeat(DESIGN_KIT_MAX_BYTES), pen_file: "", tone: "" })).not.toContain(DESIGN_KIT_CUT_NOTE);
  });

  test("none: unchanged", () => {
    expect(withDesignKit("artifacts", "T", null, null)).toBe("T");
    expect(withDesignKit(undefined, "I", null, null)).toBe("I");
  });

  test("default only: artifacts topic and index carry it", () => {
    const art = withDesignKit("artifacts", "T", null, dflt);
    expect(art).toContain("## Default design kit");
    expect(art).toContain("DEFAULT DS");
    expect(withDesignKit(undefined, "I", null, dflt)).toContain("default design kit");
    expect(withDesignKit("reviews", "T", null, dflt)).toBe("T");
  });

  test("project only, and both: the project kit wins", () => {
    expect(withDesignKit("artifacts", "T", "PROJECT DS", null)).toContain("PROJECT DS");
    const both = withDesignKit("artifacts", "T", "PROJECT DS", dflt);
    expect(both).toContain("PROJECT DS");
    expect(both).not.toContain("DEFAULT DS");
    expect(withDesignKit(undefined, "I", "PROJECT DS", dflt)).toContain(".knock/design-kit.md");
  });
});

describe("waggle_settings", () => {
  test("is listed and its schema validates the fields", () => {
    const tool = MCP_TOOLS.find((t) => t.name === "waggle_settings")!;
    expect(tool.description).toContain("Confirm with the person in Waggle");
    expect(KnockSettingsParams.safeParse({ action: "set", artifact_preset: "custom" }).success).toBe(false);
    expect(KnockSettingsParams.safeParse({ action: "set", artifact_preset: "rich" }).success).toBe(true);
  });

  test("get and set round trip through the shim, updated_by recorded, guide follows", async () => {
    const { home, cwd, store } = setup();
    const client = await startShim(home, cwd);

    const got = textOf(await client.callTool({ name: "waggle_settings", arguments: { action: "get" } }));
    expect(got).toContain("design_kit.enabled: false");
    expect(got).toContain("artifact_preset: visual");

    const set = textOf(
      await client.callTool({
        name: "waggle_settings",
        arguments: { action: "set", design_system: "Agent DS", tone: "Plain", enabled: true, artifact_preset: "rich" },
      }),
    );
    expect(set).toContain("Waggle settings updated.");
    expect(set).toContain("Agent DS");
    expect(set).toContain("artifact_preset: rich");
    expect(store.getDesignKit().updated_by).toBe("claude:sess-kit");
    expect(store.getArtifactPreset()).toBe("rich");
    expect(store.canUndoDesignKit()).toBe(true);

    // The default kit now rides on the artifacts guide, and a project kit replaces it.
    const guide = textOf(await client.callTool({ name: "waggle_guide", arguments: { topic: "artifacts" } }));
    expect(guide).toContain("## Default design kit");
    expect(guide).toContain("Agent DS");
    mkdirSync(join(cwd, ".knock"));
    writeFileSync(join(cwd, ".knock", "design-kit.md"), "PROJECT KIT");
    const both = textOf(await client.callTool({ name: "waggle_guide", arguments: { topic: "artifacts" } }));
    expect(both).toContain("PROJECT KIT");
    expect(both).not.toContain("Agent DS");
  });

  test("a long design system is stored whole, get returns it all, the guide cuts it", async () => {
    const { home, cwd, store } = setup();
    const client = await startShim(home, cwd);
    const text = Array.from({ length: 20000 }, (_, i) => `row ${i}`).join("\n");
    expect(text.length).toBeGreaterThan(100 * 1024);
    await client.callTool({ name: "waggle_settings", arguments: { action: "set", design_system: text, enabled: true } });
    expect(store.getDesignKit().design_system).toBe(text);
    const got = textOf(await client.callTool({ name: "waggle_settings", arguments: { action: "get" } }));
    expect(got).toContain(text);
    const guide = textOf(await client.callTool({ name: "waggle_guide", arguments: { topic: "artifacts" } }));
    expect(guide).toContain(DESIGN_KIT_CUT_NOTE);
    expect(guide).not.toContain("row 19999");
  });

  test("errors say what to fix and write nothing", async () => {
    const { home, cwd, store } = setup();
    const client = await startShim(home, cwd);

    const badPreset = await client.callTool({
      name: "waggle_settings",
      arguments: { action: "set", tone: "Plain", artifact_preset: "custom" },
    });
    expect(badPreset.isError).toBe(true);
    expect(textOf(badPreset)).toContain("artifact_preset");
    expect(store.getDesignKit().tone).toBe("");

    const tooBig = await client.callTool({
      name: "waggle_settings",
      arguments: { action: "set", design_system: "x".repeat(DESIGN_SYSTEM_MAX_BYTES + 1) },
    });
    expect(tooBig.isError).toBe(true);
    expect(textOf(tooBig)).toContain("design_system is 1048577 bytes; the maximum is 1048576");

    const empty = await client.callTool({ name: "waggle_settings", arguments: { action: "set" } });
    expect(empty.isError).toBe(true);
    expect(textOf(empty)).toContain("Send at least one of");
  });
});
