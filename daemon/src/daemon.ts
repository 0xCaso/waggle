import { linkSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import pkg from "../package.json" with { type: "json" };
import { daemonPaths, idleExitMinutes, MAX_UNIX_SOCKET_PATH_BYTES, unixSocketPathTooLongBytes } from "./config";
import { ConnectorManager } from "./connectors/manager";
import { connectorConfig } from "./connectors/overrides";
import { RelaySharing, SHARING_AVAILABLE } from "./connectors/relay";
import { SlackConnector } from "./connectors/slack";
import { TelegramConnector } from "./connectors/telegram";
import { EventBus } from "./events";
import { startRpcServer } from "./server";
import { pidAlive } from "./sessions";
import { APPLY_WAIT_MS, Store } from "./store";
import { UsageLogger } from "./usage";
import { USAGE_RETENTION_DAYS } from "./usage/tools";

// How often the daemon checks whether it has been idle long enough to exit.
const IDLE_CHECK_MS = 250;
// How often the daemon ends sessions whose client pid is gone (HAIL-178).
const SESSION_REAP_MS = 15_000;

// Run `waggle daemon`. Returns an exit code; the daemon stays alive until it gets
// SIGINT, SIGTERM, or it idles out (see idleExitMinutes). A second daemon on
// the same KNOCK_HOME exits 3.
export async function runDaemon(args: string[]): Promise<number> {
  const paths = daemonPaths();
  const tooLong = unixSocketPathTooLongBytes(paths.socket);
  if (tooLong !== null) {
    process.stderr.write(
      `KNOCK_HOME path is too long for a unix socket (${tooLong} bytes, max ${MAX_UNIX_SOCKET_PATH_BYTES})\n`,
    );
    return 3;
  }
  mkdirSync(paths.home, { recursive: true, mode: 0o700 });
  mkdirSync(paths.logs, { recursive: true, mode: 0o700 });

  const lockPath = join(paths.home, "knock.lock");

  // Single instance. An atomic lock file (created with link) closes the race
  // where two on-demand starts both unlink and rebind the same socket: exactly
  // one daemon owns the lock, and a crashed run leaves a stale lock the next
  // start recovers.
  if (!acquireSingleInstanceLock(lockPath)) {
    process.stderr.write(
      `waggle daemon: another daemon is already running for ${paths.home}\n`,
    );
    return 3;
  }

  // Remove a stale socket left by a killed run before we bind. Safe now that we
  // hold the single-instance lock: no other daemon is binding concurrently.
  try {
    unlinkSync(paths.socket);
  } catch {
    // Not there: fine.
  }

  const db = new Database(paths.db);
  const bus = new EventBus();
  const usage = new UsageLogger(db, paths.home);
  const store = new Store(db, paths.home, bus, usage);

  // Usage retention (KNOCK-19, HAIL-195): hourly events and tool calls older than
  // USAGE_RETENTION_DAYS are deleted at start and once a day while the daemon lives. A failed
  // delete is logged by the UsageLogger and ignored; it never stops the daemon.
  const pruneUsage = (): void => {
    usage.deleteOlderThan(USAGE_RETENTION_DAYS);
    usage.tools.deleteOlderThan(USAGE_RETENTION_DAYS);
  };
  pruneUsage();
  const retentionTimer = setInterval(pruneUsage, 86_400_000);

  // HAIL-178: a shim can outlive its client and keep heartbeating, so the daemon also checks the
  // recorded client pid of every live session on a timer and ends the ones whose client is gone.
  store.endDeadSessions(pidAlive);
  const reapTimer = setInterval(() => store.endDeadSessions(pidAlive), SESSION_REAP_MS);

  // WAG-267: a delivered reply with no visible work after APPLY_WAIT_MS is "not applied yet".
  const sweepApplied = (): void => {
    store.markRepliesNotApplied({ olderThanMs: APPLY_WAIT_MS });
  };
  sweepApplied();
  const applySweepTimer = setInterval(sweepApplied, 60_000);

  // service.restart asks the daemon to exit cleanly. The stop function is
  // assigned below, inside the run promise; the restart RPC only fires after
  // the server is up, so the closure always sees the real stop by then.
  let stopDaemon: (code: number) => void = () => {};

  // Chat connectors (HAIL-144, HAIL-145): off until the operator connects one. With none connected
  // they make no network call. Only a dev build reads the fake-service env variables (HAIL-148);
  // the release daemon always talks to the real hosts and the real Keychain.
  const cc = connectorConfig();
  const connectors = new ConnectorManager(store, bus, []);
  connectors.add(
    new TelegramConnector({ store, secrets: cc.secrets, host: connectors, baseUrl: cc.telegramBaseUrl }),
  );
  connectors.add(
    new SlackConnector({
      store,
      secrets: cc.secrets,
      host: connectors,
      baseUrl: cc.slackBaseUrl,
      ...(cc.slackSocketUrl ? { socketUrl: cc.slackSocketUrl } : {}),
    }),
  );
  // Sharing a case (WAG-387): off until the operator turns Sharing on. The relay is the only host.
  // SHARING_AVAILABLE hides the whole feature (operator decision 8 Nov).
  const relay = new RelaySharing({ store, bus, secrets: cc.secrets, baseUrl: cc.relayBaseUrl, available: SHARING_AVAILABLE });

  let server: ReturnType<typeof startRpcServer>;
  try {
    server = startRpcServer({
      socketPath: paths.socket,
      store,
      bus,
      version: pkg.version,
      onRestart: () => stopDaemon(0),
      connectors,
      relay,
    });
  } catch (err) {
    db.close();
    try {
      unlinkSync(lockPath);
    } catch {
      // Already gone.
    }
    process.stderr.write(
      `waggle daemon: cannot listen on ${paths.socket}: ${(err as Error).message}\n`,
    );
    return 3;
  }

  process.stdout.write(`waggle daemon: listening on ${paths.socket}\n`);
  connectors.start();
  relay.start();

  const idleMinutes = idleExitMinutes();
  let idleTimer: ReturnType<typeof setInterval> | null = null;
  let idleSince: number | null = null;

  return new Promise<number>((resolve) => {
    let stopped = false;
    const stop = (code: number) => {
      if (stopped) return;
      stopped = true;
      if (idleTimer !== null) clearInterval(idleTimer);
      clearInterval(retentionTimer);
      clearInterval(reapTimer);
      clearInterval(applySweepTimer);
      connectors.stop();
      relay.stop();
      try {
        server.stop();
      } catch {
        // Already stopped.
      }
      try {
        unlinkSync(paths.socket);
      } catch {
        // Already gone.
      }
      try {
        unlinkSync(lockPath);
      } catch {
        // Already gone.
      }
      db.close();
      resolve(code);
    };
    stopDaemon = stop;

    // Idle exit: only when no socket is open (shim or app), no reply is
    // queued, and no chat connector is on with an ask still open (a phone reply
    // would have nowhere to go). Queued replies and cases persist in the DB across the exit.
    if (idleMinutes > 0) {
      idleTimer = setInterval(() => {
        const idle = server.openConnections() === 0 && store.countQueuedReplies() === 0 && !connectors.keepAlive() && !relay.keepAlive(server.openConnections() > 0);
        if (idle) {
          if (idleSince === null) idleSince = Date.now();
          else if (Date.now() - idleSince >= idleMinutes * 60_000) stop(0);
        } else {
          idleSince = null;
        }
      }, IDLE_CHECK_MS);
    }

    process.once("SIGINT", () => stop(0));
    process.once("SIGTERM", () => stop(0));
  });
}

// Acquires the single-instance lock by atomically linking a pid file into
// place. Returns false when another live daemon owns it. A stale lock (owner
// pid dead, for example after a SIGKILL) is removed and retried once; the retry
// is atomic, so exactly one of several racing starts wins.
function acquireSingleInstanceLock(lockPath: string): boolean {
  if (tryLock(lockPath)) return true;

  const owner = readPid(lockPath);
  if (owner !== null && pidAlive(owner)) return false;

  try {
    unlinkSync(lockPath);
  } catch {
    // Already gone.
  }
  return tryLock(lockPath);
}

// One atomic attempt: write our pid to a unique temp file, then hard-link it to
// the lock path. link fails with EEXIST when the lock is already there.
function tryLock(lockPath: string): boolean {
  const tmp = `${lockPath}.${process.pid}`;
  writeFileSync(tmp, String(process.pid));
  try {
    linkSync(tmp, lockPath);
    return true;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
    return false;
  } finally {
    try {
      unlinkSync(tmp);
    } catch {
      // Already gone.
    }
  }
}

function readPid(lockPath: string): number | null {
  try {
    const parsed = Number(readFileSync(lockPath, "utf8").trim());
    return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
  } catch {
    return null;
  }
}
