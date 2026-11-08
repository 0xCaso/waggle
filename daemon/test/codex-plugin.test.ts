import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import pkg from "../package.json" with { type: "json" };
import { EventBus } from "../src/events";
import { startRpcServer, type RpcServer } from "../src/server";
import { MOD_STOP_MAX_CONTINUES, ModRegistry } from "../src/sessions/live";
import { Store } from "../src/store";
import { rmrf, rpcConnect, tmpHome, type RpcClient } from "./helpers";

// HAIL-137: the Codex plugin. `waggle install|uninstall codex` and `waggle doctor` against a
// stateful fake `codex` on PATH (never the real ~/.codex), the plugin's files and launcher,
// and the hooks (`waggle mod codex-hook`) against a real daemon in a temp KNOCK_HOME.

const ROOT = join(import.meta.dir, "..", "..");
const PLUGIN = join(ROOT, "plugins", "codex", "waggle");
const ENTRY = join(import.meta.dir, "..", "src", "index.ts");

// State in $CODEX_STATE: market (marketplace root), plugin (installed version), registered
// (the MCP entry). $CODEX_OLD=1 makes `codex plugin` an unknown command.
const CODEX_SH = `#!/bin/sh
printf 'codex %s\\n' "$*" >> "$CODEX_LOG"
S="$CODEX_STATE"
case "$1" in
  --version) echo "codex-cli 0.154.0" ;;
  mcp)
    case "$2" in
      list) if [ -f "$S/registered" ]; then echo '[{"name":"waggle","transport":{"command":"/stub/waggle"}}]'; else echo '[]'; fi ;;
      get) if [ -f "$S/registered" ] && [ "$3" = "waggle" ]; then echo '{"transport":{"command":"/stub/waggle","args":["mcp"]}}'; else exit 1; fi ;;
      add) touch "$S/registered" ;;
      remove) [ "$3" = "waggle" ] && rm -f "$S/registered" ;;
    esac ;;
  plugin)
    if [ "$CODEX_OLD" = "1" ]; then echo "error: unrecognized subcommand 'plugin'" >&2; exit 2; fi
    case "$2" in
      --help) echo "Manage Codex plugins" ;;
      marketplace)
        case "$3" in
          list) if [ -f "$S/market" ]; then printf '{"marketplaces":[{"name":"waggle","root":"%s"}]}\\n' "$(cat "$S/market")"; else echo '{"marketplaces":[]}'; fi ;;
          add) if [ -n "$CODEX_FAIL_ADD" ]; then echo "boom" >&2; exit 1; fi; printf '%s' "$4" > "$S/market" ;;
          remove) rm -f "$S/market" ;;
        esac ;;
      list)
        if [ -f "$S/plugin" ]; then printf '{"installed":[{"pluginId":"waggle@waggle","version":"%s","enabled":true}],"available":[]}\\n' "$(cat "$S/plugin")"
        else echo '{"installed":[],"available":[]}'; fi ;;
      add) sed -n 's/.*"version": *"\\([^"]*\\)".*/\\1/p' "$CODEX_BUNDLE/waggle/plugin.json" > "$S/plugin" ;;
      remove) rm -f "$S/plugin" ;;
    esac ;;
esac
exit 0
`;

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmrf(d);
});

function setup(version = "0.2.0") {
  const dir = mkdtempSync(join(tmpdir(), "knock-cx-"));
  dirs.push(dir);
  const state = join(dir, "state");
  mkdirSync(state);
  writeFileSync(join(dir, "codex"), CODEX_SH);
  chmodSync(join(dir, "codex"), 0o755);
  const bundle = join(dir, "App.app", "Contents", "Resources", "codex-plugin");
  mkdirSync(join(bundle, ".agents", "plugins"), { recursive: true });
  mkdirSync(join(bundle, "waggle"), { recursive: true });
  writeFileSync(join(bundle, ".agents", "plugins", "marketplace.json"), "{}");
  const writeVersion = (v: string) =>
    writeFileSync(join(bundle, "waggle", "plugin.json"), `{\n  "name": "waggle",\n  "version": "${v}"\n}\n`);
  writeVersion(version);
  const home = tmpHome();
  dirs.push(home);
  const env = (extra: Record<string, string> = {}) => ({
    ...process.env,
    HOME: home,
    KNOCK_HOME: home,
    CODEX_HOME: join(home, ".codex"),
    PATH: `${dir}:/usr/bin:/bin`,
    CODEX_LOG: join(dir, "codex.log"),
    CODEX_STATE: state,
    CODEX_BUNDLE: bundle,
    KNOCK_CODEX_PLUGIN_DIR: bundle,
    ...extra,
  });
  const log = () => (existsSync(join(dir, "codex.log")) ? readFileSync(join(dir, "codex.log"), "utf8") : "");
  const clearLog = () => rmSync(join(dir, "codex.log"), { force: true });
  return { dir, state, bundle, home, env, log, clearLog, writeVersion };
}

async function knock(args: string[], env: Record<string, string>, stdin?: string) {
  const proc = Bun.spawn([process.execPath, ENTRY, ...args], {
    env,
    stdout: "pipe",
    stderr: "pipe",
    stdin: stdin === undefined ? "ignore" : new Blob([stdin]),
  });
  const code = await proc.exited;
  return { code, stdout: await new Response(proc.stdout).text(), stderr: await new Response(proc.stderr).text() };
}

describe("waggle install codex with the bundled plugin", () => {
  test("adds the bundled marketplace, installs the plugin, and registers the MCP entry", async () => {
    const s = setup();
    const r = await knock(["install", "codex"], s.env());
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("Installed the Waggle Codex plugin.");
    expect(r.stdout).toContain("/hooks");
    expect(s.log()).toContain(`plugin marketplace add ${s.bundle}`);
    expect(s.log()).toContain("plugin add waggle@waggle");
    // The plugin has no MCP server of its own: Waggle's tools stay the config.toml entry.
    expect(s.log()).toContain("mcp add");
    expect(readFileSync(join(s.home, "knock-path"), "utf8")).toContain("/Resources/waggle");
  });

  test("keeps the [mcp_servers.waggle] entry next to the plugin", async () => {
    const s = setup();
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["install", "codex"], s.env());
    expect(r.stdout).not.toContain("Removed the older Codex MCP server waggle");
    expect(s.log()).not.toContain("mcp remove");
    expect(existsSync(join(s.state, "registered"))).toBe(true);
  });

  test("is idempotent", async () => {
    const s = setup();
    await knock(["install", "codex"], s.env());
    s.clearLog();
    const r = await knock(["install", "codex"], s.env());
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("already installed");
    expect(s.log()).not.toContain("marketplace add");
    expect(s.log()).not.toContain("plugin add");
  });

  test("--refresh installs a newer bundled version, and never installs a missing plugin", async () => {
    const s = setup("0.2.0");
    const none = await knock(["install", "codex", "--refresh"], s.env());
    expect(none.code).toBe(0);
    expect(none.stdout).toContain("not installed: nothing to refresh");
    expect(s.log()).not.toContain("plugin add");
    await knock(["install", "codex"], s.env());
    s.writeVersion("0.3.0");
    s.clearLog();
    const r = await knock(["install", "codex", "--refresh"], s.env());
    expect(r.stdout).toContain("Updated the Waggle Codex plugin to 0.3.0.");
    expect(readFileSync(join(s.state, "plugin"), "utf8").trim()).toBe("0.3.0");
    s.clearLog();
    await knock(["install", "codex", "--refresh"], s.env());
    expect(s.log()).not.toContain("plugin add");
  });

  test("a marketplace that points elsewhere (the app moved) is replaced", async () => {
    const s = setup();
    writeFileSync(join(s.state, "market"), "/Applications/Old.app/Contents/Resources/codex-plugin");
    writeFileSync(join(s.state, "plugin"), "0.2.0");
    const r = await knock(["install", "codex"], s.env());
    expect(r.stdout).toContain("Pointed the Waggle Codex plugin marketplace at this app.");
    expect(readFileSync(join(s.state, "market"), "utf8")).toBe(s.bundle);
  });

  test("--refresh after the app moved from Knock.app to Waggle.app re-points the marketplace (HAIL-180)", async () => {
    const s = setup();
    writeFileSync(join(s.state, "market"), "/Users/x/Applications/Knock.app/Contents/Resources/codex-plugin");
    writeFileSync(join(s.state, "plugin"), "0.2.0");
    const r = await knock(["install", "codex", "--refresh"], s.env());
    expect(r.stdout).toContain("Pointed the Waggle Codex plugin marketplace at this app.");
    expect(readFileSync(join(s.state, "market"), "utf8")).toBe(s.bundle);
  });

  test("a Codex without `codex plugin` keeps the MCP entry", async () => {
    const s = setup();
    const r = await knock(["install", "codex"], s.env({ CODEX_OLD: "1" }));
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("Registered Codex MCP server waggle.");
    expect(s.log()).toContain("mcp add waggle --env KNOCK_RUNTIME=codex");
    expect(s.log()).not.toContain("plugin add");
    const refresh = await knock(["install", "codex", "--refresh"], s.env({ CODEX_OLD: "1" }));
    expect(refresh.stdout).toContain("nothing to refresh");
  });

  test("no bundled plugin keeps the MCP entry", async () => {
    const s = setup();
    const r = await knock(["install", "codex"], s.env({ KNOCK_CODEX_PLUGIN_DIR: join(s.dir, "nope") }));
    expect(r.stdout).toContain("Registered Codex MCP server waggle.");
  });

  test("a failed marketplace add falls back to the MCP entry, and fails a refresh", async () => {
    const s = setup();
    const r = await knock(["install", "codex"], s.env({ CODEX_FAIL_ADD: "1" }));
    expect(r.stderr).toContain("codex plugin marketplace add failed");
    expect(r.stdout).toContain("Falling back to the Codex MCP server.");
    expect(s.log()).toContain("mcp add");
    writeFileSync(join(s.state, "plugin"), "0.1.0");
    const refresh = await knock(["install", "codex", "--refresh"], s.env({ CODEX_FAIL_ADD: "1" }));
    expect(refresh.code).toBe(1);
  });

  test("--mcp stays a Claude Code flag", async () => {
    const s = setup();
    const r = await knock(["install", "codex", "--mcp"], s.env());
    expect(r.code).toBe(2);
  });
});

describe("waggle uninstall and doctor with the Codex plugin", () => {
  test("uninstall removes the plugin, its marketplace and the MCP entry", async () => {
    const s = setup();
    await knock(["install", "codex"], s.env());
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["uninstall"], s.env());
    expect(r.stdout).toContain("Removed Codex plugin waggle@waggle.");
    expect(r.stdout).toContain("Removed Codex plugin marketplace waggle.");
    expect(r.stdout).toContain("Removed Codex MCP server waggle.");
    expect(existsSync(join(s.state, "plugin"))).toBe(false);
    expect(existsSync(join(s.state, "market"))).toBe(false);
  });

  test("uninstall with an old Codex skips the plugin commands", async () => {
    const s = setup();
    await knock(["uninstall"], s.env({ CODEX_OLD: "1" }));
    expect(s.log()).not.toContain("plugin list");
  });

  test("doctor reports Codex as a plugin, the trust step, and a version difference", async () => {
    const s = setup("0.2.0");
    await knock(["install", "codex"], s.env());
    s.writeVersion("0.3.0");
    const r = await knock(["doctor"], s.env());
    expect(r.stdout).toContain("ok    Codex installed as plugin");
    expect(r.stdout).toContain("ok    Codex MCP server registered");
    expect(r.stdout).toContain("installed Waggle Codex plugin 0.2.0 differs from this app's 0.3.0");
    expect(r.stdout).toContain("open /hooks in Codex");
  });

  test("doctor says the plugin can be installed, and names the MCP-entry mode", async () => {
    const s = setup();
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["doctor"], s.env());
    expect(r.stdout).toContain("ok    Codex can install the Waggle plugin");
    expect(r.stdout).toContain("ok    Codex installed as MCP entry");
    expect(r.stdout).not.toContain("Codex installed as plugin");
  });

  test("doctor flags a moved app and two servers", async () => {
    const s = setup();
    writeFileSync(join(s.state, "plugin"), "0.2.0");
    writeFileSync(join(s.state, "market"), "/gone/Old.app/codex-plugin");
    writeFileSync(join(s.state, "registered"), "");
    const r = await knock(["doctor"], s.env());
    expect(r.stdout).toContain("fail  Codex plugin marketplace path missing: /gone/Old.app/codex-plugin");
    expect(r.stdout).toContain("fail  Codex runs Waggle twice");
  });
});

describe("the plugin's files", () => {
  const json = (p: string) => JSON.parse(readFileSync(join(PLUGIN, p), "utf8"));

  test("the manifest and the marketplace agree; the plugin carries no MCP server", () => {
    const manifest = json("plugin.json");
    expect(manifest.name).toBe("waggle");
    expect(manifest.version).toMatch(/^\d+\.\d+\.\d+$/);
    expect(manifest.extensions["com.openai"].hooks).toBe("./hooks/hooks.json");
    expect(existsSync(join(PLUGIN, "mcp.json"))).toBe(false);
    const market = JSON.parse(readFileSync(join(ROOT, "plugins", "codex", "bundle", ".agents", "plugins", "marketplace.json"), "utf8"));
    expect(market.name).toBe("waggle");
    expect(market.plugins[0]).toMatchObject({ name: "waggle", source: { source: "local", path: "./waggle" } });
  });

  test("the hooks are fast launcher calls for the events Waggle needs", () => {
    const hooks = json("hooks/hooks.json").hooks as Record<string, { hooks: { command: string; timeout: number }[] }[]>;
    expect(Object.keys(hooks).sort()).toEqual(["PreToolUse", "SessionEnd", "SessionStart", "Stop", "UserPromptSubmit"]);
    for (const [event, groups] of Object.entries(hooks)) {
      const h = groups[0].hooks[0];
      expect(h.command).toContain(`mod codex-hook ${event}`);
      expect(h.command).toContain("bin/waggle-launcher");
      expect(h.timeout).toBeLessThanOrEqual(3);
    }
  });

  test("the skill points to waggle_guide and stays short", () => {
    const skill = readFileSync(join(PLUGIN, "skills", "waggle", "SKILL.md"), "utf8");
    expect(skill).toContain("waggle_guide");
    // HAIL-140 added the ASD-STE100 section; still short.
    expect(skill.split("\n").length).toBeLessThan(55);
  });

  test("the launcher runs KNOCK_BIN, passes KNOCK_RUNTIME, and stays silent for a hook when Waggle is missing", async () => {
    const d = mkdtempSync(join(tmpdir(), "knock-cxl-"));
    dirs.push(d);
    const bin = join(d, "fake-knock");
    writeFileSync(bin, '#!/bin/sh\necho "fake: $KNOCK_RUNTIME $@"\n');
    chmodSync(bin, 0o755);
    const run = async (env: Record<string, string>, ...args: string[]) => {
      const p = Bun.spawn(["sh", join(PLUGIN, "bin", "waggle-launcher"), ...args], {
        env: { PATH: "/usr/bin:/bin", HOME: d, ...env },
        stdout: "pipe",
        stderr: "pipe",
        stdin: "ignore",
      });
      const code = await p.exited;
      return { code, out: await new Response(p.stdout).text(), err: await new Response(p.stderr).text() };
    };
    expect((await run({ KNOCK_BIN: bin, KNOCK_RUNTIME: "codex" }, "mcp")).out).toBe("fake: codex mcp\n");
    const hook = await run({}, "mod", "codex-hook", "Stop");
    expect(hook).toEqual({ code: 0, out: "", err: "" });
    const mcp = await run({}, "mcp");
    expect(mcp.code).toBe(127);
    expect(mcp.err).toContain("restart Codex");
  });
});

// --- the hooks, against a real daemon ---

const servers: RpcServer[] = [];
const clients: RpcClient[] = [];
afterEach(() => {
  for (const c of clients.splice(0)) c.close();
  for (const s of servers.splice(0)) s.stop();
});

async function daemon(mods = new ModRegistry()) {
  const home = tmpHome();
  dirs.push(home);
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  servers.push(startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: pkg.version, mods }));
  const connect = async () => {
    const c = await rpcConnect(join(home, "knock.sock"));
    clients.push(c);
    return c;
  };
  const hook = (event: string, payload: object) =>
    knock(["mod", "codex-hook", event], { ...process.env, KNOCK_HOME: home, HOME: home, PATH: "/usr/bin:/bin" }, JSON.stringify(payload));
  return { home, mods, connect, hook };
}

const question = {
  kind: "question",
  title: "Pick a **layout**",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact layout with small rows", title: "Compact" },
    { id: "b", label: "Detailed layout" },
  ],
};

async function codexSession(connect: () => Promise<RpcClient>, id: string, cwd = "/tmp/proj") {
  const shim = await connect();
  await shim.request("session.hello", { session_id: id, cwd, parent_pid: process.pid, runtime: "codex" });
  return shim;
}

describe("waggle mod codex-hook", () => {
  test("reports live state from the events, with the tool name only", async () => {
    const d = await daemon();
    const sessions = await d.connect();
    await codexSession(d.connect, "thr-1");
    await d.hook("UserPromptSubmit", { session_id: "thr-1", cwd: "/tmp/proj", prompt: "SECRET PROMPT TEXT" });
    await d.hook("PreToolUse", { session_id: "thr-1", cwd: "/tmp/proj", tool_name: "Bash", tool_input: { command: "echo SECRET" } });
    const live = (await sessions.request("sessions.list", {})).result as { id: string; context: { live: any } }[];
    const s = live.find((x) => x.id === "thr-1")!;
    expect(s.context.live.phase).toBe("working");
    expect(s.context.live.last_tool).toBe("Bash");
    expect(s.context.live.tool_count).toBe(1);
    expect(JSON.stringify(s)).not.toContain("SECRET");
    await d.hook("Stop", { session_id: "thr-1", cwd: "/tmp/proj" });
    const after = (await sessions.request("sessions.list", {})).result as typeof live;
    expect(after.find((x) => x.id === "thr-1")!.context.live.phase).toBe("idle");
    // Hooks do not make a session nudgeable through a mod: they never poll.
    expect(after.find((x) => x.id === "thr-1")!.can_nudge).toBe(false);
    await d.hook("SessionEnd", { session_id: "thr-1", cwd: "/tmp/proj" });
    const ended = (await sessions.request("sessions.list", {})).result as typeof live;
    expect(ended.find((x) => x.id === "thr-1")!.context?.live ?? null).toBeNull();
  });

  test("Stop prints nothing when no ask is open", async () => {
    const d = await daemon();
    await codexSession(d.connect, "thr-2");
    const r = await d.hook("Stop", { session_id: "thr-2", cwd: "/tmp/proj", stop_hook_active: false });
    expect(r).toEqual({ code: 0, stdout: "", stderr: "" });
  });

  test("Stop continues the turn while an ask is open, at most N times", async () => {
    const d = await daemon();
    const shim = await codexSession(d.connect, "thr-3");
    const created = await shim.request("case.create", question);
    const caseId = (created.result as { id: string }).id;
    for (let i = 0; i < MOD_STOP_MAX_CONTINUES; i++) {
      const r = await d.hook("Stop", { session_id: "thr-3", cwd: "/tmp/proj" });
      expect(r.code).toBe(0);
      const out = JSON.parse(r.stdout);
      expect(out.decision).toBe("block");
      expect(out.reason).toBe(
        `A Waggle ask is still open (Pick a layout). Call waggle_check with case_id ${caseId} and wait for the answer before ending your turn.`,
      );
    }
    const capped = await d.hook("Stop", { session_id: "thr-3", cwd: "/tmp/proj" });
    expect(capped.stdout).toBe("");
  });

  test("Stop also continues for an answer the agent has not picked up", async () => {
    const d = await daemon();
    const shim = await codexSession(d.connect, "thr-4");
    const caseId = ((await shim.request("case.create", question)).result as { id: string }).id;
    const ui = await d.connect();
    await ui.request("reply.submit", { case_id: caseId, idempotency_key: "k1", choice: "a", comments: [], captures: [] });
    const r = await d.hook("Stop", { session_id: "thr-4", cwd: "/tmp/proj" });
    expect(JSON.parse(r.stdout).decision).toBe("block");
  });

  test("a hook session with another id is matched by folder, and never by guess", async () => {
    const d = await daemon();
    const shim = await codexSession(d.connect, "uuid-from-shim", "/tmp/only-one");
    await shim.request("case.create", question);
    const r = await d.hook("Stop", { session_id: "codex-thread-9", cwd: "/tmp/only-one" });
    expect(JSON.parse(r.stdout).decision).toBe("block");
    // A second Codex session in the same folder: nothing is guessed for a new hook id.
    await codexSession(d.connect, "second-uuid", "/tmp/only-one");
    const other = await d.hook("Stop", { session_id: "codex-thread-10", cwd: "/tmp/only-one" });
    expect(other.stdout).toBe("");
    // A different folder never matches.
    const far = await d.hook("Stop", { session_id: "codex-thread-11", cwd: "/tmp/elsewhere" });
    expect(far.stdout).toBe("");
  });

  test("fails silent: bad JSON, no daemon, unknown event", async () => {
    const home = tmpHome();
    dirs.push(home);
    const env = { ...process.env, KNOCK_HOME: home, HOME: home, PATH: "/usr/bin:/bin" };
    const none = await knock(["mod", "codex-hook", "Stop"], env, JSON.stringify({ session_id: "x", cwd: "/tmp" }));
    expect(none).toEqual({ code: 0, stdout: "", stderr: "" });
    expect(await knock(["mod", "codex-hook", "Stop"], env, "not json")).toEqual({ code: 0, stdout: "", stderr: "" });
    expect(await knock(["mod", "codex-hook", "Nope"], env, JSON.stringify({ session_id: "x" }))).toEqual({ code: 0, stdout: "", stderr: "" });
  });
});

describe("ModRegistry for hooks", () => {
  test("hook state stays fresh without a poll, and session.end forgets it", () => {
    let t = 1_000_000;
    const mods = new ModRegistry(() => t);
    mods.report("s", "turn.start", undefined, 1, true);
    t += 10 * 60_000;
    expect(mods.live("s")?.phase).toBe("working");
    expect(mods.attached("s")).toBe(false);
    mods.report("s", "session.end", undefined, 1, true);
    expect(mods.live("s")).toBeNull();
  });
});
