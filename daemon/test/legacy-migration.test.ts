import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rmrf, tmpHome } from "./helpers";

// HAIL-176: `waggle install claude|codex --refresh` moves an install made before the rename
// (plugin knock@knock, marketplace knock, MCP entry knock) to waggle@waggle. Fake `claude` and
// `codex` binaries on PATH, a temp HOME and a temp KNOCK_HOME: nothing touches a real Claude Code,
// Codex or ~/.claude. Each fake keeps its state in plain files so a run can be repeated.

const ENTRY = join(import.meta.dir, "..", "src", "index.ts");

// State in $S: plugins (lines "<id> <version>"), markets (lines "<name> <path>"), mcp-<name> files.
const CLAUDE_SH = `#!/bin/sh
printf 'claude %s\\n' "$*" >> "$LOG"
S="$STATE"
touch "$S/plugins" "$S/markets"
json_plugins() {
  printf '['; first=1
  while read -r id ver; do
    [ -z "$id" ] && continue
    [ $first = 1 ] || printf ','
    printf '{"id":"%s","version":"%s","scope":"user","enabled":true}' "$id" "$ver"; first=0
  done < "$S/plugins"
  printf ']\\n'
}
json_markets() {
  printf '['; first=1
  while read -r name path; do
    [ -z "$name" ] && continue
    [ $first = 1 ] || printf ','
    printf '{"name":"%s","source":"directory","path":"%s"}' "$name" "$path"; first=0
  done < "$S/markets"
  printf ']\\n'
}
case "$1" in
  --version) echo "2.1.287 (Claude Code)" ;;
  mcp)
    case "$2" in
      get) if [ -f "$S/mcp-$3" ]; then echo "$3:"; echo "  Command: /stub/$3"; echo "  Environment:"; echo "    KNOCK_RUNTIME=claude"; else echo "No MCP server found with name: $3" >&2; exit 1; fi ;;
      add) touch "$S/mcp-$5" ;;
      remove) rm -f "$S/mcp-$5" ;;
    esac ;;
  plugin)
    case "$2" in
      --help) echo "Manage plugins" ;;
      list) json_plugins ;;
      marketplace)
        case "$3" in
          list) json_markets ;;
          add)
            name=$(sed -n 's/.*"name": *"\\([^"]*\\)".*/\\1/p' "$4/.claude-plugin/marketplace.json" | head -1)
            if [ -n "$REJECT_SAME_DIR" ] && grep -q " $4\\$" "$S/markets"; then echo "marketplace source already added" >&2; exit 1; fi
            if grep -q " $4\\$" "$S/markets"; then echo "Marketplace already on disk"; exit 0; fi
            echo "$name $4" >> "$S/markets" ;;
          remove) grep -v "^$4 " "$S/markets" > "$S/m.tmp"; mv "$S/m.tmp" "$S/markets"
                  grep -v "@$4 " "$S/plugins" > "$S/p.tmp"; mv "$S/p.tmp" "$S/plugins" ;;
          update) : ;;
        esac ;;
      install) m="\${3#*@}"; if ! grep -q "^$m " "$S/markets"; then echo "Plugin not found in marketplace $m" >&2; exit 1; fi
               ver=$(sed -n 's/.*"version": *"\\([^"]*\\)".*/\\1/p' "$BUNDLE/waggle/.claude-plugin/plugin.json"); echo "$3 $ver" >> "$S/plugins" ;;
      uninstall) grep -v "^$3 " "$S/plugins" > "$S/p.tmp"; mv "$S/p.tmp" "$S/plugins" ;;
      update|enable) : ;;
    esac ;;
esac
exit 0
`;

const CODEX_SH = `#!/bin/sh
printf 'codex %s\\n' "$*" >> "$LOG"
S="$STATE"
touch "$S/plugins" "$S/markets"
case "$1" in
  --version) echo "codex-cli 0.154.0" ;;
  mcp)
    case "$2" in
      get) if [ -f "$S/mcp-$3" ]; then echo '{"transport":{"command":"/stub/'"$3"'","args":["mcp"]}}'; else exit 1; fi ;;
      add) cmd=""; name="$3"; shift 3; while [ $# -gt 0 ]; do case "$1" in --) shift; cmd="$1"; break ;; *) shift ;; esac; done; echo "$cmd" > "$S/mcp-$name" ;;
      remove) rm -f "$S/mcp-$3" ;;
      list) echo '[]' ;;
    esac ;;
  plugin)
    case "$2" in
      --help) echo "Manage plugins" ;;
      list)
        printf '{"installed":['; first=1
        while read -r id ver; do [ -z "$id" ] && continue; [ $first = 1 ] || printf ','; printf '{"pluginId":"%s","version":"%s","enabled":true}' "$id" "$ver"; first=0; done < "$S/plugins"
        printf '],"available":[]}\\n' ;;
      marketplace)
        case "$3" in
          list)
            printf '{"marketplaces":['; first=1
            while read -r name path; do [ -z "$name" ] && continue; [ $first = 1 ] || printf ','; printf '{"name":"%s","root":"%s"}' "$name" "$path"; first=0; done < "$S/markets"
            printf ']}\\n' ;;
          add) name=$(sed -n 's/.*"name": *"\\([^"]*\\)".*/\\1/p' "$4/.agents/plugins/marketplace.json" | head -1); echo "$name $4" >> "$S/markets" ;;
          remove) grep -v "^$4 " "$S/markets" > "$S/m.tmp"; mv "$S/m.tmp" "$S/markets" ;;
        esac ;;
      add) ver=$(sed -n 's/.*"version": *"\\([^"]*\\)".*/\\1/p' "$CODEX_BUNDLE/waggle/plugin.json"); echo "$3 $ver" >> "$S/plugins" ;;
      remove) grep -v "^$3 " "$S/plugins" > "$S/p.tmp"; mv "$S/p.tmp" "$S/plugins" ;;
    esac ;;
esac
exit 0
`;

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmrf(d);
});

function setup() {
  const dir = mkdtempSync(join(tmpdir(), "knock-lm-"));
  dirs.push(dir);
  const state = join(dir, "state");
  mkdirSync(state);
  for (const [name, body] of [["claude", CLAUDE_SH], ["codex", CODEX_SH]] as const) {
    writeFileSync(join(dir, name), body);
    chmodSync(join(dir, name), 0o755);
  }
  // The app's bundled marketplaces: both carry the waggle plugin at 0.2.0.
  const claudeDir = join(dir, "App.app", "Contents", "Resources", "claude-plugin");
  mkdirSync(join(claudeDir, ".claude-plugin"), { recursive: true });
  mkdirSync(join(claudeDir, "waggle", ".claude-plugin"), { recursive: true });
  writeFileSync(join(claudeDir, ".claude-plugin", "marketplace.json"), `{ "name": "waggle" }`);
  writeFileSync(join(claudeDir, "waggle", ".claude-plugin", "plugin.json"), `{ "name": "waggle", "version": "0.2.0" }`);
  const codexDir = join(dir, "App.app", "Contents", "Resources", "codex-plugin");
  mkdirSync(join(codexDir, ".agents", "plugins"), { recursive: true });
  mkdirSync(join(codexDir, "waggle"), { recursive: true });
  writeFileSync(join(codexDir, ".agents", "plugins", "marketplace.json"), `{ "name": "waggle" }`);
  writeFileSync(join(codexDir, "waggle", "plugin.json"), `{ "name": "waggle", "version": "0.2.0" }`);
  const home = tmpHome();
  dirs.push(home);
  const env = (extra: Record<string, string> = {}) => ({
    ...process.env,
    HOME: home,
    KNOCK_HOME: home,
    PATH: `${dir}:/usr/bin:/bin`,
    LOG: join(dir, "log"),
    STATE: state,
    BUNDLE: join(dir, "App.app", "Contents", "Resources", "claude-plugin"),
    CODEX_BUNDLE: join(dir, "App.app", "Contents", "Resources", "codex-plugin"),
    KNOCK_PLUGIN_DIR: claudeDir,
    KNOCK_CODEX_PLUGIN_DIR: codexDir,
    ...extra,
  });
  const read = (name: string) => (existsSync(join(state, name)) ? readFileSync(join(state, name), "utf8") : "");
  const log = () => (existsSync(join(dir, "log")) ? readFileSync(join(dir, "log"), "utf8") : "");
  return { dir, state, home, env, read, log, claudeDir, codexDir };
}

async function waggle(args: string[], env: Record<string, string | undefined>) {
  const proc = Bun.spawn([process.execPath, ENTRY, ...args], {
    env: env as Record<string, string>,
    stdout: "pipe",
    stderr: "pipe",
    stdin: "ignore",
  });
  const code = await proc.exited;
  return { code, stdout: await new Response(proc.stdout).text(), stderr: await new Response(proc.stderr).text() };
}

describe("Claude Code: knock@knock moves to waggle@waggle", () => {
  test("refresh installs waggle@waggle, removes the old plugin, its marketplace and the knock entry", async () => {
    const s = setup();
    writeFileSync(join(s.state, "plugins"), "knock@knock 0.1.1\n");
    writeFileSync(join(s.state, "markets"), `knock ${s.claudeDir}\n`);
    writeFileSync(join(s.state, "mcp-knock"), "");
    const r = await waggle(["install", "claude", "--refresh"], s.env());
    expect(r.code).toBe(0);
    expect(s.read("plugins")).toBe("waggle@waggle 0.2.0\n");
    expect(s.read("markets")).toBe(`waggle ${s.claudeDir}\n`);
    expect(existsSync(join(s.state, "mcp-knock"))).toBe(false);
    expect(r.stdout).toContain("Moved the Claude Code plugin knock@knock to waggle@waggle");
    // Same folder (an update in place): Claude Code keeps the folder under the name knock, so the
    // old plugin and marketplace go first, then the folder is added as waggle.
    const log = s.log();
    expect(log.indexOf("plugin uninstall knock@knock")).toBeLessThan(log.indexOf("plugin marketplace add"));
  });

  test("an old marketplace in another folder: the new plugin goes in before the old one comes out", async () => {
    const s = setup();
    writeFileSync(join(s.state, "plugins"), "knock@knock 0.1.1\n");
    writeFileSync(join(s.state, "markets"), "knock /old/Knock.app/Contents/Resources/claude-plugin\n");
    const r = await waggle(["install", "claude", "--refresh"], s.env());
    expect(r.code).toBe(0);
    expect(s.read("plugins")).toBe("waggle@waggle 0.2.0\n");
    expect(s.read("markets")).toBe(`waggle ${s.claudeDir}\n`);
    const log = s.log();
    expect(log.indexOf("plugin install waggle@waggle")).toBeLessThan(log.indexOf("plugin uninstall knock@knock"));
  });

  test("is idempotent: a second refresh changes nothing and says nothing about the move", async () => {
    const s = setup();
    writeFileSync(join(s.state, "plugins"), "knock@knock 0.1.1\n");
    writeFileSync(join(s.state, "markets"), `knock ${s.claudeDir}\n`);
    await waggle(["install", "claude", "--refresh"], s.env());
    const again = await waggle(["install", "claude", "--refresh"], s.env());
    expect(again.code).toBe(0);
    expect(again.stdout).not.toContain("Moved the Claude Code plugin");
    expect(again.stdout).toContain("Waggle Claude Code plugin already installed.");
    expect(s.read("plugins")).toBe("waggle@waggle 0.2.0\n");
  });

  test("a refresh with nothing installed still installs nothing", async () => {
    const s = setup();
    const r = await waggle(["install", "claude", "--refresh"], s.env());
    expect(r.code).toBe(0);
    expect(s.read("plugins")).toBe("");
  });

  test("when Claude Code refuses a second marketplace on the same folder, the old one goes and the add is retried", async () => {
    const s = setup();
    writeFileSync(join(s.state, "plugins"), "knock@knock 0.1.1\n");
    writeFileSync(join(s.state, "markets"), `knock ${s.claudeDir}\n`);
    const r = await waggle(["install", "claude", "--refresh"], s.env({ REJECT_SAME_DIR: "1" }));
    expect(r.code).toBe(0);
    expect(s.read("plugins")).toBe("waggle@waggle 0.2.0\n");
    expect(s.read("markets")).toBe(`waggle ${s.claudeDir}\n`);
  });

  test("install --mcp moves a knock user entry to waggle", async () => {
    const s = setup();
    writeFileSync(join(s.state, "mcp-knock"), "");
    const r = await waggle(["install", "claude", "--mcp"], s.env());
    expect(r.code).toBe(0);
    expect(existsSync(join(s.state, "mcp-waggle"))).toBe(true);
    expect(existsSync(join(s.state, "mcp-knock"))).toBe(false);
    expect(r.stdout).toContain("Registered Claude Code MCP server waggle.");
  });

  test("doctor counts an old knock plugin as connected, and uninstall removes old and new", async () => {
    const s = setup();
    writeFileSync(join(s.state, "plugins"), "knock@knock 0.1.1\n");
    writeFileSync(join(s.state, "markets"), `knock ${s.claudeDir}\n`);
    const doctor = await waggle(["doctor"], s.env());
    expect(doctor.stdout).toContain("ok    Claude Code MCP server registered");
    const out = await waggle(["uninstall"], s.env());
    expect(out.stdout).toContain("Removed Claude Code plugin knock@knock.");
    expect(s.read("plugins")).toBe("");
    expect(s.read("markets")).toBe("");
  });
});

describe("Codex: knock@knock moves to waggle@waggle", () => {
  test("refresh installs waggle@waggle, removes the old plugin and marketplace, and moves the knock entry", async () => {
    const s = setup();
    writeFileSync(join(s.state, "plugins"), "knock@knock 0.1.1\n");
    writeFileSync(join(s.state, "markets"), `knock ${s.codexDir}\n`);
    writeFileSync(join(s.state, "mcp-knock"), "/stub/knock\n");
    const r = await waggle(["install", "codex", "--refresh"], s.env());
    expect(r.code).toBe(0);
    expect(s.read("plugins")).toBe("waggle@waggle 0.2.0\n");
    expect(s.read("markets")).toBe(`waggle ${s.codexDir}\n`);
    expect(existsSync(join(s.state, "mcp-knock"))).toBe(false);
    expect(existsSync(join(s.state, "mcp-waggle"))).toBe(true);
    expect(r.stdout).toContain("Moved the Codex plugin knock@knock to waggle@waggle");
  });

  test("is idempotent", async () => {
    const s = setup();
    writeFileSync(join(s.state, "plugins"), "knock@knock 0.1.1\n");
    writeFileSync(join(s.state, "markets"), `knock ${s.codexDir}\n`);
    writeFileSync(join(s.state, "mcp-knock"), "/stub/knock\n");
    await waggle(["install", "codex", "--refresh"], s.env());
    const again = await waggle(["install", "codex", "--refresh"], s.env());
    expect(again.code).toBe(0);
    expect(again.stdout).not.toContain("Moved the Codex");
    expect(s.read("plugins")).toBe("waggle@waggle 0.2.0\n");
  });
});
