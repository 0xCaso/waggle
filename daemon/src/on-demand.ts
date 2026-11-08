import { spawn, type ChildProcess } from "node:child_process";
import { resolve } from "node:path";
import { stableKnockPathOrNull } from "./config";
import { DaemonConnectionError } from "./mcp/client";

// Starting `waggle daemon` on demand. The shim, the app and `waggle test-ask`
// call this when the socket is unreachable instead of relying on a LaunchAgent
// (docs/SERVICE.md).

export const ON_DEMAND_RETRY_MS = 3000;
const RETRY_STEP_MS = 100;

// The command that runs `waggle daemon` on demand (HAIL-27). It prefers the
// stable install path - the app bundle binary, then the `~/.local/bin/knock`
// symlink - so a shim or CLI that survived an update never respawns the binary
// Sparkle moved aside under ~/Library/Caches. `execPath` (this process's own
// binary) is used only when neither standard location exists: a source-checkout
// run, or a test with a temp HOME. `execPath` is a parameter so tests can pass
// a Sparkle cache path and prove it is rejected.
export function daemonCommand(
  env: NodeJS.ProcessEnv = process.env,
  execPath: string = process.execPath,
): { bin: string; args: string[] } {
  // A test or dev copy (its own KNOCK_HOME) never starts the operator's
  // installed binary: a LaunchServices launch drops HOME, so the stable lookup
  // would find the real ~/Applications/Waggle.app and run it against the test
  // data (seen 2026-09-27 in update-e2e). Such a copy starts its own binary,
  // unless KNOCK_STABLE_BIN names one explicitly.
  const stable = env.KNOCK_HOME && !env.KNOCK_STABLE_BIN ? null : stableKnockPathOrNull(env);
  if (stable !== null) return { bin: stable, args: ["daemon"] };
  // Source run (`bun src/index.ts`): the binary is the bun runtime and the
  // daemon is the entry script. Compiled (`bun build --compile`): the binary is
  // the knock binary itself.
  const script = process.argv[1];
  if (script && /\.[cm]?[jt]sx?$/.test(script)) {
    return { bin: execPath, args: [resolve(script), "daemon"] };
  }
  return { bin: execPath, args: ["daemon"] };
}

// Starts `waggle daemon` detached and ignores its stdio, so it outlives the
// caller. Safe to call when a daemon is already running: the extra process hits
// the single-instance guard (daemon.ts) and exits 3. Returns the child so
// tests can observe the single-instance race.
export function startDaemonOnDemand(env: NodeJS.ProcessEnv = process.env): ChildProcess {
  const { bin, args } = daemonCommand(env);
  const child = spawn(bin, args, { env, detached: true, stdio: "ignore" });
  child.unref();
  return child;
}

// Connects a client, starting the daemon on demand when the socket is
// unreachable and retrying for up to ON_DEMAND_RETRY_MS. Shared by the MCP
// shim and `waggle test-ask` so both use the same on-demand start and 3 s retry
// (docs/SERVICE.md, KNOCK-17).
export async function connectWithOnDemandStart(
  client: { connect: (socketPath: string) => Promise<void> },
  socketPath: string,
): Promise<void> {
  // Fast path: the daemon is already up.
  try {
    await client.connect(socketPath);
    return;
  } catch {
    // Socket unreachable: start the daemon, then retry below.
  }
  startDaemonOnDemand();
  const deadline = Date.now() + ON_DEMAND_RETRY_MS;
  for (;;) {
    await sleep(RETRY_STEP_MS);
    try {
      await client.connect(socketPath);
      return;
    } catch {
      if (Date.now() >= deadline) {
        throw new DaemonConnectionError(
          "waggle daemon did not become reachable within 3s",
        );
      }
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
