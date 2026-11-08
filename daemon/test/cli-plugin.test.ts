import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import pkg from "../package.json" with { type: "json" };
import { EventBus } from "../src/events";
import { startRpcServer, type RpcServer } from "../src/server";
import { Store } from "../src/store";
import { rmrf, rpcConnect, tmpHome } from "./helpers";

// HAIL-134: `waggle mod ...` (the mod's way to the daemon), and install, doctor and
// uninstall when the Waggle Claude Code plugin is installed. `claude`, `codex` and
// `open` are fakes on PATH. Nothing here touches a real Claude Code, a real app or
// a real ~/.claude.

const ENTRY = join(import.meta.dir, "..", "src", "index.ts");

// A fake claude: `mcp get/add/remove waggle` with a state file, and `plugin list
// --json` that prints $CLAUDE_PLUGINS (a file) when it exists.
const CLAUDE_SH = `#!/bin/sh
printf 'claude %s\\n' "$*" >> "$CLAUDE_LOG"
case "$1" in
  mcp)
    case "$2" in
      get)
        if [ -f "$CLAUDE_STATE/registered" ] && [ "$3" = "waggle" ]; then
          echo "waggle:"; echo "  Command: /stub/waggle"; echo "  Args: mcp"; echo "  Environment:"; echo "    KNOCK_RUNTIME=claude"
        else
          echo "No MCP server found with name: waggle" >&2; exit 1
        fi ;;
      list) if [ -f "$CLAUDE_STATE/registered" ]; then echo "waggle: /stub/waggle mcp - Connected"; fi ;;
      add) touch "$CLAUDE_STATE/registered" ;;
      remove) [ "$5" = "waggle" ] && rm -f "$CLAUDE_STATE/registered" ;;
    esac ;;
  plugin)
    if [ "$2" = "list" ] && [ -f "$CLAUDE_STATE/plugins.json" ]; then cat "$CLAUDE_STATE/plugins.json"; fi ;;
  --version) echo "2.1.287 (Claude Code)" ;;
esac
exit 0
`;
const OPEN_SH = `#!/bin/sh
printf 'open %s\\n' "$*" >> "$OPEN_LOG"
exit 0
`;

const dirs: string[] = [];
const servers: RpcServer[] = [];

afterEach(() => {
  for (const s of servers.splice(0)) s.stop();
  for (const d of dirs.splice(0)) rmrf(d);
});

function stub() {
  const dir = mkdtempSync(join(tmpdir(), "knock-stub-"));
  dirs.push(dir);
  const state = join(dir, "state");
  mkdirSync(state);
  for (const [name, body] of [
    ["claude", CLAUDE_SH],
    ["open", OPEN_SH],
  ]) {
    writeFileSync(join(dir, name), body);
    chmodSync(join(dir, name), 0o755);
  }
  const env = (home: string, extra: Record<string, string> = {}) => ({
    ...process.env,
    HOME: home,
    KNOCK_HOME: home,
    // No real claude or codex: only the fakes and the system tools.
    PATH: `${dir}:/usr/bin:/bin`,
    CLAUDE_LOG: join(dir, "claude.log"),
    CLAUDE_STATE: state,
    OPEN_LOG: join(dir, "open.log"),
    ...extra,
  });
  const log = (name: string) => (existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8") : "");
  return { dir, state, env, log };
}

async function knock(args: string[], env: Record<string, string>) {
  const proc = Bun.spawn([process.execPath, ENTRY, ...args], { env, stdout: "pipe", stderr: "pipe", stdin: "ignore" });
  const code = await proc.exited;
  return { code, stdout: await new Response(proc.stdout).text(), stderr: await new Response(proc.stderr).text() };
}

const PLUGIN_LIST = JSON.stringify([
  { id: "brag@brag", enabled: false },
  { id: "waggle@waggle", version: "0.1.0", scope: "user", enabled: true },
]);

describe("waggle mod", () => {
  function daemon() {
    const home = tmpHome();
    dirs.push(home);
    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    const store = new Store(db, home, bus);
    servers.push(startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: pkg.version }));
    return { home, store };
  }

  test("open with no case brings the app forward on its queue and sends no event", async () => {
    const { home } = daemon();
    const s = stub();
    const r = await knock(["mod", "open"], s.env(home, { KNOCK_BUNDLE_ID: "dev.limone.knock.test98" }));
    expect(r.code).toBe(0);
    expect(s.log("open.log")).toBe("open -b dev.limone.knock.test98\n");
  });

  test("report then poll: one line of JSON each", async () => {
    const { home } = daemon();
    const s = stub();
    const env = s.env(home);
    const report = await knock(["mod", "report", "--session", "sess-a", "--event", "tool.call", "--tool", "Bash"], env);
    expect(report.code).toBe(0);
    expect(JSON.parse(report.stdout)).toEqual({ ok: true });
    const poll = await knock(["mod", "poll", "--session", "sess-a", "--mod-version", "0.1.0"], env);
    expect(poll.code).toBe(0);
    const status = JSON.parse(poll.stdout);
    expect(status).toMatchObject({ open_ask: null, open_count: 0, answer: null, nudge: null });
    expect(typeof status.sig).toBe("string");
  });

  test("bad arguments exit 2 and send nothing", async () => {
    const { home } = daemon();
    const env = stub().env(home);
    expect((await knock(["mod"], env)).code).toBe(2);
    expect((await knock(["mod", "report", "--session", "s", "--event", "prompt.text"], env)).code).toBe(2);
    expect((await knock(["mod", "poll"], env)).code).toBe(2);
    expect((await knock(["mod", "poll", "--session", "s", "--wait-ms", "soon"], env)).code).toBe(2);
    expect((await knock(["mod", "open", "--bogus", "x"], env)).code).toBe(2);
  });

  test("open sends case.open, then brings the app forward with open -b", async () => {
    const { home, store } = daemon();
    const task = store.createTask({ name: "t", project: "p" });
    const created = store.createCase(task.id, {
      kind: "question", title: "T", need: "N", why: "W", recommendation: "a", recommendation_why: "R",
      options: [{ id: "a", label: "A" }, { id: "b", label: "B" }],
    });
    const s = stub();
    const watcher = await rpcConnect(join(home, "knock.sock"));
    await watcher.request("events.subscribe", {});
    const result = await knock(["mod", "open", "--case", created.id], s.env(home, { KNOCK_BUNDLE_ID: "dev.limone.knock.test99" }));
    expect(result.code).toBe(0);
    expect(s.log("open.log")).toBe("open -b dev.limone.knock.test99\n");
    expect((await watcher.nextLine()).params).toMatchObject({ type: "case.open_requested", case_id: created.id });
    watcher.close();
    const missing = await knock(["mod", "open", "--case", "c_nope"], s.env(home));
    expect(missing.code).toBe(1);
    expect(s.log("open.log")).toBe("open -b dev.limone.knock.test99\n"); // no second launch
  });
});

describe("waggle install claude with the plugin", () => {
  test("adds no MCP entry when the plugin is installed", async () => {
    const home = tmpHome();
    dirs.push(home);
    const s = stub();
    writeFileSync(join(s.state, "plugins.json"), PLUGIN_LIST);
    const r = await knock(["install", "claude"], s.env(home));
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("installed as a Claude Code plugin");
    expect(s.log("claude.log")).not.toContain("mcp add");
    expect(existsSync(join(s.state, "registered"))).toBe(false);
  });

  test("removes the older user entry, so Claude Code runs exactly one Waggle server", async () => {
    const home = tmpHome();
    dirs.push(home);
    const s = stub();
    writeFileSync(join(s.state, "plugins.json"), PLUGIN_LIST);
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["install", "claude"], s.env(home));
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("Removed the older Claude Code MCP server waggle");
    expect(s.log("claude.log")).toContain("mcp remove --scope user waggle");
    expect(existsSync(join(s.state, "registered"))).toBe(false);
  });

  test("a disabled plugin does not count: install registers the user entry as before", async () => {
    const home = tmpHome();
    dirs.push(home);
    const s = stub();
    writeFileSync(join(s.state, "plugins.json"), JSON.stringify([{ id: "waggle@waggle", enabled: false }]));
    const r = await knock(["install", "claude"], s.env(home));
    expect(r.code).toBe(0);
    expect(s.log("claude.log")).toContain("mcp add --scope user waggle");
  });

  test("without the plugin, install is unchanged", async () => {
    const home = tmpHome();
    dirs.push(home);
    const s = stub();
    const r = await knock(["install", "claude"], s.env(home));
    expect(r.stdout).toContain("Registered Claude Code MCP server waggle.");
  });
});

describe("waggle doctor with the plugin", () => {
  test("plugin only: registered through the plugin, no warning", async () => {
    const home = tmpHome();
    dirs.push(home);
    const s = stub();
    writeFileSync(join(s.state, "plugins.json"), PLUGIN_LIST);
    const r = await knock(["doctor"], s.env(home));
    expect(r.stdout).toContain("ok    Claude Code MCP server registered");
    expect(r.stdout).toContain("ok    Claude Code installed as plugin");
    expect(r.stdout).not.toContain("runs Waggle twice");
    expect(r.code).toBe(0);
  });

  test("plugin and user entry: names the duplicate and its fix", async () => {
    const home = tmpHome();
    dirs.push(home);
    const s = stub();
    writeFileSync(join(s.state, "plugins.json"), PLUGIN_LIST);
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["doctor"], s.env(home));
    expect(r.stdout).toContain("fail  Claude Code runs Waggle twice (the plugin and an older MCP entry)  (fix: waggle install claude)");
  });

  test("no plugin: doctor prints no plugin line", async () => {
    const home = tmpHome();
    dirs.push(home);
    const s = stub();
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["doctor"], s.env(home));
    expect(r.stdout).not.toContain("plugin");
  });
});

describe("waggle uninstall with the plugin", () => {
  test("removes the user entry, the plugin and its marketplace", async () => {
    const home = tmpHome();
    dirs.push(home);
    const s = stub();
    writeFileSync(join(s.state, "plugins.json"), PLUGIN_LIST);
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["uninstall"], s.env(home));
    expect(r.stdout).toContain("Removed Claude Code MCP server waggle.");
    expect(r.stdout).toContain("Removed Claude Code plugin waggle@waggle.");
    expect(s.log("claude.log")).toContain("plugin uninstall waggle@waggle --scope user");
  });
});
