import { createInterface } from "node:readline";
import { chmodSync, lstatSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { knockHome } from "../config";
import { LEGACY_KNOCK_ALIASES } from "../protocol/legacy-aliases";
import { removeLegacyLaunchAgent, SERVICE_LABEL } from "../service";
import {
  LEGACY_CLAUDE_SERVER_NAME,
  claudeMcpGet,
  claudeMcpRemove,
  claudePluginsSupported,
  isKnockRegisteredInGet,
} from "./claude";
import { uninstallPlugin } from "./claude-plugin";
import {
  LEGACY_CODEX_SERVER_NAME,
  codexMcpList,
  codexMcpRemove,
  codexPluginsSupported,
  isCodexRegistered,
} from "./codex";
import { uninstallCodexPlugin } from "./codex-plugin";

// `waggle uninstall [--purge] [--yes]`: removes the MCP registration from every
// runtime where it exists, plus any legacy LaunchAgent (current or pre-rename
// label), and with --purge deletes $KNOCK_HOME after a y/N prompt (--yes skips
// the prompt). Prints one line per thing it removed. Returns 0 on success, 2
// for unknown arguments.
export async function runUninstall(args: string[]): Promise<number> {
  let purge = false;
  let yes = false;
  for (const arg of args) {
    if (arg === "--purge") purge = true;
    else if (arg === "--yes") yes = true;
    else {
      process.stderr.write(`waggle uninstall: unknown argument: ${arg}\n`);
      return 2;
    }
  }

  const out = process.stdout;

  if (isKnockRegisteredInGet(claudeMcpGet())) {
    claudeMcpRemove();
    out.write("Removed Claude Code MCP server waggle.\n");
  } else {
    out.write("Claude Code MCP server waggle was not registered.\n");
  }
  // HAIL-176: an entry made before the rename.
  if (LEGACY_KNOCK_ALIASES && isKnockRegisteredInGet(claudeMcpGet(LEGACY_CLAUDE_SERVER_NAME), LEGACY_CLAUDE_SERVER_NAME)) {
    claudeMcpRemove(LEGACY_CLAUDE_SERVER_NAME);
    out.write("Removed Claude Code MCP server knock.\n");
  }

  // HAIL-135: the plugin and its marketplace go too (a Claude Code without plugin
  // support has neither).
  if (claudePluginsSupported()) {
    for (const line of uninstallPlugin()) out.write(`${line}\n`);
  }

  // HAIL-137: the Codex plugin and its marketplace go too.
  if (codexPluginsSupported()) {
    for (const line of uninstallCodexPlugin()) out.write(`${line}\n`);
  }

  const codexList = codexMcpList().stdout;
  if (isCodexRegistered(codexList)) {
    codexMcpRemove();
    out.write("Removed Codex MCP server waggle.\n");
  } else {
    out.write("Codex MCP server waggle was not registered.\n");
  }
  if (LEGACY_KNOCK_ALIASES && isCodexRegistered(codexList, LEGACY_CODEX_SERVER_NAME)) {
    codexMcpRemove(LEGACY_CODEX_SERVER_NAME);
    out.write("Removed Codex MCP server knock.\n");
  }

  const removed = removeLegacyLaunchAgent();
  if (removed.length > 0) {
    for (const label of removed) out.write(`Removed legacy ${label} LaunchAgent.\n`);
  } else {
    out.write(`${SERVICE_LABEL} was not installed.\n`);
  }

  if (purge) {
    const home = knockHome();
    if (yes || (await confirm(`Delete ${home} and all Waggle data? [y/N] `))) {
      removeTree(home);
      out.write(`Deleted ${home}.\n`);
    } else {
      out.write(`Kept ${home}.\n`);
    }
  }
  return 0;
}

// Removes a tree even when a staged artifact made it read-only (chmod a-w).
// `rmSync(recursive, force)` alone fails with EACCES on a read-only directory
// (a staged html_bundle or screenshot is read-only per docs/protocol-mvp.md
// "Artifacts"), so restore every write bit first, deepest first (KNOCK-17:
// `waggle uninstall --purge` must still delete the data root after an HTML
// review).
function removeTree(path: string): void {
  try {
    const st = lstatSync(path);
    if (st.isDirectory()) {
      for (const name of readdirSync(path)) {
        removeTree(join(path, name));
      }
    }
    chmodSync(path, st.mode | 0o222);
  } catch {
    // Missing entry: nothing to remove.
  }
  try {
    rmSync(path, { recursive: true, force: true });
  } catch {
    // Already gone.
  }
}

// Asks one y/N question on stdout and reads one line from stdin. A leading
// "y" (case-insensitive) answers yes; anything else answers no.
function confirm(question: string): Promise<boolean> {
  const rl = createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false,
  });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(/^y/i.test(answer.trim()));
    });
  });
}
