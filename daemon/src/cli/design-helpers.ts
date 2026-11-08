import { run, type RunResult } from "./exec";

// HAIL-239: "Design helpers" in Settings > Agents. It adds the optional Impeccable plugin
// (https://github.com/pbakaus/impeccable, Apache 2.0) to Claude Code, and removes it again.
// Nothing here runs unless the person clicks: the app calls `waggle design-helpers add|remove`.
// The claude CLI does the download. The daemon makes no network call of its own.
export const IMPECCABLE_SOURCE = "pbakaus/impeccable";
export const IMPECCABLE_MARKETPLACE = "impeccable";
export const IMPECCABLE_PLUGIN_ID = "impeccable@impeccable";

// A marketplace add clones a repository, so it needs far more than the 15 s default.
const NETWORK_TIMEOUT_MS = 180_000;

const claude = (args: string[], timeoutMs?: number): RunResult => run("claude", args, timeoutMs);

// True when `claude plugin list --json` shows the plugin, whatever its marketplace name or state.
export function impeccableInstalled(result: RunResult): boolean {
  if (result.status !== 0) return false;
  try {
    const list = JSON.parse(result.stdout) as unknown;
    return Array.isArray(list) && list.some((p) => p?.id === IMPECCABLE_PLUGIN_ID);
  } catch {
    return false;
  }
}

function marketplaceKnown(result: RunResult): boolean {
  if (result.status !== 0) return false;
  try {
    const list = JSON.parse(result.stdout) as unknown;
    return Array.isArray(list) && list.some((m) => m?.name === IMPECCABLE_MARKETPLACE);
  } catch {
    return false;
  }
}

function failure(label: string, result: RunResult): string {
  const detail = result.error ?? (result.stderr.trim() || result.stdout.trim());
  return `${label} failed${detail ? `: ${detail}` : ""}`;
}

// `waggle design-helpers status|add|remove`. status prints "installed" or "not installed" and
// exits 0 when it could tell. add and remove are idempotent. Exit 1 on a failed claude call.
export function runDesignHelpers(args: string[]): number {
  const verb = args[0];
  const out = process.stdout;
  const err = process.stderr;
  if (args.length !== 1 || (verb !== "status" && verb !== "add" && verb !== "remove")) {
    err.write("waggle design-helpers: expected status, add or remove\n");
    return 2;
  }
  if (run("claude", ["plugin", "--help"]).status !== 0) {
    err.write("waggle design-helpers: Claude Code with plugin support was not found on PATH\n");
    return 1;
  }
  const listed = claude(["plugin", "list", "--json"]);
  if (verb === "status") {
    if (listed.status !== 0) {
      err.write(`waggle design-helpers: ${failure("claude plugin list", listed)}\n`);
      return 1;
    }
    out.write(impeccableInstalled(listed) ? "installed\n" : "not installed\n");
    return 0;
  }
  const installed = impeccableInstalled(listed);

  if (verb === "add") {
    if (installed) {
      out.write("Impeccable is already installed.\n");
      return 0;
    }
    if (!marketplaceKnown(claude(["plugin", "marketplace", "list", "--json"]))) {
      const added = claude(["plugin", "marketplace", "add", IMPECCABLE_SOURCE, "--scope", "user"], NETWORK_TIMEOUT_MS);
      if (added.status !== 0) {
        err.write(`waggle design-helpers: ${failure("claude plugin marketplace add", added)}\n`);
        return 1;
      }
    }
    const result = claude(["plugin", "install", IMPECCABLE_PLUGIN_ID, "--scope", "user"], NETWORK_TIMEOUT_MS);
    if (result.status !== 0) {
      err.write(`waggle design-helpers: ${failure("claude plugin install", result)}\n`);
      return 1;
    }
    out.write("Installed Impeccable.\n");
    return 0;
  }

  if (installed) {
    const result = claude(["plugin", "uninstall", IMPECCABLE_PLUGIN_ID, "--scope", "user"]);
    if (result.status !== 0) {
      err.write(`waggle design-helpers: ${failure("claude plugin uninstall", result)}\n`);
      return 1;
    }
    out.write("Removed Impeccable.\n");
  }
  if (marketplaceKnown(claude(["plugin", "marketplace", "list", "--json"]))) {
    claude(["plugin", "marketplace", "remove", IMPECCABLE_MARKETPLACE]);
  }
  return 0;
}
