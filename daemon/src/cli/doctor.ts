import { existsSync } from "node:fs";
import pkg from "../../package.json" with { type: "json" };
import { currentExecPath, daemonPaths, MAX_UNIX_SOCKET_PATH_BYTES, unixSocketPathTooLongBytes } from "../config";
import { DaemonClient } from "../mcp/client";
import { AGENT_INSTRUCTIONS_VERSION } from "../protocol";
import { LEGACY_KNOCK_ALIASES } from "../protocol/legacy-aliases";
import type { ServiceStatus, SessionInfo } from "../protocol";
import {
  claudeMarketplaceListAsync,
  claudeMcpGetAsync,
  claudePluginListAsync,
  claudePluginsSupportedAsync,
  claudeVersionAsync,
  isKnockPluginInList,
  isKnockRegisteredInGet,
  LEGACY_CLAUDE_SERVER_NAME,
  knockMarketplaceInList,
  knockPluginEntry,
  registeredKnockPathFromGet,
} from "./claude";
import { bundledPluginDir, bundledPluginVersion } from "./claude-plugin";
import {
  LEGACY_CODEX_PLUGIN_ID,
  LEGACY_CODEX_SERVER_NAME,
  codexKnockMarketplaceRoot,
  codexKnockPluginEntry,
  codexMarketplaceListAsync,
  codexMcpListAsync,
  codexPluginListAsync,
  codexPluginsSupportedAsync,
  codexVersionAsync,
  isCodexRegistered,
  registeredCodexKnockPath,
} from "./codex";
import { bundledCodexPluginDir, bundledCodexPluginVersion } from "./codex-plugin";

// `waggle doctor`: the version first, then one line per check, ok/fail/skip plus
// the fix (docs/protocol-mvp.md "Components"). A runtime that is not found on
// PATH is "skip", not "fail" — neither runtime is required (KNOCK-20). A
// warning does not fail the run. Exit 0 when at least one runtime is found
// and registered, and the service is reachable or startable on demand
// (always true here; see below).
//
// The old "service running (launchd)" check is gone: the service starts on
// demand (docs/SERVICE.md), so "reachable, or startable on demand" is always
// true while this binary can run the daemon.
export async function runDoctor(): Promise<number> {
  process.stdout.write(`waggle ${pkg.version}\n`);
  const { checks, warnings } = await collectChecks();
  for (const check of checks) {
    process.stdout.write(`${statusWord(check.status)}${formatRest(check)}\n`);
  }
  for (const warning of warnings) {
    process.stdout.write(`warn  ${warning}\n`);
  }
  const serviceStartable = checks.some(
    (check) => check.label === "service reachable, or startable on demand" && check.status === "ok",
  );
  const anyRuntimeConnected = checks.some(
    (check) => check.label.endsWith("MCP server registered") && check.status === "ok",
  );
  return serviceStartable && anyRuntimeConnected ? 0 : 1;
}

type CheckStatus = "ok" | "fail" | "skip";

interface Check {
  label: string;
  status: CheckStatus;
  fix: string;
}

interface RuntimeAdapter {
  id: "claude" | "codex";
  label: string;
  found(): Promise<boolean>;
  // Fetches the runtime's own `mcp list` stdout once, so the registration
  // check and the registered-path warning (below) share one exec call
  // instead of each spawning it separately — a second, sequential spawn per
  // runtime here would add the ~1s the fake binaries sleep in cli-install.test.ts
  // back onto the wall clock, undoing the pass-2 concurrency fix.
  listStdout(): Promise<string>;
  isRegistered(stdout: string): boolean;
  registeredPath(stdout: string): string | null;
  // HAIL-134: true when Waggle reaches this runtime as a plugin instead of an MCP entry.
  plugin?(): Promise<boolean>;
  // HAIL-135: extra plugin lines (marketplace path, version) once the plugin is installed.
  pluginChecks?(): Promise<{ checks: Check[]; warnings: string[] }>;
  // HAIL-136: true when this runtime supports plugins and the app bundles one, so the
  // app can offer it to a user connected through the MCP entry.
  pluginCapable?(): Promise<boolean>;
}

// HAIL-135: which marketplace the plugin came from, and whether the bundled copy is newer.
// A marketplace path that no longer exists means the app moved: the plugin keeps
// working from Claude Code's cache, but it cannot update until install runs again.
async function pluginDetails(): Promise<{ checks: Check[]; warnings: string[] }> {
  const checks: Check[] = [];
  const warnings: string[] = [];
  const [market, list] = await Promise.all([claudeMarketplaceListAsync(), claudePluginListAsync()]);
  const entry = knockMarketplaceInList(market);
  if (entry?.path && !existsSync(entry.path)) {
    checks.push({
      label: `Claude Code plugin marketplace path missing: ${entry.path} (the app moved?)`,
      status: "fail",
      fix: "waggle install claude",
    });
  }
  const dir = bundledPluginDir();
  const bundled = dir ? bundledPluginVersion(dir) : null;
  const installed = knockPluginEntry(list)?.version ?? null;
  if (bundled && installed && bundled !== installed) {
    warnings.push(`installed Waggle plugin ${installed} differs from this app's ${bundled} (fix: waggle install claude)`);
  }
  return { checks, warnings };
}

// HAIL-137: the same for the Codex plugin. Its hooks need the user's trust in Codex (`/hooks`),
// which Waggle cannot read, so doctor always says so.
async function codexPluginDetails(): Promise<{ checks: Check[]; warnings: string[] }> {
  const checks: Check[] = [];
  const warnings: string[] = [];
  const [market, list] = await Promise.all([codexMarketplaceListAsync(), codexPluginListAsync()]);
  const root = codexKnockMarketplaceRoot(market)?.root ?? null;
  if (root && !existsSync(root)) {
    checks.push({
      label: `Codex plugin marketplace path missing: ${root} (the app moved?)`,
      status: "fail",
      fix: "waggle install codex",
    });
  }
  const dir = bundledCodexPluginDir();
  const bundled = dir ? bundledCodexPluginVersion(dir) : null;
  const installed = codexKnockPluginEntry(list)?.version ?? null;
  if (bundled && installed && bundled !== installed) {
    warnings.push(`installed Waggle Codex plugin ${installed} differs from this app's ${bundled} (fix: waggle install codex)`);
  }
  warnings.push("Codex skips the Waggle plugin hooks until you trust them: open /hooks in Codex");
  return { checks, warnings };
}

// `found`/`listStdout` each shell out (`claude --version`, `claude mcp list`,
// ...); `claude mcp list`/`codex mcp list` probe every configured MCP
// server's live connectivity and can take several seconds on their own (see
// the "Always" note this story carries: "waggle doctor takes about 8s because
// claude mcp list checks every server"). The two runtimes' adapters below run
// through `collectChecks`'s `Promise.all`, so Claude Code's and Codex's own
// exec calls overlap on the wire instead of queueing behind each other —
// KNOCK-20 fold pass 2 traced the M1 window's "stuck on Checking..." bug to
// this queueing (worst case, four sequential exec calls) compounding with no
// timeout on any one of them (fixed separately in exec.ts's `DEFAULT_TIMEOUT_MS`).
const RUNTIMES: RuntimeAdapter[] = [
  {
    id: "claude",
    label: "Claude Code",
    found: async () => (await claudeVersionAsync()).status === 0,
    // `claude mcp get knock`, not `claude mcp list`: list health-checks every
    // configured server and ran past the exec timeout on a Mac with many of
    // them (friend report 29 Sep). The status line keeps get's exit code.
    listStdout: async () => {
      const get = await claudeMcpGetAsync();
      if (isKnockRegisteredInGet(get)) return get.stdout;
      // HAIL-176: an entry made before the rename is still named knock until the app moves it.
      if (!LEGACY_KNOCK_ALIASES) return "";
      const legacy = await claudeMcpGetAsync(LEGACY_CLAUDE_SERVER_NAME);
      return isKnockRegisteredInGet(legacy, LEGACY_CLAUDE_SERVER_NAME) ? legacy.stdout : "";
    },
    isRegistered: (stdout) => /^(waggle|knock)\s*:\s*$/m.test(stdout),
    registeredPath: registeredKnockPathFromGet,
    plugin: async () => isKnockPluginInList(await claudePluginListAsync()),
    pluginChecks: pluginDetails,
    pluginCapable: async () => bundledPluginDir() !== null && (await claudePluginsSupportedAsync()),
  },
  {
    id: "codex",
    label: "Codex",
    found: async () => (await codexVersionAsync()).status === 0,
    listStdout: async () => (await codexMcpListAsync()).stdout,
    isRegistered: (stdout) =>
      isCodexRegistered(stdout) || (LEGACY_KNOCK_ALIASES && isCodexRegistered(stdout, LEGACY_CODEX_SERVER_NAME)),
    registeredPath: (stdout) =>
      registeredCodexKnockPath(stdout) ??
      (LEGACY_KNOCK_ALIASES ? registeredCodexKnockPath(stdout, LEGACY_CODEX_SERVER_NAME) : null),
    plugin: async () => {
      const list = await codexPluginListAsync();
      return (
        codexKnockPluginEntry(list) !== null ||
        (LEGACY_KNOCK_ALIASES && codexKnockPluginEntry(list, LEGACY_CODEX_PLUGIN_ID) !== null)
      );
    },
    pluginChecks: codexPluginDetails,
    pluginCapable: async () => bundledCodexPluginDir() !== null && (await codexPluginsSupportedAsync()),
  },
];

async function collectChecksForRuntime(runtime: RuntimeAdapter): Promise<{ checks: Check[]; warnings: string[] }> {
  const found = await runtime.found();
  const checks: Check[] = [
    { label: `${runtime.id} found`, status: found ? "ok" : "skip", fix: `install ${runtime.label}` },
  ];
  if (!found) {
    checks.push({
      label: `${runtime.label} MCP server registered`,
      status: "skip",
      fix: `install ${runtime.label} first`,
    });
    return { checks, warnings: [] };
  }
  const [listStdout, viaPlugin] = await Promise.all([runtime.listStdout(), runtime.plugin?.() ?? false]);
  const pluginWarnings: string[] = [];
  const entry = runtime.isRegistered(listStdout);
  // The plugin's own MCP server counts as registered (HAIL-134).
  const registered = entry || viaPlugin;
  checks.push({
    label: `${runtime.label} MCP server registered`,
    status: registered ? "ok" : "fail",
    fix: `waggle install ${runtime.id}`,
  });
  if (viaPlugin) {
    checks.push({ label: `${runtime.label} installed as plugin`, status: "ok", fix: "" });
    const details = await runtime.pluginChecks?.();
    if (details) {
      checks.push(...details.checks);
      pluginWarnings.push(...details.warnings);
    }
    // Two servers for one session: the plugin's and the one `waggle install` made.
    if (entry) {
      checks.push({
        label: `${runtime.label} runs Waggle twice (the plugin and an older MCP entry)`,
        status: "fail",
        fix: `waggle install ${runtime.id}`,
      });
    }
  }
  // A warning does not fail the run. The MCP registration must point at a path
  // that survives an update (INSTALL.md, KNOCK-21); warn when the registered
  // path is missing so the update does not leave a dangling registration
  // silently. Checked for both runtimes (KNOCK-20 fold pass 4: merge with
  // KNOCK-21).
  const warnings: string[] = [...pluginWarnings];
  if (await runtime.pluginCapable?.()) {
    checks.push({ label: `${runtime.label} can install the Waggle plugin`, status: "ok", fix: "" });
  }
  if (entry && !viaPlugin) {
    checks.push({ label: `${runtime.label} installed as MCP entry`, status: "ok", fix: "" });
  }
  if (entry) {
    const path = runtime.registeredPath(listStdout);
    if (path !== null && !existsSync(path)) warnings.push(`registered MCP path missing: ${path}`);
  }
  return { checks, warnings };
}

async function collectChecks(): Promise<{ checks: Check[]; warnings: string[] }> {
  const serviceCheck = serviceReachableCheck();
  const daemon = await daemonStatusCheck();
  // `Promise.all` starts every runtime's chain at once (real concurrency,
  // since each `found`/`listStdout` call is a non-blocking `spawn`, not
  // `spawnSync`) but still resolves in `RUNTIMES` order, so the printed
  // output stays deterministic: service, then the running daemon, then
  // claude's two lines, then codex's two lines, exactly as before.
  const perRuntime = await Promise.all(RUNTIMES.map(collectChecksForRuntime));
  return {
    checks: [serviceCheck, agentInstructionsCheck(), ...daemon.checks, ...perRuntime.flatMap((r) => r.checks)],
    warnings: [...daemon.warnings, ...perRuntime.flatMap((r) => r.warnings)],
  };
}

// HAIL-30: the shim serves agent instructions on initialize; report the
// version so a tester can see which text their installed build carries.
// Always ok - the constant ships with this binary.
function agentInstructionsCheck(): Check {
  return { label: `agent instructions v${AGENT_INSTRUCTIONS_VERSION}`, status: "ok", fix: "" };
}

// The service check is "ok" when the daemon can start on demand, and "fail"
// with the specific message when the socket path is too long for macOS to bind
// (KNOCK-17). Every other case is startable: the binary is right here.
function serviceReachableCheck(): Check {
  const tooLong = unixSocketPathTooLongBytes(daemonPaths().socket);
  if (tooLong !== null) {
    return {
      label: "service reachable, or startable on demand",
      status: "fail",
      fix: `KNOCK_HOME path is too long for a unix socket (${tooLong} bytes, max ${MAX_UNIX_SOCKET_PATH_BYTES})`,
    };
  }
  return { label: "service reachable, or startable on demand", status: "ok", fix: "" };
}

// Reports the running daemon's version and exec path, and warns when either
// differs from this CLI's (HAIL-27); also the "sessions" section (HAIL-46):
// one ok line per connected session, or a warning when none is connected.
// Best effort: a daemon that is not running yields no check and no warning -
// the "startable on demand" check above covers that case, and with no daemon
// reachable there is no way to know whether a session is connected either.
// The read is a plain connect, never an on-demand start.
async function daemonStatusCheck(): Promise<{ checks: Check[]; warnings: string[] }> {
  const state = await readDaemonState();
  if (state === null) return { checks: [], warnings: [] };
  const { status, sessions } = state;
  const warnings: string[] = [];
  if (status.version !== pkg.version) {
    warnings.push(`running daemon version ${status.version} differs from this CLI (${pkg.version})`);
  }
  const ownPath = currentExecPath();
  if (status.exec_path !== ownPath) {
    warnings.push(`running daemon path ${status.exec_path} differs from this CLI (${ownPath})`);
  }
  const checks: Check[] = [
    { label: `running daemon ${status.version} at ${status.exec_path}`, status: "ok", fix: "" },
  ];
  const live = sessions.filter((session) => session.state === "live");
  if (live.length === 0) {
    warnings.push(NO_SESSION_WARNING);
  } else {
    const now = new Date();
    for (const session of live) checks.push(sessionCheck(session, now));
  }
  return { checks, warnings };
}

// Reads service.status and sessions.list over the same connection, without
// starting the daemon on demand.
async function readDaemonState(): Promise<{ status: ServiceStatus; sessions: SessionInfo[] } | null> {
  const client = new DaemonClient();
  try {
    await client.connect(daemonPaths().socket);
    const status = (await client.call("service.status", {}, 5000)) as ServiceStatus;
    const sessions = (await client.call("sessions.list", {}, 5000)) as SessionInfo[];
    return { status, sessions };
  } catch {
    return null;
  } finally {
    client.close();
  }
}

const NO_SESSION_WARNING =
  "no agent session connected: start Claude Code, or run /mcp → waggle → Reconnect";

// One "sessions" line (HAIL-46 doctor contract): "<Runtime> · <project>[ ·
// <branch>] · connected <duration>", e.g. "Claude Code · knock · main ·
// connected 2h". `RUNTIME_LABELS` reuses the same human names `RUNTIMES`
// already carries, so a second connector's label never drifts from doctor's
// own "found"/"registered" lines for it.
const RUNTIME_LABELS: Record<string, string> = Object.fromEntries(
  RUNTIMES.map((runtime) => [runtime.id, runtime.label]),
);

function sessionCheck(session: SessionInfo, now: Date): Check {
  const parts = [RUNTIME_LABELS[session.runtime] ?? session.runtime, session.project];
  if (session.branch) parts.push(session.branch);
  parts.push(connectedLabel(session.connected_at, now));
  return { label: parts.join(" · "), status: "ok", fix: "" };
}

// "connected 2h", "connected 45m", "connected 2h 3m": whole minutes under an
// hour, else hours plus a remainder that is dropped when it is zero.
function connectedLabel(connectedAt: string, now: Date): string {
  const minutes = Math.max(0, Math.floor((now.getTime() - Date.parse(connectedAt)) / 60000));
  if (minutes < 60) return `connected ${minutes}m`;
  const hours = Math.floor(minutes / 60);
  const rem = minutes % 60;
  return rem === 0 ? `connected ${hours}h` : `connected ${hours}h ${rem}m`;
}

function statusWord(status: CheckStatus): string {
  switch (status) {
    case "ok":
      return "ok    ";
    case "fail":
      return "fail  ";
    case "skip":
      return "skip  ";
  }
}

function formatRest(check: Check): string {
  return check.status === "ok" ? check.label : `${check.label}  (fix: ${check.fix})`;
}
