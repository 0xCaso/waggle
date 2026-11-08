import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { currentExecPath, knockHome, stableKnockPathOrNull } from "../config";
import { LEGACY_KNOCK_ALIASES } from "../protocol/legacy-aliases";
import {
  claudeMarketplaceAdd,
  claudeMarketplaceList,
  claudeMarketplaceRemove,
  claudeMarketplaceUpdate,
  claudeMcpGet,
  claudeMcpRemove,
  CLAUDE_MARKETPLACE,
  CLAUDE_PLUGIN_ID,
  LEGACY_CLAUDE_MARKETPLACE,
  LEGACY_CLAUDE_PLUGIN_ID,
  LEGACY_CLAUDE_SERVER_NAME,
  claudePluginEnable,
  claudePluginInstall,
  claudePluginList,
  claudePluginUninstall,
  claudePluginUpdate,
  isKnockRegisteredInGet,
  knockMarketplaceInList,
  knockPluginEntry,
} from "./claude";
import type { RunResult } from "./exec";

// HAIL-135: Waggle.app ships its Claude Code plugin as a local marketplace at
// Contents/Resources/claude-plugin (scripts/bundle-app.sh). `waggle install claude`
// points Claude Code at it. This module finds that directory and runs the install.

const PLUGIN_ID = CLAUDE_PLUGIN_ID;
const MARKETPLACE = CLAUDE_MARKETPLACE;

// The bundled marketplace directory: KNOCK_PLUGIN_DIR (tests, dev), else next to this
// binary (the app's own waggle), else next to the stable install path. Null when there
// is none, for example in a source checkout: install then keeps the MCP entry.
export function bundledPluginDir(env: NodeJS.ProcessEnv = process.env): string | null {
  const candidates: string[] = [];
  if (env.KNOCK_PLUGIN_DIR) candidates.push(env.KNOCK_PLUGIN_DIR);
  try {
    candidates.push(join(dirname(currentExecPath()), "claude-plugin"));
  } catch {
    // No real path for this binary: the other candidates remain.
  }
  const stable = stableKnockPathOrNull(env);
  if (stable) candidates.push(join(dirname(stable), "claude-plugin"));
  return candidates.find((dir) => existsSync(join(dir, ".claude-plugin", "marketplace.json"))) ?? null;
}

// The version in the bundled plugin's plugin.json, or null when unreadable.
export function bundledPluginVersion(dir: string): string | null {
  try {
    const manifest = JSON.parse(readFileSync(join(dir, "waggle", ".claude-plugin", "plugin.json"), "utf8"));
    return typeof manifest.version === "string" ? manifest.version : null;
  } catch {
    return null;
  }
}

function failure(label: string, result: RunResult): string {
  const detail = result.error ?? (result.stderr.trim() || result.stdout.trim());
  return `${label} failed${detail ? `: ${detail}` : ""}`;
}

// The launcher in the plugin's cache copy cannot see the bundle, so install records
// where this bundle's binary is. The launcher reads it before its usual search.
export function recordKnockPath(dir: string): void {
  try {
    mkdirSync(knockHome(), { recursive: true });
    writeFileSync(join(knockHome(), "knock-path"), `${join(dirname(dir), "waggle")}\n`);
  } catch {
    // The launcher still finds the app in /Applications or ~/Applications.
  }
}

export interface PluginInstallResult {
  ok: boolean;
  // Lines for stdout, and the error for stderr when not ok.
  lines: string[];
  error?: string;
}

// Installs or refreshes the bundled plugin. Idempotent: a second run changes nothing.
// With `refreshOnly` it acts only when the plugin is installed already (the app runs
// that at launch, after an update, and must not install for a user who removed it).
export function installBundledPlugin(dir: string, refreshOnly = false): PluginInstallResult {
  const lines: string[] = [];
  const bundledVersion = bundledPluginVersion(dir);
  let installed = knockPluginEntry(claudePluginList());
  // HAIL-176: an install made before the rename holds knock@knock. Refresh then moves it: the
  // waggle plugin goes in first, the old one comes out after, so a session never has none.
  const legacyInstalled = LEGACY_KNOCK_ALIASES ? knockPluginEntry(claudePluginList(), LEGACY_CLAUDE_PLUGIN_ID) : null;
  if (refreshOnly && !installed && !legacyInstalled) {
    return { ok: true, lines: ["Waggle plugin is not installed: nothing to refresh."] };
  }

  // Claude Code keeps a folder under the marketplace name it first read there: adding the same
  // folder again says "already on disk" (exit 0) and keeps the name knock (checked with the real
  // CLI, 5 Oct). An update replaces the files in place, so the old plugin no longer loads anyway:
  // take it out first, then add the folder as waggle.
  let legacyRemoved = false;
  if (legacyInstalled) {
    const legacyMarket = knockMarketplaceInList(claudeMarketplaceList(), LEGACY_CLAUDE_MARKETPLACE);
    if (legacyMarket?.path === dir) {
      lines.push(...removeLegacyPlugin());
      legacyRemoved = true;
    }
  }

  const market = knockMarketplaceInList(claudeMarketplaceList());
  let marketplaceChanged = false;
  if (!market) {
    let added = claudeMarketplaceAdd(dir);
    if (added.status !== 0 && legacyInstalled && !legacyRemoved) {
      // Claude Code may refuse a second marketplace on a directory the old knock marketplace
      // already reads. Remove the old plugin and marketplace, then add again.
      lines.push(...removeLegacyPlugin());
      added = claudeMarketplaceAdd(dir);
    }
    if (added.status !== 0) return { ok: false, lines, error: failure("claude plugin marketplace add", added) };
    marketplaceChanged = true;
    lines.push("Added the Waggle plugin marketplace.");
  } else if (market.path !== dir) {
    // A marketplace named knock that points elsewhere (an older app location, a repo
    // checkout): replace it with the bundled one.
    claudeMarketplaceRemove(MARKETPLACE);
    const added = claudeMarketplaceAdd(dir);
    if (added.status !== 0) return { ok: false, lines, error: failure("claude plugin marketplace add", added) };
    marketplaceChanged = true;
    installed = knockPluginEntry(claudePluginList());
    lines.push("Pointed the Waggle plugin marketplace at this app.");
  } else if (bundledVersion !== null && installed?.version !== bundledVersion) {
    // Same path, new files (an app update replaced them in place): refresh the catalog.
    claudeMarketplaceUpdate(MARKETPLACE);
  }

  if (!installed) {
    const result = claudePluginInstall(PLUGIN_ID);
    if (result.status !== 0) return { ok: false, lines, error: failure("claude plugin install", result) };
    lines.push("Installed the Waggle Claude Code plugin.");
  } else if (bundledVersion !== null && installed.version !== bundledVersion) {
    const result = claudePluginUpdate(PLUGIN_ID);
    if (result.status !== 0) return { ok: false, lines, error: failure("claude plugin update", result) };
    lines.push(`Updated the Waggle Claude Code plugin to ${bundledVersion}.`);
  } else if (!installed.enabled) {
    claudePluginEnable(PLUGIN_ID);
    lines.push("Enabled the Waggle Claude Code plugin.");
  } else if (!marketplaceChanged) {
    lines.push("Waggle Claude Code plugin already installed.");
  }

  recordKnockPath(dir);
  if (legacyInstalled && !legacyRemoved) lines.push(...removeLegacyPlugin());
  // One Waggle server per session: the plugin serves Waggle, so the old user entries go.
  if (isKnockRegisteredInGet(claudeMcpGet())) {
    claudeMcpRemove();
    lines.push("Removed the older Claude Code MCP server waggle: the plugin serves Waggle now.");
  }
  if (LEGACY_KNOCK_ALIASES && isKnockRegisteredInGet(claudeMcpGet(LEGACY_CLAUDE_SERVER_NAME), LEGACY_CLAUDE_SERVER_NAME)) {
    claudeMcpRemove(LEGACY_CLAUDE_SERVER_NAME);
    lines.push("Removed the older Claude Code MCP server knock: the plugin serves Waggle now.");
  }
  return { ok: true, lines };
}

// HAIL-176: removes the pre-rename plugin knock@knock and its marketplace. Idempotent: it reports
// only what it removed, so a second run says nothing.
export function removeLegacyPlugin(): string[] {
  const lines: string[] = [];
  if (knockPluginEntry(claudePluginList(), LEGACY_CLAUDE_PLUGIN_ID)) {
    claudePluginUninstall(LEGACY_CLAUDE_PLUGIN_ID);
    lines.push(`Moved the Claude Code plugin ${LEGACY_CLAUDE_PLUGIN_ID} to ${PLUGIN_ID}: removed the old one.`);
  }
  if (knockMarketplaceInList(claudeMarketplaceList(), LEGACY_CLAUDE_MARKETPLACE)) {
    claudeMarketplaceRemove(LEGACY_CLAUDE_MARKETPLACE);
    lines.push(`Removed the old Claude Code plugin marketplace ${LEGACY_CLAUDE_MARKETPLACE}.`);
  }
  return lines;
}

// Removes the plugin and its marketplace (and, with the aliases on, the old ones); reports what
// it removed.
export function uninstallPlugin(): string[] {
  const lines: string[] = [];
  if (knockPluginEntry(claudePluginList())) {
    claudePluginUninstall(PLUGIN_ID);
    lines.push(`Removed Claude Code plugin ${PLUGIN_ID}.`);
  }
  if (knockMarketplaceInList(claudeMarketplaceList())) {
    claudeMarketplaceRemove(MARKETPLACE);
    lines.push(`Removed Claude Code plugin marketplace ${MARKETPLACE}.`);
  }
  if (LEGACY_KNOCK_ALIASES) {
    if (knockPluginEntry(claudePluginList(), LEGACY_CLAUDE_PLUGIN_ID)) {
      claudePluginUninstall(LEGACY_CLAUDE_PLUGIN_ID);
      lines.push(`Removed Claude Code plugin ${LEGACY_CLAUDE_PLUGIN_ID}.`);
    }
    if (knockMarketplaceInList(claudeMarketplaceList(), LEGACY_CLAUDE_MARKETPLACE)) {
      claudeMarketplaceRemove(LEGACY_CLAUDE_MARKETPLACE);
      lines.push(`Removed Claude Code plugin marketplace ${LEGACY_CLAUDE_MARKETPLACE}.`);
    }
  }
  return lines;
}
