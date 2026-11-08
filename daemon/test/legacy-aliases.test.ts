import { describe, expect, test } from "bun:test";
import {
  LEGACY_KNOCK_ALIASES,
  LEGACY_TOOL_NAMES,
  MCP_TOOLS,
  buildMcpTools,
  canonicalToolName,
} from "../src/protocol";

// HAIL-176: the knock_* tool names are aliases of the waggle_* tools, behind one switch.

const WAGGLE = ["waggle_ask", "waggle_check", "waggle_update", "waggle_guide", "waggle_settings", "waggle_themes"];

describe("tool aliases", () => {
  test("the switch is on for the transition release", () => {
    expect(LEGACY_KNOCK_ALIASES).toBe(true);
    expect(MCP_TOOLS.map((t) => t.name).sort()).toEqual([...WAGGLE, ...Object.values(LEGACY_TOOL_NAMES)].sort());
  });

  test("every alias has the same schema as its tool and the old-name description", () => {
    const tools = buildMcpTools(true);
    for (const name of WAGGLE) {
      const tool = tools.find((t) => t.name === name)!;
      const alias = tools.find((t) => t.name === LEGACY_TOOL_NAMES[name])!;
      expect(alias.inputSchema).toEqual(tool.inputSchema);
      expect(alias.description).toBe(`Old name of ${name}. Use ${name}.`);
    }
  });

  test("an alias resolves to the same handler as the waggle tool", () => {
    for (const name of WAGGLE) {
      expect(canonicalToolName(name, true)).toBe(name);
      expect(canonicalToolName(LEGACY_TOOL_NAMES[name]!, true)).toBe(name);
    }
    expect(canonicalToolName("knock_nope", true)).toBeNull();
  });

  test("switch off: the aliases are not listed and do not resolve", () => {
    expect(buildMcpTools(false).map((t) => t.name).sort()).toEqual([...WAGGLE].sort());
    for (const name of WAGGLE) {
      expect(canonicalToolName(name, false)).toBe(name);
      expect(canonicalToolName(LEGACY_TOOL_NAMES[name]!, false)).toBeNull();
    }
  });

  test("the Swift switch matches the daemon switch", async () => {
    const swift = await Bun.file(`${import.meta.dir}/../../apps/macos/Sources/Knock/Support/LegacyNames.swift`).text();
    const match = swift.match(/aliasesEnabled\s*=\s*(true|false)/);
    expect(match).not.toBeNull();
    expect(match![1] === "true").toBe(LEGACY_KNOCK_ALIASES);
  });
});
