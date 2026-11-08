import { run, runAsync, type RunResult } from "./exec";

// HAIL-176: the names Codex knows Waggle by, and the old Knock names (read only to move an old
// install while LEGACY_KNOCK_ALIASES is on).
export const CODEX_SERVER_NAME = "waggle";
export const LEGACY_CODEX_SERVER_NAME = "knock";
export const LEGACY_CODEX_PLUGIN_ID = "knock@knock";
export const LEGACY_CODEX_MARKETPLACE = "knock";

// The codex CLI is found on PATH. Every call goes through `run` so tests can
// stub the binary; this module never touches a real ~/.codex/config.toml.
//
// `waggle install codex` registers the MCP server exactly as
// docs/protocol-mvp.md and KNOCK-20 describe:
//   codex mcp add waggle --env KNOCK_RUNTIME=codex -- <abs path to waggle> mcp
// (verified against a local codex-cli 0.154.0 install: `codex mcp add <name>
// [--env K=V] -- <command>...`, `codex mcp get <name> [--json]`, `codex mcp
// remove <name>`, `codex mcp list [--json]`).

export function codexMcpList(): RunResult {
  return run("codex", ["mcp", "list", "--json"]);
}

export function codexMcpGet(name: string = CODEX_SERVER_NAME): RunResult {
  return run("codex", ["mcp", "get", name, "--json"]);
}

export function codexMcpAdd(knockPath: string): RunResult {
  return run("codex", ["mcp", "add", CODEX_SERVER_NAME, "--env", "KNOCK_RUNTIME=codex", "--", knockPath, "mcp"]);
}

export function codexMcpRemove(name: string = CODEX_SERVER_NAME): RunResult {
  return run("codex", ["mcp", "remove", name]);
}

export function codexVersion(): RunResult {
  return run("codex", ["--version"]);
}

// Async twins of `codexVersion`/`codexMcpList`, used only by `waggle doctor`
// (doctor.ts) so its Claude Code and Codex checks actually overlap on the
// wire instead of queueing behind each other (KNOCK-20 fold pass 2).
export function codexVersionAsync(): Promise<RunResult> {
  return runAsync("codex", ["--version"]);
}

export function codexMcpListAsync(): Promise<RunResult> {
  return runAsync("codex", ["mcp", "list", "--json"]);
}

// True when `codex mcp list --json` includes a server named "knock" (presence
// only, the same level of check `isKnockRegistered` does for Claude Code from
// `claude mcp list`). Used by `waggle doctor` and `waggle uninstall`.
export function isCodexRegistered(listStdout: string, name: string = CODEX_SERVER_NAME): boolean {
  try {
    const parsed = JSON.parse(listStdout) as unknown;
    return Array.isArray(parsed) && parsed.some((s) => (s as { name?: string })?.name === name);
  } catch {
    return false;
  }
}

// True when `codex mcp get knock --json` already shows the exact command Waggle
// would register: the knock binary path invoked with a single "mcp" argument.
// `waggle install codex` uses this for its idempotency check ("when `codex mcp
// get knock` already shows the same command").
// The absolute path the knock MCP server is registered with under Codex, or
// null when it is not registered. doctor uses it to warn when that path no
// longer exists, the same way `registeredKnockPath` (claude.ts) does for
// Claude Code (KNOCK-21 stable binary path, extended to Codex in KNOCK-20 fold
// pass 4).
export function registeredCodexKnockPath(listStdout: string, name: string = CODEX_SERVER_NAME): string | null {
  try {
    const parsed = JSON.parse(listStdout) as unknown;
    if (!Array.isArray(parsed)) return null;
    const entry = parsed.find((s) => (s as { name?: string })?.name === name) as
      | { transport?: { command?: string } }
      | undefined;
    return entry?.transport?.command ?? null;
  } catch {
    return null;
  }
}

export function isCodexCommandRegistered(getStdout: string, knockPath: string): boolean {
  try {
    const parsed = JSON.parse(getStdout) as {
      transport?: { command?: string; args?: string[] };
    };
    const transport = parsed.transport;
    return (
      transport?.command === knockPath &&
      Array.isArray(transport.args) &&
      transport.args.length === 1 &&
      transport.args[0] === "mcp"
    );
  } catch {
    return false;
  }
}

// HAIL-137: the Waggle Codex plugin. Verified against codex-cli 0.154.0 (read-only help, then
// the commands below against a temporary CODEX_HOME):
//   codex plugin --help                    exits 0 only where `codex plugin` exists
//   codex plugin marketplace list --json   { marketplaces: [{ name, root }] }
//   codex plugin marketplace add <path>    adds a local marketplace (reads .agents/plugins/marketplace.json)
//   codex plugin marketplace remove <name>
//   codex plugin list --json               { installed: [{ pluginId, version, enabled }] }
//   codex plugin add <plugin>@<market>     installs; run again after a version change and it replaces
//                                          the cached copy (there is no `update` for a local marketplace)
//   codex plugin remove <plugin>@<market>
export const CODEX_PLUGIN_ID = "waggle@waggle";
export const CODEX_MARKETPLACE = "waggle";

export function codexPluginsSupported(): boolean {
  return run("codex", ["plugin", "--help"]).status === 0;
}

export async function codexPluginsSupportedAsync(): Promise<boolean> {
  return (await runAsync("codex", ["plugin", "--help"])).status === 0;
}

export function codexPluginList(): RunResult {
  return run("codex", ["plugin", "list", "--json"]);
}

export function codexPluginListAsync(): Promise<RunResult> {
  return runAsync("codex", ["plugin", "list", "--json"]);
}

export function codexMarketplaceList(): RunResult {
  return run("codex", ["plugin", "marketplace", "list", "--json"]);
}

export function codexMarketplaceListAsync(): Promise<RunResult> {
  return runAsync("codex", ["plugin", "marketplace", "list", "--json"]);
}

export function codexMarketplaceAdd(path: string): RunResult {
  return run("codex", ["plugin", "marketplace", "add", path]);
}

export function codexMarketplaceRemove(name: string): RunResult {
  return run("codex", ["plugin", "marketplace", "remove", name]);
}

export function codexPluginAdd(id: string): RunResult {
  return run("codex", ["plugin", "add", id]);
}

export function codexPluginRemove(id: string): RunResult {
  return run("codex", ["plugin", "remove", id]);
}

export interface InstalledCodexPlugin {
  version: string | null;
  enabled: boolean;
}

// The installed "knock@knock" plugin from `codex plugin list --json`, or null.
export function codexKnockPluginEntry(result: RunResult, id: string = CODEX_PLUGIN_ID): InstalledCodexPlugin | null {
  if (result.status !== 0) return null;
  try {
    const list = (JSON.parse(result.stdout) as { installed?: unknown }).installed;
    if (!Array.isArray(list)) return null;
    const entry = list.find((p) => p?.pluginId === id);
    if (!entry) return null;
    return { version: typeof entry.version === "string" ? entry.version : null, enabled: entry.enabled !== false };
  } catch {
    return null;
  }
}

// The root of the marketplace named "knock" in `codex plugin marketplace list --json`, or null.
export function codexKnockMarketplaceRoot(
  result: RunResult,
  name: string = CODEX_MARKETPLACE,
): { root: string | null } | null {
  if (result.status !== 0) return null;
  try {
    const list = (JSON.parse(result.stdout) as { marketplaces?: unknown }).marketplaces;
    if (!Array.isArray(list)) return null;
    const entry = list.find((m) => m?.name === name);
    if (!entry) return null;
    return { root: typeof entry.root === "string" ? entry.root : null };
  } catch {
    return null;
  }
}
