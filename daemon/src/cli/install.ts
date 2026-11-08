import { stableKnockPath } from "../config";
import { LEGACY_KNOCK_ALIASES } from "../protocol/legacy-aliases";
import { removeLegacyLaunchAgent } from "../service";
import {
  claudeMcpAdd,
  claudeMcpGet,
  claudeMcpRemove,
  claudePluginList,
  claudePluginsSupported,
  claudeVersion,
  hasRuntimeEnv,
  isKnockPluginInList,
  isKnockRegisteredInGet,
  LEGACY_CLAUDE_SERVER_NAME,
} from "./claude";
import { bundledPluginDir, installBundledPlugin, uninstallPlugin } from "./claude-plugin";
import {
  LEGACY_CODEX_SERVER_NAME,
  codexMcpAdd,
  codexMcpGet,
  codexMcpRemove,
  codexPluginsSupported,
  codexVersion,
  isCodexCommandRegistered,
} from "./codex";
import { bundledCodexPluginDir, installBundledCodexPlugin } from "./codex-plugin";

const RUNTIME_IDS = ["claude", "codex"] as const;
type RuntimeArg = (typeof RUNTIME_IDS)[number];

// `waggle install [claude|codex]` (`claude --mcp`: MCP entry only, no plugin, HAIL-136): registers the MCP server for one runtime, or
// (with no argument) for every runtime found on PATH — neither is required.
// Idempotent per runtime: re-running prints what did not change. Also removes
// a legacy LaunchAgent left by an older build (the current or pre-rename
// label); the pilot installs no LaunchAgent, the service starts on demand
// (docs/SERVICE.md).
// Returns 0 on success, 1 when a requested runtime failed to register or (with
// no argument) none was found, 2 for an unrecognized runtime name.
export async function runInstall(args: string[]): Promise<number> {
  const requested = args[0];
  const refresh = args.includes("--refresh");
  const mcpOnly = args.includes("--mcp");
  if (requested !== undefined && args.slice(1).some((a) => a !== "--refresh" && a !== "--mcp")) {
    process.stderr.write("waggle install: expected 'claude' or 'codex', then optionally --refresh or --mcp\n");
    return 2;
  }
  if (mcpOnly && requested !== "claude") {
    process.stderr.write("waggle install: --mcp goes with 'claude'\n");
    return 2;
  }
  if (refresh && requested !== "claude" && requested !== "codex") {
    process.stderr.write("waggle install: --refresh goes with 'claude' or 'codex'\n");
    return 2;
  }
  if (refresh && mcpOnly) {
    process.stderr.write("waggle install: --refresh and --mcp do not go together\n");
    return 2;
  }
  if (requested !== undefined && !isRuntimeArg(requested)) {
    process.stderr.write("waggle install: expected 'claude' or 'codex'\n");
    return 2;
  }

  const targets: RuntimeArg[] = requested ? [requested] : [...RUNTIME_IDS];
  let anyFailed = false;
  let anyInstalled = false;

  for (const target of targets) {
    const found = target === "claude" ? claudeVersion().status === 0 : codexVersion().status === 0;
    if (!found) {
      if (requested === undefined) {
        process.stdout.write(`Skipped ${target}: not found on PATH.\n`);
        continue;
      }
      // HAIL-218: a Codex refresh with no Codex has nothing to do. The app runs it at every launch.
      if (refresh && target === "codex") {
        process.stdout.write("Codex is not installed: nothing to refresh.\n");
        continue;
      }
      process.stderr.write(`waggle install: ${target} was not found on PATH\n`);
      anyFailed = true;
      continue;
    }
    const code = target === "claude" ? installClaude(refresh, mcpOnly) : installCodex(refresh);
    if (code === 0) anyInstalled = true;
    else anyFailed = true;
  }

  for (const label of removeLegacyLaunchAgent()) {
    process.stdout.write(`Removed legacy ${label} LaunchAgent.\n`);
  }

  if (requested === undefined && !anyInstalled && !anyFailed) {
    process.stderr.write("waggle install: no supported runtime found on PATH (claude, codex)\n");
    return 1;
  }
  return anyFailed ? 1 : 0;
}

function isRuntimeArg(value: string): value is RuntimeArg {
  return (RUNTIME_IDS as readonly string[]).includes(value);
}

// HAIL-135: with a bundled plugin and a Claude Code that has `claude plugin`, installs
// the plugin (see claude-plugin.ts). `--refresh` only updates a plugin that is
// installed already; the app runs it at launch so an updated app brings its new plugin.
// Otherwise registers (or upgrades) the Claude Code MCP server. An existing
// registration made before KNOCK-20 (no KNOCK_RUNTIME env) is replaced once.
// The registered path is the stable install path, never a build or worktree
// path (stableKnockPath, KNOCK-17).
function installClaude(refresh: boolean, mcpOnly: boolean): number {
  const out = process.stdout;
  const err = process.stderr;
  const knockPath = stableKnockPath();

  // HAIL-136: `--mcp` is the "plugin Off" mode: the MCP entry only, the plugin and its
  // marketplace removed. The entry goes in first, so a failed add leaves the plugin
  // serving Waggle rather than nothing.
  if (mcpOnly) {
    const code = registerMcpEntry(knockPath);
    if (code !== 0) return code;
    if (claudePluginsSupported()) {
      for (const line of uninstallPlugin()) out.write(`${line}\n`);
    }
    return 0;
  }

  const pluginDir = bundledPluginDir();
  if (pluginDir !== null && claudePluginsSupported()) {
    const result = installBundledPlugin(pluginDir, refresh);
    for (const line of result.lines) out.write(`${line}\n`);
    if (result.ok) return 0;
    // The plugin could not be installed: say so, and keep the MCP entry path below
    // so Waggle still reaches Claude Code.
    err.write(`waggle install: ${result.error}\n`);
    if (refresh) return 1;
    out.write("Falling back to the Claude Code MCP server.\n");
  } else if (refresh) {
    out.write("No bundled plugin or no plugin support: nothing to refresh.\n");
    return 0;
  }

  // HAIL-134: with the Waggle plugin installed, the plugin serves Waggle. Add no
  // user entry, and remove one left by an earlier install, so Claude Code runs
  // exactly one Waggle server. `waggle install` is the one command that fixes both.
  if (isKnockPluginInList(claudePluginList())) {
    out.write("Waggle is installed as a Claude Code plugin: no MCP entry needed.\n");
    if (isKnockRegisteredInGet(claudeMcpGet())) {
      claudeMcpRemove();
      out.write("Removed the older Claude Code MCP server waggle: the plugin serves Waggle now.\n");
    }
    removeLegacyClaudeEntry(out, "the plugin serves Waggle now");
    return 0;
  }

  return registerMcpEntry(knockPath);
}

// HAIL-176: the user entry made before the rename is named knock. Remove it once the waggle one
// (or the plugin) serves Waggle. Idempotent: no entry, no output.
function removeLegacyClaudeEntry(out: NodeJS.WriteStream, why: string): void {
  if (!LEGACY_KNOCK_ALIASES) return;
  if (!isKnockRegisteredInGet(claudeMcpGet(LEGACY_CLAUDE_SERVER_NAME), LEGACY_CLAUDE_SERVER_NAME)) return;
  claudeMcpRemove(LEGACY_CLAUDE_SERVER_NAME);
  out.write(`Removed the older Claude Code MCP server knock: ${why}.\n`);
}

// Registers (or upgrades) the Claude Code MCP server, whatever else is installed.
function registerMcpEntry(knockPath: string): number {
  const out = process.stdout;
  const err = process.stderr;

  // `claude mcp get knock` checks only Waggle's entry; `claude mcp list`
  // health-checks every server and could time out, which made install
  // re-add an existing server and fail (friend report 29 Sep).
  const get = claudeMcpGet();
  if (isKnockRegisteredInGet(get)) {
    if (hasRuntimeEnv(get.stdout)) {
      out.write("Claude Code MCP server waggle already registered.\n");
      removeLegacyClaudeEntry(out, "the waggle entry serves Waggle now");
      return 0;
    }
    claudeMcpRemove();
    const added = claudeMcpAdd(knockPath);
    if (added.status !== 0) {
      const detail = added.error ?? (added.stderr.trim() || added.stdout.trim());
      err.write(`waggle install: claude mcp add failed${detail ? `: ${detail}` : ""}\n`);
      return 1;
    }
    out.write("Replaced Claude Code MCP server waggle to add the runtime label.\n");
    removeLegacyClaudeEntry(out, "the waggle entry serves Waggle now");
    return 0;
  }

  const added = claudeMcpAdd(knockPath);
  if (added.status !== 0) {
    // A get that timed out can miss a server that exists: then add fails with
    // "already exists". Check once more before calling it a failure.
    if (isKnockRegisteredInGet(claudeMcpGet())) {
      out.write("Claude Code MCP server waggle already registered.\n");
      return 0;
    }
    const detail = added.error ?? (added.stderr.trim() || added.stdout.trim());
    err.write(`waggle install: claude mcp add failed${detail ? `: ${detail}` : ""}\n`);
    return 1;
  }
  out.write("Registered Claude Code MCP server waggle.\n");
  removeLegacyClaudeEntry(out, "the waggle entry serves Waggle now");
  return 0;
}

// Registers the Codex MCP server. `codex mcp add` overwrites an existing
// server of the same name in place, so a stale command is fixed by adding
// again rather than removing first. The registered path is the stable install
// path (stableKnockPath, KNOCK-17).
function installCodex(refresh: boolean): number {
  const out = process.stdout;
  const err = process.stderr;
  const knockPath = stableKnockPath();

  // HAIL-137: with a bundled plugin and a Codex that has `codex plugin`, install the plugin
  // (the skill and the hooks). `--refresh` only updates one that is installed already. The MCP
  // entry below is always kept: it serves Waggle's tools in every mode.
  const pluginDir = bundledCodexPluginDir();
  if (pluginDir !== null && codexPluginsSupported()) {
    const result = installBundledCodexPlugin(pluginDir, refresh);
    for (const line of result.lines) out.write(`${line}\n`);
    if (!result.ok) {
      err.write(`waggle install: ${result.error}\n`);
      if (refresh) return 1;
      out.write("Falling back to the Codex MCP server.\n");
    } else if (refresh && !hasLegacyCodexEntry()) {
      return 0;
    }
  } else if (refresh && !hasLegacyCodexEntry()) {
    out.write("No bundled plugin or no plugin support: nothing to refresh.\n");
    return 0;
  }

  const get = codexMcpGet();
  if (get.status === 0 && isCodexCommandRegistered(get.stdout, knockPath)) {
    out.write("Codex MCP server waggle already registered.\n");
    removeLegacyCodexEntry(out);
    return 0;
  }

  const added = codexMcpAdd(knockPath);
  if (added.status !== 0) {
    const detail = added.error ?? (added.stderr.trim() || added.stdout.trim());
    err.write(`waggle install: codex mcp add failed${detail ? `: ${detail}` : ""}\n`);
    return 1;
  }
  out.write("Registered Codex MCP server waggle.\n");
  removeLegacyCodexEntry(out);
  return 0;
}

// HAIL-176: the Codex entry made before the rename is named knock. A refresh moves it: the
// waggle entry goes in first, then the old one is removed. Idempotent.
function hasLegacyCodexEntry(): boolean {
  if (!LEGACY_KNOCK_ALIASES) return false;
  return codexMcpGet(LEGACY_CODEX_SERVER_NAME).status === 0;
}

function removeLegacyCodexEntry(out: NodeJS.WriteStream): void {
  if (!hasLegacyCodexEntry()) return;
  codexMcpRemove(LEGACY_CODEX_SERVER_NAME);
  out.write("Moved the Codex MCP server knock to waggle: removed the old entry.\n");
}
