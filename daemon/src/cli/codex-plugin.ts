import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { currentExecPath, stableKnockPathOrNull } from "../config";
import { LEGACY_KNOCK_ALIASES } from "../protocol/legacy-aliases";
import { recordKnockPath } from "./claude-plugin";
import {
  CODEX_MARKETPLACE,
  CODEX_PLUGIN_ID,
  LEGACY_CODEX_MARKETPLACE,
  LEGACY_CODEX_PLUGIN_ID,
  codexKnockMarketplaceRoot,
  codexKnockPluginEntry,
  codexMarketplaceAdd,
  codexMarketplaceList,
  codexMarketplaceRemove,
  codexPluginAdd,
  codexPluginList,
  codexPluginRemove,
} from "./codex";
import type { RunResult } from "./exec";
import type { PluginInstallResult } from "./claude-plugin";

// HAIL-137: Waggle.app ships its Codex plugin as a local marketplace at
// Contents/Resources/codex-plugin (scripts/bundle-app.sh): `.agents/plugins/marketplace.json`
// plus the plugin in ./knock. `waggle install codex` points Codex at it.

// The bundled marketplace directory: KNOCK_CODEX_PLUGIN_DIR (tests, dev), else next to this
// binary, else next to the stable install path. Null when there is none.
export function bundledCodexPluginDir(env: NodeJS.ProcessEnv = process.env): string | null {
  const candidates: string[] = [];
  if (env.KNOCK_CODEX_PLUGIN_DIR) candidates.push(env.KNOCK_CODEX_PLUGIN_DIR);
  try {
    candidates.push(join(dirname(currentExecPath()), "codex-plugin"));
  } catch {
    // No real path for this binary: the other candidates remain.
  }
  const stable = stableKnockPathOrNull(env);
  if (stable) candidates.push(join(dirname(stable), "codex-plugin"));
  return candidates.find((dir) => existsSync(join(dir, ".agents", "plugins", "marketplace.json"))) ?? null;
}

// The version in the bundled plugin's plugin.json, or null when unreadable.
export function bundledCodexPluginVersion(dir: string): string | null {
  try {
    const manifest = JSON.parse(readFileSync(join(dir, "waggle", "plugin.json"), "utf8"));
    return typeof manifest.version === "string" ? manifest.version : null;
  } catch {
    return null;
  }
}

function failure(label: string, result: RunResult): string {
  const detail = result.error ?? (result.stderr.trim() || result.stdout.trim());
  return `${label} failed${detail ? `: ${detail}` : ""}`;
}

// Codex prints the resolved path (/private/tmp/...) where the bundle path may be a symlink.
function samePath(a: string | null, b: string): boolean {
  if (a === null) return false;
  const real = (p: string) => {
    try {
      return realpathSync(p);
    } catch {
      return p;
    }
  };
  return real(a) === real(b);
}

// Installs or refreshes the bundled plugin. Idempotent. With `refreshOnly` it acts only
// when the plugin is installed already (the app runs that at launch). Codex has no plugin
// `update` for a local marketplace: `codex plugin add` again replaces the cached copy.
export function installBundledCodexPlugin(dir: string, refreshOnly = false): PluginInstallResult {
  const lines: string[] = [];
  const bundledVersion = bundledCodexPluginVersion(dir);
  const installed = codexKnockPluginEntry(codexPluginList());
  // HAIL-176: an install made before the rename holds knock@knock; refresh moves it to waggle@waggle.
  const legacyInstalled = LEGACY_KNOCK_ALIASES
    ? codexKnockPluginEntry(codexPluginList(), LEGACY_CODEX_PLUGIN_ID)
    : null;
  if (refreshOnly && !installed && !legacyInstalled) {
    return { ok: true, lines: ["Waggle Codex plugin is not installed: nothing to refresh."] };
  }

  const market = codexKnockMarketplaceRoot(codexMarketplaceList());
  let changed = false;
  if (!market || !samePath(market.root, dir)) {
    if (market) codexMarketplaceRemove(CODEX_MARKETPLACE);
    const added = codexMarketplaceAdd(dir);
    if (added.status !== 0) return { ok: false, lines, error: failure("codex plugin marketplace add", added) };
    changed = true;
    lines.push(market ? "Pointed the Waggle Codex plugin marketplace at this app." : "Added the Waggle Codex plugin marketplace.");
  }

  const stale = installed !== null && bundledVersion !== null && installed.version !== bundledVersion;
  if (!installed || stale || changed) {
    const result = codexPluginAdd(CODEX_PLUGIN_ID);
    if (result.status !== 0) return { ok: false, lines, error: failure("codex plugin add", result) };
    lines.push(
      !installed
        ? "Installed the Waggle Codex plugin."
        : stale
          ? `Updated the Waggle Codex plugin to ${bundledVersion}.`
          : "Reinstalled the Waggle Codex plugin from this app.",
    );
  } else {
    lines.push("Waggle Codex plugin already installed.");
  }

  recordKnockPath(dir);
  if (legacyInstalled) lines.push(...removeLegacyCodexPlugin());
  // The plugin carries the skill and the hooks only. Waggle's MCP server stays the config.toml
  // entry: Codex documents plugin MCP servers as remote URLs and may skip a local stdio one, and
  // the entry is known to work (HAIL-137 fold).
  lines.push("Open /hooks in Codex once and trust the Waggle hooks: Codex skips plugin hooks until you do.");
  return { ok: true, lines };
}

// HAIL-176: removes the pre-rename plugin knock@knock and its marketplace. Idempotent.
export function removeLegacyCodexPlugin(): string[] {
  const lines: string[] = [];
  if (codexKnockPluginEntry(codexPluginList(), LEGACY_CODEX_PLUGIN_ID)) {
    codexPluginRemove(LEGACY_CODEX_PLUGIN_ID);
    lines.push(`Moved the Codex plugin ${LEGACY_CODEX_PLUGIN_ID} to ${CODEX_PLUGIN_ID}: removed the old one.`);
  }
  if (codexKnockMarketplaceRoot(codexMarketplaceList(), LEGACY_CODEX_MARKETPLACE)) {
    codexMarketplaceRemove(LEGACY_CODEX_MARKETPLACE);
    lines.push(`Removed the old Codex plugin marketplace ${LEGACY_CODEX_MARKETPLACE}.`);
  }
  return lines;
}

// Removes the plugin and its marketplace (and, with the aliases on, the old ones); reports what
// it removed.
export function uninstallCodexPlugin(): string[] {
  const lines: string[] = [];
  if (LEGACY_KNOCK_ALIASES) lines.push(...removeLegacyCodexPlugin());
  if (codexKnockPluginEntry(codexPluginList())) {
    codexPluginRemove(CODEX_PLUGIN_ID);
    lines.push(`Removed Codex plugin ${CODEX_PLUGIN_ID}.`);
  }
  if (codexKnockMarketplaceRoot(codexMarketplaceList())) {
    codexMarketplaceRemove(CODEX_MARKETPLACE);
    lines.push(`Removed Codex plugin marketplace ${CODEX_MARKETPLACE}.`);
  }
  return lines;
}
