import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rmrf, tmpHome } from "./helpers";

// HAIL-135: `waggle install|uninstall claude` and `waggle doctor` with the plugin that ships
// inside Waggle.app. `claude` is a stateful fake on PATH: nothing here touches a real
// Claude Code, a real app or a real ~/.claude.

const ENTRY = join(import.meta.dir, "..", "src", "index.ts");

// State files in $CLAUDE_STATE: market (the marketplace path), plugin (the installed
// version), disabled, registered (the MCP entry). $CLAUDE_OLD=1 makes `claude plugin`
// an unknown command, as in a Claude Code from before plugins.
const CLAUDE_SH = `#!/bin/sh
printf 'claude %s\\n' "$*" >> "$CLAUDE_LOG"
S="$CLAUDE_STATE"
case "$1" in
  mcp)
    case "$2" in
      get)
        if [ -f "$S/registered" ] && [ "$3" = "waggle" ]; then
          echo "waggle:"; echo "  Command: /stub/waggle"; echo "  Environment:"; echo "    KNOCK_RUNTIME=claude"
        else echo "No MCP server found with name: waggle" >&2; exit 1; fi ;;
      add) touch "$S/registered" ;;
      remove) [ "$5" = "waggle" ] && rm -f "$S/registered" ;;
    esac ;;
  plugin)
    if [ "$CLAUDE_OLD" = "1" ]; then echo "error: unknown command 'plugin'" >&2; exit 1; fi
    case "$2" in
      --help) echo "Manage Claude Code plugins" ;;
      marketplace)
        case "$3" in
          list) if [ -f "$S/market" ]; then printf '[{"name":"waggle","source":"directory","path":"%s"}]\\n' "$(cat "$S/market")"; else echo "[]"; fi ;;
          add) if [ -n "$CLAUDE_FAIL_ADD" ]; then echo "boom" >&2; exit 1; fi; printf '%s' "$4" > "$S/market" ;;
          remove) rm -f "$S/market" "$S/plugin" ;;
          update) : ;;
        esac ;;
      list)
        if [ -f "$S/plugin" ]; then
          en=true; [ -f "$S/disabled" ] && en=false
          printf '[{"id":"waggle@waggle","version":"%s","scope":"user","enabled":%s}]\\n' "$(cat "$S/plugin")" "$en"
        else echo "[]"; fi ;;
      install) cat "$CLAUDE_BUNDLE/waggle/.claude-plugin/plugin.json" | sed -n 's/.*"version": *"\\([^"]*\\)".*/\\1/p' > "$S/plugin" ;;
      update) cat "$CLAUDE_BUNDLE/waggle/.claude-plugin/plugin.json" | sed -n 's/.*"version": *"\\([^"]*\\)".*/\\1/p' > "$S/plugin" ;;
      enable) rm -f "$S/disabled" ;;
      uninstall) rm -f "$S/plugin" ;;
    esac ;;
  --version) echo "2.1.287 (Claude Code)" ;;
esac
exit 0
`;

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmrf(d);
});

function setup(version = "0.2.0") {
  const dir = mkdtempSync(join(tmpdir(), "knock-pi-"));
  dirs.push(dir);
  const state = join(dir, "state");
  mkdirSync(state);
  writeFileSync(join(dir, "claude"), CLAUDE_SH);
  chmodSync(join(dir, "claude"), 0o755);
  const bundle = join(dir, "App.app", "Contents", "Resources", "claude-plugin");
  mkdirSync(join(bundle, ".claude-plugin"), { recursive: true });
  mkdirSync(join(bundle, "waggle", ".claude-plugin"), { recursive: true });
  writeFileSync(join(bundle, ".claude-plugin", "marketplace.json"), "{}");
  const writeVersion = (v: string) =>
    writeFileSync(join(bundle, "waggle", ".claude-plugin", "plugin.json"), `{\n  "name": "waggle",\n  "version": "${v}"\n}\n`);
  writeVersion(version);
  const home = tmpHome();
  dirs.push(home);
  const env = (extra: Record<string, string> = {}) => ({
    ...process.env,
    HOME: home,
    KNOCK_HOME: home,
    PATH: `${dir}:/usr/bin:/bin`,
    CLAUDE_LOG: join(dir, "claude.log"),
    CLAUDE_STATE: state,
    CLAUDE_BUNDLE: bundle,
    KNOCK_PLUGIN_DIR: bundle,
    ...extra,
  });
  const log = () => (existsSync(join(dir, "claude.log")) ? readFileSync(join(dir, "claude.log"), "utf8") : "");
  const clearLog = () => rmSync(join(dir, "claude.log"), { force: true });
  return { dir, state, bundle, home, env, log, clearLog, writeVersion };
}

async function knock(args: string[], env: Record<string, string>) {
  const proc = Bun.spawn([process.execPath, ENTRY, ...args], { env, stdout: "pipe", stderr: "pipe", stdin: "ignore" });
  const code = await proc.exited;
  return { code, stdout: await new Response(proc.stdout).text(), stderr: await new Response(proc.stderr).text() };
}

describe("waggle install claude with the bundled plugin", () => {
  test("adds the bundled marketplace and installs the plugin at user scope", async () => {
    const s = setup();
    const r = await knock(["install", "claude"], s.env());
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("Installed the Waggle Claude Code plugin.");
    expect(s.log()).toContain(`plugin marketplace add ${s.bundle} --scope user`);
    expect(s.log()).toContain("plugin install waggle@waggle --scope user");
    expect(s.log()).not.toContain("mcp add");
    expect(readFileSync(join(s.state, "market"), "utf8")).toBe(s.bundle);
  });

  test("removes the older user MCP entry", async () => {
    const s = setup();
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["install", "claude"], s.env());
    expect(r.stdout).toContain("Removed the older Claude Code MCP server waggle");
    expect(existsSync(join(s.state, "registered"))).toBe(false);
  });

  test("records where this bundle's binary is, for the plugin's launcher", async () => {
    const s = setup();
    await knock(["install", "claude"], s.env());
    expect(readFileSync(join(s.home, "knock-path"), "utf8")).toBe(join(s.bundle, "..", "waggle").replace(/\/claude-plugin\/\.\.\//, "/") + "\n");
  });

  test("is idempotent: the second run changes nothing", async () => {
    const s = setup();
    await knock(["install", "claude"], s.env());
    s.clearLog();
    const r = await knock(["install", "claude"], s.env());
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("already installed");
    expect(s.log()).not.toContain("marketplace add");
    expect(s.log()).not.toContain("plugin install");
    expect(s.log()).not.toContain("plugin update");
  });

  test("a marketplace that points elsewhere (the app moved) is replaced", async () => {
    const s = setup();
    writeFileSync(join(s.state, "market"), "/Applications/Old.app/Contents/Resources/claude-plugin");
    writeFileSync(join(s.state, "plugin"), "0.2.0");
    const r = await knock(["install", "claude"], s.env());
    expect(r.code).toBe(0);
    expect(s.log()).toContain("plugin marketplace remove waggle");
    expect(s.log()).toContain(`plugin marketplace add ${s.bundle}`);
    expect(readFileSync(join(s.state, "market"), "utf8")).toBe(s.bundle);
    expect(existsSync(join(s.state, "plugin"))).toBe(true);
  });

  test("--refresh after the app moved from Knock.app to Waggle.app re-points the marketplace (HAIL-180)", async () => {
    const s = setup();
    writeFileSync(join(s.state, "market"), "/Users/x/Applications/Knock.app/Contents/Resources/claude-plugin");
    writeFileSync(join(s.state, "plugin"), "0.2.0");
    const r = await knock(["install", "claude", "--refresh"], s.env());
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("Pointed the Waggle plugin marketplace at this app.");
    expect(readFileSync(join(s.state, "market"), "utf8")).toBe(s.bundle);
    expect(existsSync(join(s.state, "plugin"))).toBe(true);
  });

  test("a newer bundled plugin refreshes the marketplace and updates the plugin", async () => {
    const s = setup("0.1.0");
    await knock(["install", "claude"], s.env());
    s.writeVersion("0.2.0");
    s.clearLog();
    const r = await knock(["install", "claude"], s.env());
    expect(r.stdout).toContain("Updated the Waggle Claude Code plugin to 0.2.0.");
    expect(s.log()).toContain("plugin marketplace update waggle");
    expect(s.log()).toContain("plugin update waggle@waggle --scope user");
    expect(readFileSync(join(s.state, "plugin"), "utf8").trim()).toBe("0.2.0");
  });

  test("--refresh does nothing when the plugin is not installed", async () => {
    const s = setup();
    const r = await knock(["install", "claude", "--refresh"], s.env());
    expect(r.code).toBe(0);
    expect(s.log()).not.toContain("marketplace add");
    expect(s.log()).not.toContain("plugin install");
  });

  test("--refresh updates an installed plugin after an app update", async () => {
    const s = setup("0.1.0");
    await knock(["install", "claude"], s.env());
    s.writeVersion("0.2.0");
    const r = await knock(["install", "claude", "--refresh"], s.env());
    expect(r.code).toBe(0);
    expect(readFileSync(join(s.state, "plugin"), "utf8").trim()).toBe("0.2.0");
  });

  test("a Claude Code without plugin support keeps the MCP entry", async () => {
    const s = setup();
    const r = await knock(["install", "claude"], s.env({ CLAUDE_OLD: "1" }));
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("Registered Claude Code MCP server waggle.");
    expect(s.log()).toContain("mcp add --scope user waggle");
    expect(s.log()).not.toContain("marketplace add");
  });

  test("a failed marketplace add falls back to the MCP entry", async () => {
    const s = setup();
    const r = await knock(["install", "claude"], s.env({ CLAUDE_FAIL_ADD: "1" }));
    expect(r.stderr).toContain("claude plugin marketplace add failed: boom");
    expect(r.stdout).toContain("Registered Claude Code MCP server waggle.");
  });

  test("no bundled plugin (a source checkout): the MCP entry, as before", async () => {
    const s = setup();
    const r = await knock(["install", "claude"], s.env({ KNOCK_PLUGIN_DIR: join(s.dir, "nope") }));
    expect(r.stdout).toContain("Registered Claude Code MCP server waggle.");
  });
});

describe("waggle install claude --mcp (plugin Off)", () => {
  test("registers the MCP entry and removes the plugin and its marketplace", async () => {
    const s = setup();
    await knock(["install", "claude"], s.env());
    expect(existsSync(join(s.state, "registered"))).toBe(false);
    const r = await knock(["install", "claude", "--mcp"], s.env());
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("Registered Claude Code MCP server waggle.");
    expect(r.stdout).toContain("Removed Claude Code plugin waggle@waggle.");
    expect(r.stdout).toContain("Removed Claude Code plugin marketplace waggle.");
    expect(existsSync(join(s.state, "registered"))).toBe(true);
    expect(existsSync(join(s.state, "plugin"))).toBe(false);
    expect(existsSync(join(s.state, "market"))).toBe(false);
  });

  test("is idempotent: the second run changes nothing", async () => {
    const s = setup();
    await knock(["install", "claude", "--mcp"], s.env());
    s.clearLog();
    const r = await knock(["install", "claude", "--mcp"], s.env());
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("already registered");
    expect(s.log()).not.toContain("mcp add");
    expect(s.log()).not.toContain("plugin uninstall");
    expect(s.log()).not.toContain("marketplace remove");
  });

  test("a failed MCP add keeps the plugin: never neither", async () => {
    const s = setup();
    await knock(["install", "claude"], s.env());
    writeFileSync(join(s.dir, "claude"), CLAUDE_SH.replace("add) touch", "add) echo nope >&2; exit 1; touch"));
    const r = await knock(["install", "claude", "--mcp"], s.env());
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("claude mcp add failed");
    expect(existsSync(join(s.state, "plugin"))).toBe(true);
  });

  test("with a Claude Code without plugin support it only registers the entry", async () => {
    const s = setup();
    const r = await knock(["install", "claude", "--mcp"], s.env({ CLAUDE_OLD: "1" }));
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("Registered Claude Code MCP server waggle.");
  });

  test("--mcp with --refresh, or with codex, is refused", async () => {
    const s = setup();
    expect((await knock(["install", "claude", "--mcp", "--refresh"], s.env())).code).toBe(2);
    expect((await knock(["install", "codex", "--mcp"], s.env())).code).toBe(2);
  });

  test("a later --refresh does not bring the plugin back", async () => {
    const s = setup();
    await knock(["install", "claude", "--mcp"], s.env());
    await knock(["install", "claude", "--refresh"], s.env());
    expect(existsSync(join(s.state, "plugin"))).toBe(false);
  });
});

describe("waggle uninstall claude with the bundled plugin", () => {
  test("removes the plugin, the marketplace and the MCP entry", async () => {
    const s = setup();
    await knock(["install", "claude"], s.env());
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["uninstall"], s.env());
    expect(r.stdout).toContain("Removed Claude Code plugin waggle@waggle.");
    expect(r.stdout).toContain("Removed Claude Code plugin marketplace waggle.");
    expect(r.stdout).toContain("Removed Claude Code MCP server waggle.");
    expect(existsSync(join(s.state, "plugin"))).toBe(false);
    expect(existsSync(join(s.state, "market"))).toBe(false);
  });

  test("with old Claude Code it only removes the MCP entry", async () => {
    const s = setup();
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["uninstall"], s.env({ CLAUDE_OLD: "1" }));
    expect(r.stdout).toContain("Removed Claude Code MCP server waggle.");
    expect(r.stdout).not.toContain("plugin marketplace");
  });
});

describe("waggle doctor with the bundled plugin", () => {
  test("plugin mode: ok lines, no marketplace failure", async () => {
    const s = setup();
    await knock(["install", "claude"], s.env());
    const r = await knock(["doctor"], s.env());
    expect(r.stdout).toContain("ok    Claude Code installed as plugin");
    expect(r.stdout).not.toContain("marketplace path missing");
    expect(r.stdout).not.toContain("installed as MCP entry");
  });

  test("reports when the plugin can be offered (plugin support and a bundle)", async () => {
    const s = setup();
    writeFileSync(join(s.state, "registered"), "");
    expect((await knock(["doctor"], s.env())).stdout).toContain("ok    Claude Code can install the Waggle plugin");
    expect((await knock(["doctor"], s.env({ CLAUDE_OLD: "1" }))).stdout).not.toContain("can install the Waggle plugin");
    expect((await knock(["doctor"], s.env({ KNOCK_PLUGIN_DIR: join(s.dir, "nope") }))).stdout).not.toContain(
      "can install the Waggle plugin",
    );
  });

  test("MCP mode is named", async () => {
    const s = setup();
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["doctor"], s.env({ CLAUDE_OLD: "1" }));
    expect(r.stdout).toContain("ok    Claude Code installed as MCP entry");
  });

  test("a marketplace path that no longer exists is flagged with the fix", async () => {
    const s = setup();
    await knock(["install", "claude"], s.env());
    rmSync(join(s.dir, "App.app"), { recursive: true });
    const r = await knock(["doctor"], s.env({ KNOCK_PLUGIN_DIR: join(s.dir, "nope") }));
    expect(r.stdout).toContain(`fail  Claude Code plugin marketplace path missing: ${s.bundle}`);
    expect(r.stdout).toContain("(fix: waggle install claude)");
  });

  test("a plugin older than the app's is a warning", async () => {
    const s = setup("0.1.0");
    await knock(["install", "claude"], s.env());
    s.writeVersion("0.2.0");
    const r = await knock(["doctor"], s.env());
    expect(r.stdout).toContain("warn  installed Waggle plugin 0.1.0 differs from this app's 0.2.0");
  });
});
