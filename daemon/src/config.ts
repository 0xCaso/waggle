import { existsSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { LEGACY_KNOCK_ALIASES } from "./protocol/legacy-aliases";

// The data root when KNOCK_HOME is not set. The app, the shim and the CLI all
// resolve the same default (docs/protocol-mvp.md "Components").
export const DEFAULT_KNOCK_HOME = join(
  homedir(),
  "Library",
  "Application Support",
  "Knock",
);

// Tests always set KNOCK_HOME to a temp dir; production never sets it.
export function knockHome(env: NodeJS.ProcessEnv = process.env): string {
  return env.KNOCK_HOME ?? DEFAULT_KNOCK_HOME;
}

export interface DaemonPaths {
  home: string;
  db: string;
  socket: string;
  blobs: string;
  bundles: string;
  logs: string;
}

export function daemonPaths(home: string = knockHome()): DaemonPaths {
  return {
    home,
    db: join(home, "knock.db"),
    socket: join(home, "knock.sock"),
    blobs: join(home, "blobs"),
    bundles: join(home, "bundles"),
    logs: join(home, "logs"),
  };
}

// Minutes with no connected shim, no app client and no queued reply before the
// daemon exits on its own (docs/SERVICE.md). 0 = never exit. Fractional minutes
// are allowed so tests can use a short window.
export function idleExitMinutes(env: NodeJS.ProcessEnv = process.env): number {
  const raw = env.KNOCK_IDLE_EXIT_MIN;
  if (raw === undefined || raw === "") return 30;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 0) return 30;
  return parsed;
}

// macOS limits a unix socket path to 103 bytes (sockaddr_un.sun_path[104]
// minus the NUL terminator). A longer path makes Bun.listen fail with a
// generic error, so waggle daemon and waggle doctor check this up front and print
// a specific message (KNOCK-17).
export const MAX_UNIX_SOCKET_PATH_BYTES = 103;

// The socket path's byte length when it is too long for a unix socket, else
// null.
export function unixSocketPathTooLongBytes(socketPath: string): number | null {
  const bytes = Buffer.byteLength(socketPath);
  return bytes > MAX_UNIX_SOCKET_PATH_BYTES ? bytes : null;
}

// The path `waggle install` registers for the MCP server. The pilot install is
// `~/Applications/Waggle.app/Contents/Resources/waggle` (INSTALL.md); the
// `~/.local/bin/waggle` symlink points at that same binary and survives an
// update the same way. Prefer the app path, then the symlink, so a build or
// worktree path is never registered; fall back to process.execPath only when
// Waggle is not installed at either standard location (a source-checkout run, or
// a test with a temp HOME).
export function stableKnockPath(
  env: NodeJS.ProcessEnv = process.env,
  execPath: string = process.execPath,
): string {
  return stableKnockPathOrNull(env) ?? execPath;
}

// HAIL-176: where the binary may sit, best first. A Sparkle update can leave the new bundle at the
// old `Knock.app` path, and an old bundle only has the `knock` binary, so both app names and both
// binary names are searched. The `knock` names go once LEGACY_KNOCK_ALIASES is gone.
export function stableBinaryCandidates(home: string): string[] {
  const apps = ["Waggle.app", "Knock.app"].map((app) => join(home, "Applications", app, "Contents", "Resources"));
  const links = join(home, ".local", "bin");
  return [
    ...apps.map((dir) => join(dir, "waggle")),
    join(links, "waggle"),
    ...(LEGACY_KNOCK_ALIASES ? [...apps.map((dir) => join(dir, "knock")), join(links, "knock")] : []),
  ];
}

// The stable install path, or null when Waggle is not installed at either
// standard location (a source-checkout run, or a test with a temp HOME).
// Distinct from stableKnockPath so a caller that needs a path to register
// (install) keeps its execPath fallback, while on-demand start falls back to a
// script-aware command instead (HAIL-27).
export function stableKnockPathOrNull(env: NodeJS.ProcessEnv = process.env): string | null {
  // An explicit stable binary wins (the update e2e points a surviving shim at
  // the updated bundle this way).
  const explicit = env.KNOCK_STABLE_BIN;
  if (explicit) return existsSync(explicit) ? explicit : null;
  const home = env.HOME ?? homedir();
  return stableBinaryCandidates(home).find((path) => existsSync(path)) ?? null;
}

// The realpath of this process's own binary. When compiled with `bun build
// --compile`, that is process.execPath (the knock binary). When run from source
// (`bun src/index.ts`), process.execPath is the bun runtime, so the entry
// script is the binary to report. service.status reports this so the app can
// compare it with its own bundled binary (HAIL-27).
export function currentExecPath(): string {
  const script = process.argv[1];
  if (script && /\.[cm]?[jt]sx?$/.test(script)) {
    return realpathSync(resolve(script));
  }
  return realpathSync(process.execPath);
}
