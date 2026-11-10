import { LEGACY_KNOCK_ALIASES } from "../protocol/legacy-aliases";
import { run, runAsync, type RunResult } from "./exec";

// HAIL-176: the names Claude Code knows Waggle by, and the Knock names it used to have. The legacy
// names are read only while LEGACY_KNOCK_ALIASES is on, to move an old install to the new names.
export const CLAUDE_SERVER_NAME = "waggle";
export const CLAUDE_PLUGIN_ID = "waggle@waggle";
export const CLAUDE_MARKETPLACE = "waggle";
export const LEGACY_CLAUDE_SERVER_NAME = "knock";
export const LEGACY_CLAUDE_PLUGIN_ID = "knock@knock";
export const LEGACY_CLAUDE_MARKETPLACE = "knock";

// The claude CLI is found on PATH. Every call goes through `run` so tests can
// stub the binary; this module never touches real Claude Code settings.
//
// `waggle install claude` registers the MCP server at user scope exactly as
// docs/protocol-mvp.md and INSTALL.md describe:
//   claude mcp add --scope user waggle -e KNOCK_RUNTIME=claude -- <abs path to waggle> mcp
// (KNOCK-20 added the -e KNOCK_RUNTIME=claude env flag; `claude mcp add -e
// K=V ...` is the syntax a locally installed Claude Code 2.1.283 accepts.)

// `claude mcp get knock` prints the server's command, args and an
// "Environment:" block listing each `KEY=value` line — used to detect an
// older registration that predates the runtime env (see `hasRuntimeEnv`).
export function claudeMcpGet(name: string = CLAUDE_SERVER_NAME): RunResult {
  return run("claude", ["mcp", "get", name]);
}

export function claudeMcpAdd(knockPath: string): RunResult {
  return run("claude", [
    "mcp",
    "add",
    "--scope",
    "user",
    CLAUDE_SERVER_NAME,
    "-e",
    "KNOCK_RUNTIME=claude",
    "--",
    knockPath,
    "mcp",
  ]);
}

export function claudeMcpRemove(name: string = CLAUDE_SERVER_NAME): RunResult {
  return run("claude", ["mcp", "remove", "--scope", "user", name]);
}

export function claudeVersion(): RunResult {
  return run("claude", ["--version"]);
}

// Async twin of `claudeVersion`, used only by `waggle doctor` (doctor.ts) so its
// Claude Code and Codex checks actually overlap on the wire instead of queueing
// behind each other (KNOCK-20 fold pass 2).
export function claudeVersionAsync(): Promise<RunResult> {
  return runAsync("claude", ["--version"]);
}

// `claude mcp get knock` checks only Waggle's own entry (about 1 s), where
// `claude mcp list` health-checks every configured server (10 s on a Mac
// with ~20 servers, over the 15 s exec timeout on a friend's Mac: the
// Connect screen then showed Claude Code as "not connected" and stuck on
// "Checking…"). doctor and install use `get` for the registration check.
export function claudeMcpGetAsync(name: string = CLAUDE_SERVER_NAME): Promise<RunResult> {
  return runAsync("claude", ["mcp", "get", name]);
}

// True when `claude mcp get knock` found the server: it prints "knock:" on
// the first line and exits 0; a missing server exits 1 with
// "No MCP server named ...".
export function isKnockRegisteredInGet(result: RunResult, name: string = CLAUDE_SERVER_NAME): boolean {
  return result.status === 0 && new RegExp(`^${name}\\s*:\\s*$`, "m").test(result.stdout);
}

// The command path from `claude mcp get knock` ("  Command: /path/knock").
export function registeredKnockPathFromGet(getStdout: string): string | null {
  const match = getStdout.match(/^\s*Command:\s*(\S+)/m);
  return match ? match[1] : null;
}

// A registered server appears in `claude mcp list` as a line that starts with
// its name and a colon, for example `knock: /path/waggle mcp - Connected`.
export function isKnockRegistered(listStdout: string, name: string = CLAUDE_SERVER_NAME): boolean {
  return new RegExp(`^${name}\\s*:`, "m").test(listStdout);
}

// True when `claude mcp get knock` already shows KNOCK_RUNTIME=claude in its
// "Environment:" block. False for a registration made before KNOCK-20 added
// the env flag, which `waggle install claude` then replaces once.
export function hasRuntimeEnv(getStdout: string): boolean {
  return /^\s*KNOCK_RUNTIME=claude\s*$/m.test(getStdout);
}

// The absolute path the knock MCP server is registered with, or null when it is
// not registered. doctor uses it to warn when that path no longer exists
// (KNOCK-21 stable binary path).
export function registeredKnockPath(listStdout: string, name: string = CLAUDE_SERVER_NAME): string | null {
  const match = listStdout.match(new RegExp(`^${name}\\s*:\\s*(\\S+)`, "m"));
  return match ? match[1] : null;
}

// HAIL-134: the Waggle Claude Code plugin (plugins/claude-code/knock) brings its own
// MCP server, so a user entry made by `waggle install` would start a second one.
// `claude plugin list --json` is read-only and prints an array of installed
// plugins: [{ "id": "knock@knock", "enabled": true, ... }].
export function claudePluginList(): RunResult {
  return run("claude", ["plugin", "list", "--json"]);
}

export function claudePluginListAsync(): Promise<RunResult> {
  return runAsync("claude", ["plugin", "list", "--json"]);
}

// True when an enabled plugin named "waggle" (or, with the legacy aliases on, the old "knock")
// is installed, whatever its marketplace.
export function isKnockPluginInList(result: RunResult): boolean {
  if (result.status !== 0) return false;
  try {
    const list = JSON.parse(result.stdout) as unknown;
    return (
      Array.isArray(list) &&
      list.some((p) => {
        const id = typeof p?.id === "string" ? p.id : "";
        const plugin = id.split("@")[0];
        return (plugin === "waggle" || (LEGACY_KNOCK_ALIASES && plugin === "knock")) && p.enabled !== false;
      })
    );
  } catch {
    return false;
  }
}

// HAIL-135: Waggle installs its bundled plugin through Claude Code's plugin commands.
// `claude plugin --help` is read-only and exits 0 only where the command exists.
export function claudePluginsSupported(): boolean {
  return run("claude", ["plugin", "--help"]).status === 0;
}

export async function claudePluginsSupportedAsync(): Promise<boolean> {
  return (await runAsync("claude", ["plugin", "--help"])).status === 0;
}

// `claude plugin marketplace list --json` prints [{ "name", "source", "path" | "installLocation" }].
export function claudeMarketplaceList(): RunResult {
  return run("claude", ["plugin", "marketplace", "list", "--json"]);
}

export function claudeMarketplaceListAsync(): Promise<RunResult> {
  return runAsync("claude", ["plugin", "marketplace", "list", "--json"]);
}

export function claudeMarketplaceAdd(path: string): RunResult {
  return run("claude", ["plugin", "marketplace", "add", path, "--scope", "user"]);
}

export function claudeMarketplaceUpdate(name: string): RunResult {
  return run("claude", ["plugin", "marketplace", "update", name]);
}

export function claudeMarketplaceRemove(name: string): RunResult {
  return run("claude", ["plugin", "marketplace", "remove", name]);
}

export function claudePluginInstall(id: string): RunResult {
  return run("claude", ["plugin", "install", id, "--scope", "user"]);
}

export function claudePluginUpdate(id: string): RunResult {
  return run("claude", ["plugin", "update", id, "--scope", "user"]);
}

export function claudePluginEnable(id: string): RunResult {
  return run("claude", ["plugin", "enable", id, "--scope", "user"]);
}

export function claudePluginUninstall(id: string): RunResult {
  return run("claude", ["plugin", "uninstall", id, "--scope", "user"]);
}

export interface KnockMarketplace {
  // Where Claude Code reads the marketplace from; null when the list does not say.
  path: string | null;
}

// The marketplace named `name` ("waggle", or the old "knock") in `claude plugin marketplace list
// --json`, or null.
export function knockMarketplaceInList(result: RunResult, name: string = CLAUDE_MARKETPLACE): KnockMarketplace | null {
  if (result.status !== 0) return null;
  try {
    const list = JSON.parse(result.stdout) as unknown;
    if (!Array.isArray(list)) return null;
    const entry = list.find((m) => m?.name === name);
    if (!entry) return null;
    const path = entry.path ?? entry.installLocation;
    return { path: typeof path === "string" ? path : null };
  } catch {
    return null;
  }
}

export interface InstalledKnockPlugin {
  version: string | null;
  enabled: boolean;
}

// The installed plugin `id` ("waggle@waggle", or the old "knock@knock") from `claude plugin list
// --json`, or null.
export function knockPluginEntry(result: RunResult, id: string = CLAUDE_PLUGIN_ID): InstalledKnockPlugin | null {
  if (result.status !== 0) return null;
  try {
    const list = JSON.parse(result.stdout) as unknown;
    if (!Array.isArray(list)) return null;
    const entry = list.find((p) => p?.id === id);
    if (!entry) return null;
    return { version: typeof entry.version === "string" ? entry.version : null, enabled: entry.enabled !== false };
  } catch {
    return null;
  }
}
