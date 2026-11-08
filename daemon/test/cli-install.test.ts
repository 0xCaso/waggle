import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import type { Subprocess } from "bun";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir, userInfo } from "node:os";
import { join } from "node:path";
import pkg from "../package.json" with { type: "json" };
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { rpcConnect, rmrf, stopDaemonByHome, tmpHome } from "./helpers";

// End-to-end CLI tests. Every side-effecting subcommand runs as a spawned
// process with HOME, KNOCK_HOME and PATH pointed at temp dirs: `claude`,
// `codex` and `launchctl` are fakes on PATH, so real user settings are never
// touched (KNOCK-06 acceptance, KNOCK-20: never the real claude/codex mcp add).
// The pilot installs no LaunchAgent (KNOCK-18): install only registers the MCP
// server(s) and removes a legacy LaunchAgent (current or pre-rename label).

const ENTRY = join(import.meta.dir, "..", "src", "index.ts");
const SERVICE_LABEL = "dev.limone.knock.daemon";
const PRE_RENAME_LABEL = "dev.hail.daemon";
const BOOTOUT_TARGET = `gui/${userInfo().uid}/${SERVICE_LABEL}`;
const PRE_RENAME_BOOTOUT_TARGET = `gui/${userInfo().uid}/${PRE_RENAME_LABEL}`;

// Mimics a real `claude mcp get waggle`: an "Environment:" block listing each
// KEY=value line, present only once `add` recorded one via -e.
const CLAUDE_SH = `#!/bin/sh
printf 'claude %s\\n' "$*" >> "$CLAUDE_LOG"
# HAIL-176: the entry is named waggle; a pre-rename entry named knock lives in its own state file
# (a test creates "registered-legacy"), so each name is registered on its own.
case "$1" in
  mcp)
    case "$2" in
      list)
        if [ -f "$CLAUDE_STATE/registered" ]; then
          echo "waggle: \${CLAUDE_REGISTERED_PATH:-/stub/waggle} mcp - Connected"
        else
          echo "Checking MCP server health..."
        fi
        if [ -f "$CLAUDE_STATE/registered-legacy" ]; then
          echo "knock: /stub/knock mcp - Connected"
        fi
        ;;
      get)
        name="$3"
        file="$CLAUDE_STATE/registered"
        [ "$name" = "knock" ] && file="$CLAUDE_STATE/registered-legacy"
        if [ -f "$file" ]; then
          echo "$name:"
          echo "  Command: \${CLAUDE_REGISTERED_PATH:-/stub/waggle}"
          echo "  Args: mcp"
          echo "  Environment:"
          if [ -f "$CLAUDE_STATE/env" ]; then
            sed 's/^/    /' "$CLAUDE_STATE/env"
          fi
        else
          echo "No MCP server found with name: $name" >&2
          exit 1
        fi
        ;;
      add)
        touch "$CLAUDE_STATE/registered"
        rm -f "$CLAUDE_STATE/env"
        shift 2
        while [ $# -gt 0 ]; do
          case "$1" in
            -e) echo "$2" >> "$CLAUDE_STATE/env"; shift 2 ;;
            *) shift ;;
          esac
        done
        ;;
      remove)
        if [ "$5" = "knock" ]; then rm -f "$CLAUDE_STATE/registered-legacy"; else rm -f "$CLAUDE_STATE/registered" "$CLAUDE_STATE/env"; fi
        ;;
    esac
    ;;
  --version) echo "1.0.0" ;;
esac
exit 0
`;

// Mimics a real `codex mcp add/get/list/remove waggle --json` (verified against
// a local codex-cli 0.154.0): `add` overwrites any existing registration in
// place, `get`/`list` print JSON with a `transport.command`/`transport.args`.
// A pre-rename entry named knock lives in "registered-legacy" (a test creates it).
const CODEX_SH = `#!/bin/sh
printf 'codex %s\\n' "$*" >> "$CODEX_LOG"
case "$1" in
  mcp)
    case "$2" in
      list)
        items=""
        if [ -f "$CODEX_STATE/registered" ]; then
          cmd=$(cat "$CODEX_STATE/registered")
          items="{\\"name\\":\\"waggle\\",\\"transport\\":{\\"command\\":\\"$cmd\\",\\"args\\":[\\"mcp\\"]}}"
        fi
        if [ -f "$CODEX_STATE/registered-legacy" ]; then
          cmd=$(cat "$CODEX_STATE/registered-legacy")
          [ -n "$items" ] && items="$items,"
          items="$items{\\"name\\":\\"knock\\",\\"transport\\":{\\"command\\":\\"$cmd\\",\\"args\\":[\\"mcp\\"]}}"
        fi
        echo "[$items]"
        ;;
      get)
        name="$3"
        file="$CODEX_STATE/registered"
        [ "$name" = "knock" ] && file="$CODEX_STATE/registered-legacy"
        if [ -f "$file" ]; then
          cmd=$(cat "$file")
          printf '{"name":"%s","transport":{"command":"%s","args":["mcp"],"env":{"KNOCK_RUNTIME":"codex"}}}\\n' "$name" "$cmd"
        else
          echo "Error: No MCP server named '$name' found." >&2
          exit 1
        fi
        ;;
      add)
        shift 3 # drop "mcp add waggle"
        cmd=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --) shift; cmd="$1"; break ;;
            *) shift ;;
          esac
        done
        echo "$cmd" > "$CODEX_STATE/registered"
        ;;
      remove)
        if [ "$3" = "knock" ]; then rm -f "$CODEX_STATE/registered-legacy"; else rm -f "$CODEX_STATE/registered"; fi
        ;;
    esac
    ;;
  --version) echo "codex-cli 0.154.0" ;;
esac
exit 0
`;

const LAUNCHCTL_SH = `#!/bin/sh
printf 'launchctl %s\\n' "$*" >> "$LAUNCHCTL_LOG"
exit 0
`;

interface Stub {
  dir: string;
  claudeState: string;
  codexState: string;
  claudeLog: string;
  codexLog: string;
  launchctlLog: string;
}

function makeStub(opts: { codex?: boolean } = {}): Stub {
  const dir = mkdtempSync(join(tmpdir(), "knock-stub-"));
  const claudeState = join(dir, "claude-state");
  const codexState = join(dir, "codex-state");
  mkdirSync(claudeState, { recursive: true });
  mkdirSync(codexState, { recursive: true });
  const claudeLog = join(dir, "claude.log");
  const codexLog = join(dir, "codex.log");
  const launchctlLog = join(dir, "launchctl.log");
  writeFileSync(join(dir, "claude"), CLAUDE_SH);
  writeFileSync(join(dir, "launchctl"), LAUNCHCTL_SH);
  chmodSync(join(dir, "claude"), 0o755);
  chmodSync(join(dir, "launchctl"), 0o755);
  if (opts.codex !== false) {
    writeFileSync(join(dir, "codex"), CODEX_SH);
    chmodSync(join(dir, "codex"), 0o755);
  }
  return { dir, claudeState, codexState, claudeLog, codexLog, launchctlLog };
}

// `isolatePath` drops every directory except `stub.dir` and the standard
// system bin dirs (still needed for the fake scripts' own `touch`/`rm`/`sed`)
// so a runtime the stub does not provide a fake for (e.g. `newStub({ codex:
// false })`) resolves to "not found" instead of falling through to whatever
// real `claude`/`codex` a developer happens to have installed under
// `~/.local/bin`, `/opt/homebrew/bin` or an npm global prefix — AGENTS.md:
// never run the real claude/codex mcp add outside a fake binary.
function envWith(
  home: string,
  stub: Stub,
  extra: Record<string, string> = {},
  opts: { isolatePath?: boolean } = {},
): Record<string, string> {
  return {
    ...process.env,
    HOME: home,
    KNOCK_HOME: home,
    PATH: opts.isolatePath ? `${stub.dir}:/usr/bin:/bin` : `${stub.dir}:${process.env.PATH}`,
    CLAUDE_LOG: stub.claudeLog,
    CLAUDE_STATE: stub.claudeState,
    CODEX_LOG: stub.codexLog,
    CODEX_STATE: stub.codexState,
    LAUNCHCTL_LOG: stub.launchctlLog,
    ...extra,
  };
}

interface RunResult {
  code: number;
  stdout: string;
  stderr: string;
}

async function runKnock(
  args: string[],
  env: Record<string, string>,
  stdin?: string,
): Promise<RunResult> {
  const proc = Bun.spawn([process.execPath, ENTRY, ...args], {
    env,
    stdout: "pipe",
    stderr: "pipe",
    stdin: "pipe",
  });
  proc.stdin.write(stdin ?? "");
  proc.stdin.end();
  const code = await proc.exited;
  const stdout = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();
  return { code, stdout, stderr };
}

function readLog(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

function legacyPlistPath(home: string): string {
  return join(home, "Library", "LaunchAgents", `${SERVICE_LABEL}.plist`);
}

function preRenamePlistPath(home: string): string {
  return join(home, "Library", "LaunchAgents", `${PRE_RENAME_LABEL}.plist`);
}

function writeLegacyPlist(home: string): void {
  mkdirSync(join(home, "Library", "LaunchAgents"), { recursive: true });
  writeFileSync(legacyPlistPath(home), "<plist/>");
}

function writePreRenamePlist(home: string): void {
  mkdirSync(join(home, "Library", "LaunchAgents"), { recursive: true });
  writeFileSync(preRenamePlistPath(home), "<plist/>");
}

const homes: string[] = [];
const stubs: Stub[] = [];
const procs: Subprocess[] = [];

afterEach(async () => {
  for (const proc of procs.splice(0)) {
    try {
      proc.kill();
      await proc.exited;
    } catch {
      // Already gone.
    }
  }
  for (const home of homes.splice(0)) {
    await stopDaemonByHome(home);
    rmrf(home);
  }
  for (const stub of stubs.splice(0)) {
    rmrf(stub.dir);
  }
});

function newHome(): string {
  const home = tmpHome();
  homes.push(home);
  return home;
}

function newStub(opts: { codex?: boolean } = {}): Stub {
  const stub = makeStub(opts);
  stubs.push(stub);
  return stub;
}

describe("waggle install claude", () => {
  test("registers the MCP server and installs no LaunchAgent", async () => {
    const home = newHome();
    const stub = newStub();

    const result = await runKnock(["install", "claude"], envWith(home, stub));

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Registered Claude Code MCP server waggle.");
    expect(result.stdout).not.toContain(`Installed ${SERVICE_LABEL}.`);

    const claudeLog = readLog(stub.claudeLog);
    // install checks with `mcp get` (one server), never `mcp list` (every
    // server's health check, which timed out on a friend's Mac).
    expect(claudeLog).toContain("claude mcp get waggle");
    expect(claudeLog).not.toContain("claude mcp list");
    expect(claudeLog).toContain(
      `claude mcp add --scope user waggle -e KNOCK_RUNTIME=claude -- ${process.execPath} mcp`,
    );

    // No launchctl call and no plist were written.
    expect(readLog(stub.launchctlLog)).toBe("");
    expect(existsSync(legacyPlistPath(home))).toBe(false);
  });

  test("removes a legacy LaunchAgent and says so", async () => {
    const home = newHome();
    const stub = newStub();
    writeLegacyPlist(home);

    const result = await runKnock(
      ["install", "claude"],
      envWith(home, stub, { KNOCK_ALLOW_LAUNCHCTL: "1" }),
    );

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Registered Claude Code MCP server waggle.");
    expect(result.stdout).toContain(`Removed legacy ${SERVICE_LABEL} LaunchAgent.`);
    expect(readLog(stub.launchctlLog)).toContain(`launchctl bootout ${BOOTOUT_TARGET}`);
    expect(existsSync(legacyPlistPath(home))).toBe(false);
  });

  test("removes a pre-rename dev.hail.daemon LaunchAgent and says so", async () => {
    const home = newHome();
    const stub = newStub();
    writePreRenamePlist(home);

    const result = await runKnock(
      ["install", "claude"],
      envWith(home, stub, { KNOCK_ALLOW_LAUNCHCTL: "1" }),
    );

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Registered Claude Code MCP server waggle.");
    expect(result.stdout).toContain(`Removed legacy ${PRE_RENAME_LABEL} LaunchAgent.`);
    expect(readLog(stub.launchctlLog)).toContain(`launchctl bootout ${PRE_RENAME_BOOTOUT_TARGET}`);
    expect(existsSync(preRenamePlistPath(home))).toBe(false);
  });

  test("is idempotent and prints what did not change", async () => {
    const home = newHome();
    const stub = newStub();
    const env = envWith(home, stub);

    await runKnock(["install", "claude"], env);
    const second = await runKnock(["install", "claude"], env);

    expect(second.code).toBe(0);
    expect(second.stdout).toContain("Claude Code MCP server waggle already registered.");

    const claudeLog = readLog(stub.claudeLog);
    const adds = claudeLog.match(/claude mcp add/g);
    expect(adds).toHaveLength(1);
  });

  test("replaces an existing registration made before the runtime env, once", async () => {
    const home = newHome();
    const stub = newStub();
    const env = envWith(home, stub);

    // Simulate a pre-KNOCK-20 registration: no -e flag, so no env file.
    await runKnock(["install", "claude"], env);
    writeFileSync(join(stub.claudeState, "env"), "");

    const result = await runKnock(["install", "claude"], env);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Replaced Claude Code MCP server waggle to add the runtime label.");

    const again = await runKnock(["install", "claude"], env);
    expect(again.stdout).toContain("Claude Code MCP server waggle already registered.");

    const claudeLog = readLog(stub.claudeLog);
    expect(claudeLog).toContain("claude mcp remove --scope user waggle");
    const adds = claudeLog.match(/claude mcp add/g);
    expect(adds).toHaveLength(2);
  });

  test("registers the stable app path, not the running binary", async () => {
    const home = newHome();
    const stub = newStub();
    // The pilot install location (INSTALL.md): the binary inside the app.
    const appKnock = join(home, "Applications", "Waggle.app", "Contents", "Resources", "waggle");
    mkdirSync(join(home, "Applications", "Waggle.app", "Contents", "Resources"), { recursive: true });
    writeFileSync(appKnock, "#!/bin/sh\n");

    const result = await runKnock(["install", "claude"], envWith(home, stub));

    expect(result.code).toBe(0);
    expect(readLog(stub.claudeLog)).toContain(
      `claude mcp add --scope user waggle -e KNOCK_RUNTIME=claude -- ${appKnock} mcp`,
    );
  });
});

describe("waggle install codex", () => {
  test("registers the MCP server with the runtime env", async () => {
    const home = newHome();
    const stub = newStub();

    const result = await runKnock(["install", "codex"], envWith(home, stub));

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Registered Codex MCP server waggle.");

    const codexLog = readLog(stub.codexLog);
    expect(codexLog).toContain(
      `codex mcp add waggle --env KNOCK_RUNTIME=codex -- ${process.execPath} mcp`,
    );
  });

  test("is idempotent and prints what did not change", async () => {
    const home = newHome();
    const stub = newStub();
    const env = envWith(home, stub);

    await runKnock(["install", "codex"], env);
    const second = await runKnock(["install", "codex"], env);

    expect(second.code).toBe(0);
    expect(second.stdout).toContain("Codex MCP server waggle already registered.");

    const codexLog = readLog(stub.codexLog);
    const adds = codexLog.match(/codex mcp add/g);
    expect(adds).toHaveLength(1);
  });
});

describe("waggle install codex --refresh", () => {
  test("exits 0 with a plain line when codex is absent (HAIL-218)", async () => {
    const home = newHome();
    const stub = newStub({ codex: false });

    const result = await runKnock(["install", "codex", "--refresh"], envWith(home, stub, {}, { isolatePath: true }));

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Codex is not installed: nothing to refresh");
    expect(result.stderr).not.toContain("not found");
  });

  test("a plain install codex still fails when codex is absent", async () => {
    const home = newHome();
    const stub = newStub({ codex: false });

    const result = await runKnock(["install", "codex"], envWith(home, stub, {}, { isolatePath: true }));

    expect(result.code).toBe(1);
    expect(result.stderr).toContain("codex was not found on PATH");
  });
});

describe("waggle install (no runtime)", () => {
  test("installs every runtime found on PATH and names the one it skipped", async () => {
    const home = newHome();
    const stub = newStub({ codex: false });

    const result = await runKnock(["install"], envWith(home, stub, {}, { isolatePath: true }));

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Registered Claude Code MCP server waggle.");
    expect(result.stdout).toContain("Skipped codex: not found on PATH.");
  });

  test("installs both when both are on PATH", async () => {
    const home = newHome();
    const stub = newStub();

    const result = await runKnock(["install"], envWith(home, stub));

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Registered Claude Code MCP server waggle.");
    expect(result.stdout).toContain("Registered Codex MCP server waggle.");
  });
});

describe("waggle doctor", () => {
  test("prints ok for claude and skip for codex after installing claude only", async () => {
    const home = newHome();
    const stub = newStub({ codex: false });
    const env = envWith(home, stub, {}, { isolatePath: true });

    await runKnock(["install", "claude"], env);

    const result = await runKnock(["doctor"], env);

    expect(result.code).toBe(0);
    for (const line of [
      `waggle ${pkg.version}`,
      "ok    service reachable, or startable on demand",
      "ok    agent instructions v11",
      "ok    claude found",
      "ok    Claude Code MCP server registered",
      "skip  codex found  (fix: install Codex)",
      "skip  Codex MCP server registered  (fix: install Codex first)",
    ]) {
      expect(result.stdout).toContain(line);
    }
    // The stub registers /stub/waggle, which does not exist: doctor warns but
    // does not fail (KNOCK-21 stable binary path).
    expect(result.stdout).toContain("warn  registered MCP path missing: /stub/waggle");
    // The launchd check is gone (KNOCK-18).
    expect(result.stdout).not.toContain("service running");
  });

  test("prints ok for both runtimes after installing both", async () => {
    const home = newHome();
    const stub = newStub();
    const env = envWith(home, stub);

    await runKnock(["install"], env);

    const result = await runKnock(["doctor"], env);

    expect(result.code).toBe(0);
    for (const line of [
      "ok    claude found",
      "ok    Claude Code MCP server registered",
      "ok    codex found",
      "ok    Codex MCP server registered",
    ]) {
      expect(result.stdout).toContain(line);
    }
  });

  test("does not warn when the registered MCP path exists", async () => {
    const home = newHome();
    const stub = newStub();
    const registeredPath = join(home, "bin", "waggle");
    mkdirSync(join(home, "bin"), { recursive: true });
    writeFileSync(registeredPath, "#!/bin/sh\n");
    const env = envWith(home, stub, { CLAUDE_REGISTERED_PATH: registeredPath });

    await runKnock(["install", "claude"], env);

    const result = await runKnock(["doctor"], env);

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("ok    Claude Code MCP server registered");
    expect(result.stdout).not.toContain("warn  registered MCP path missing");
  });

  test("prints fail (not skip) for a runtime that is found but not registered", async () => {
    const home = newHome();
    const stub = newStub();

    const result = await runKnock(["doctor"], envWith(home, stub));

    expect(result.code).toBe(1);
    expect(result.stdout).toContain("ok    claude found");
    expect(result.stdout).toContain("fail  Claude Code MCP server registered  (fix: waggle install claude)");
    expect(result.stdout).toContain("ok    codex found");
    expect(result.stdout).toContain("fail  Codex MCP server registered  (fix: waggle install codex)");
  });

  test("prints skip (not fail) for every check when neither runtime is on PATH", async () => {
    const home = newHome();
    const emptyDir = mkdtempSync(join(tmpdir(), "knock-empty-"));
    stubs.push({
      dir: emptyDir,
      claudeState: join(emptyDir, "claude-state"),
      codexState: join(emptyDir, "codex-state"),
      claudeLog: "",
      codexLog: "",
      launchctlLog: "",
    });

    const result = await runKnock(["doctor"], {
      ...process.env,
      HOME: home,
      KNOCK_HOME: home,
      PATH: emptyDir,
    });

    expect(result.code).toBe(1);
    expect(result.stdout).toContain("ok    service reachable, or startable on demand");
    expect(result.stdout).toContain("skip  claude found  (fix: install Claude Code)");
    expect(result.stdout).toContain(
      "skip  Claude Code MCP server registered  (fix: install Claude Code first)",
    );
    expect(result.stdout).toContain("skip  codex found  (fix: install Codex)");
    expect(result.stdout).toContain(
      "skip  Codex MCP server registered  (fix: install Codex first)",
    );
  });

  // KNOCK-20 fold pass 2: a live `waggle doctor` from the app got stuck on the
  // M1 "Checking..." step forever, traced to `claude mcp list` sitting on a
  // slow live connectivity probe with no timeout, while doctor.ts ran
  // claude's two checks and codex's two checks one after another. Two fixes:
  // exec.ts now bounds every call, and doctor.ts now runs the two runtimes'
  // checks concurrently (`Promise.all`) instead of queueing them. Each fake
  // binary sleeps 1s before answering `--version` and `mcp list`, so a
  // runtime's own two checks (found, then registered) take ~2s in sequence;
  // sequential runtimes (the pre-fix order) would take ~4s total, concurrent
  // runtimes (this test) should land close to ~2s.
  test("claude's and codex's checks overlap instead of queueing", async () => {
    const home = newHome();
    const dir = mkdtempSync(join(tmpdir(), "knock-slow-"));
    stubs.push({ dir, claudeState: "", codexState: "", claudeLog: "", codexLog: "", launchctlLog: "" });
    const slowShell = (versionLine: string, listLine: string) => `#!/bin/sh
sleep 1
case "$1" in
  --version) echo "${versionLine}" ;;
  mcp)
    case "$2" in
      list) echo '${listLine}' ;;
    esac
    ;;
esac
exit 0
`;
    writeFileSync(join(dir, "claude"), slowShell("1.0.0", "no knock server registered"));
    writeFileSync(join(dir, "codex"), slowShell("codex-cli 0.154.0", "[]"));
    chmodSync(join(dir, "claude"), 0o755);
    chmodSync(join(dir, "codex"), 0o755);

    const started = Date.now();
    const result = await runKnock(["doctor"], {
      ...process.env,
      HOME: home,
      KNOCK_HOME: home,
      PATH: `${dir}:/usr/bin:/bin`,
    });
    const elapsedMs = Date.now() - started;

    expect(result.stdout).toContain("ok    claude found");
    expect(result.stdout).toContain("ok    codex found");
    expect(elapsedMs).toBeLessThan(3500);
  });

  // HAIL-27: doctor reports the running daemon's version and exec path, and
  // warns when either differs from this CLI's own.
  test("reports the running daemon and warns when version and path differ", async () => {
    const home = newHome();
    const stub = newStub();
    const db = new Database(join(home, "knock.db"));
    const store = new Store(db, home);
    const server = startRpcServer({
      socketPath: join(home, "knock.sock"),
      store,
      bus: new EventBus(),
      version: "0.0.9",
      execPath: "/fake/old/knock",
    });
    try {
      const result = await runKnock(["doctor"], envWith(home, stub));

      expect(result.stdout).toContain("ok    running daemon 0.0.9 at /fake/old/knock");
      expect(result.stdout).toContain(
        `warn  running daemon version 0.0.9 differs from this CLI (${pkg.version})`,
      );
      expect(result.stdout).toContain(
        "warn  running daemon path /fake/old/knock differs from this CLI",
      );
    } finally {
      server.stop();
      db.close();
    }
  });
});

// HAIL-46: doctor's "sessions" section - one ok line per connected session,
// read over the same socket connection service.status already uses (see
// readDaemonState in doctor.ts), or a warning when none is connected. A
// warning never fails the run (docs/protocol-mvp.md convention, preserved
// here): these tests check stdout only, not `result.code`.
describe("waggle doctor sessions", () => {
  function startTestDaemon(home: string): { store: Store; server: RpcServer; db: Database } {
    const db = new Database(join(home, "knock.db"));
    const store = new Store(db, home);
    const server = startRpcServer({
      socketPath: join(home, "knock.sock"),
      store,
      bus: new EventBus(),
      version: pkg.version,
    });
    return { store, server, db };
  }

  test("warns when no agent session is connected", async () => {
    const home = newHome();
    const stub = newStub();
    const { server, db } = startTestDaemon(home);
    try {
      const result = await runKnock(["doctor"], envWith(home, stub));
      expect(result.stdout).toContain(
        "warn  no agent session connected: start Claude Code, or run /mcp → waggle → Reconnect",
      );
    } finally {
      server.stop();
      db.close();
    }
  });

  test("prints one ok line for a single connected session", async () => {
    const home = newHome();
    const stub = newStub();
    const { store, server, db } = startTestDaemon(home);
    try {
      const task = store.createTask({ name: "knock", project: "knock" });
      store.createSession(task.id, {
        id: "s1",
        cwd: "/tmp/knock",
        branch: "main",
        pid: process.pid,
        runtime: "claude",
      });

      const result = await runKnock(["doctor"], envWith(home, stub));
      expect(result.stdout).toContain("ok    Claude Code · knock · main · connected 0m");
      expect(result.stdout).not.toContain("no agent session connected");
    } finally {
      server.stop();
      db.close();
    }
  });

  test("prints one ok line per session for two connected sessions", async () => {
    const home = newHome();
    const stub = newStub();
    const { store, server, db } = startTestDaemon(home);
    try {
      const task = store.createTask({ name: "knock", project: "knock" });
      store.createSession(task.id, {
        id: "s1",
        cwd: "/tmp/knock",
        branch: "main",
        pid: process.pid,
        runtime: "claude",
      });
      const otherTask = store.createTask({ name: "OME-412", project: "weekend-league" });
      store.createSession(otherTask.id, {
        id: "s2",
        cwd: "/tmp/weekend-league",
        branch: "ome-412-pricing",
        pid: process.pid,
        runtime: "codex",
      });

      const result = await runKnock(["doctor"], envWith(home, stub));
      expect(result.stdout).toContain("ok    Claude Code · knock · main · connected 0m");
      expect(result.stdout).toContain(
        "ok    Codex · weekend-league · ome-412-pricing · connected 0m",
      );
    } finally {
      server.stop();
      db.close();
    }
  });

  // A disconnected or ended session is not "connected" (docs/protocol-mvp.md
  // "Socket RPC" session states): doctor's own filter to state === "live"
  // must still warn when every known session has moved past that.
  test("warns when every known session has disconnected", async () => {
    const home = newHome();
    const stub = newStub();
    const { store, server, db } = startTestDaemon(home);
    try {
      const task = store.createTask({ name: "knock", project: "knock" });
      const session = store.createSession(task.id, {
        id: "s1",
        cwd: "/tmp/knock",
        branch: "main",
        pid: process.pid,
        runtime: "claude",
      });
      store.setSessionState(session.id, "disconnected");

      const result = await runKnock(["doctor"], envWith(home, stub));
      expect(result.stdout).toContain(
        "warn  no agent session connected: start Claude Code, or run /mcp → waggle → Reconnect",
      );
      expect(result.stdout).not.toContain("Claude Code · knock · main · connected");
    } finally {
      server.stop();
      db.close();
    }
  });
});

describe("waggle uninstall", () => {
  test("removes the MCP registration and a legacy LaunchAgent", async () => {
    const home = newHome();
    const stub = newStub();
    const env = envWith(home, stub);

    await runKnock(["install", "claude"], env);
    // The legacy agent is left by an OLDER build, so it appears after install.
    writeLegacyPlist(home);

    const result = await runKnock(["uninstall"], envWith(home, stub, { KNOCK_ALLOW_LAUNCHCTL: "1" }));

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Removed Claude Code MCP server waggle.");
    expect(result.stdout).toContain("Codex MCP server waggle was not registered.");
    expect(result.stdout).toContain(`Removed legacy ${SERVICE_LABEL} LaunchAgent.`);

    expect(readLog(stub.claudeLog)).toContain("claude mcp remove --scope user waggle");
    expect(readLog(stub.launchctlLog)).toContain(`launchctl bootout ${BOOTOUT_TARGET}`);
    expect(existsSync(legacyPlistPath(home))).toBe(false);
  });

  test("removes the registration from every runtime where it exists", async () => {
    const home = newHome();
    const stub = newStub();
    const env = envWith(home, stub);

    await runKnock(["install"], env);

    const result = await runKnock(["uninstall"], env);

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Removed Claude Code MCP server waggle.");
    expect(result.stdout).toContain("Removed Codex MCP server waggle.");
    expect(readLog(stub.claudeLog)).toContain("claude mcp remove --scope user waggle");
    expect(readLog(stub.codexLog)).toContain("codex mcp remove waggle");
  });

  test("reports no legacy agent when none exists", async () => {
    const home = newHome();
    const stub = newStub();

    const result = await runKnock(["uninstall"], envWith(home, stub));

    expect(result.code).toBe(0);
    expect(result.stdout).toContain(`${SERVICE_LABEL} was not installed.`);
    expect(readLog(stub.launchctlLog)).toBe("");
  });

  test("--purge --yes deletes KNOCK_HOME", async () => {
    const home = newHome();
    const stub = newStub();
    writeFileSync(join(home, "keep-me.txt"), "data");

    const result = await runKnock(["uninstall", "--purge", "--yes"], envWith(home, stub));

    expect(result.code).toBe(0);
    expect(result.stdout).toContain(`Deleted ${home}.`);
    expect(existsSync(home)).toBe(false);
  });

  test("--purge --yes deletes KNOCK_HOME even with a read-only staged bundle", async () => {
    const home = newHome();
    const stub = newStub();
    // A staged html bundle is read-only (chmod a-w, docs/protocol-mvp.md
    // "Artifacts"); purge must still delete the data root (KNOCK-17).
    const bundleDir = join(home, "bundles", "c_x", "r1");
    mkdirSync(bundleDir, { recursive: true });
    writeFileSync(join(bundleDir, "index.html"), "<html></html>");
    chmodSync(join(bundleDir, "index.html"), 0o444);
    chmodSync(bundleDir, 0o555);

    const result = await runKnock(["uninstall", "--purge", "--yes"], envWith(home, stub));

    expect(result.code).toBe(0);
    expect(result.stdout).toContain(`Deleted ${home}.`);
    expect(existsSync(home)).toBe(false);
  });

  test("--purge keeps KNOCK_HOME when the prompt is answered n", async () => {
    const home = newHome();
    const stub = newStub();
    writeFileSync(join(home, "keep-me.txt"), "data");

    const result = await runKnock(["uninstall", "--purge"], envWith(home, stub), "n\n");

    expect(result.code).toBe(0);
    expect(result.stdout).toContain(`Kept ${home}.`);
    expect(existsSync(join(home, "keep-me.txt"))).toBe(true);
  });
});

describe("waggle test-ask", () => {
  test("starts the daemon on demand and delivers the reply to the test session", async () => {
    const home = newHome();

    // No daemon is pre-started: `waggle test-ask` must start it on demand the
    // way the shim does (KNOCK-17), then complete the same loop.
    const run = runKnock(
      ["test-ask"],
      { ...process.env, KNOCK_HOME: home, KNOCK_ASK_WAIT_MS: "8000" },
    );

    const caseId = await waitForValue(async () => {
      let client;
      try {
        client = await rpcConnect(join(home, "knock.sock"));
      } catch {
        // The daemon started on demand is not up yet; try again.
        return null;
      }
      try {
        const res = await client.request("cases.list", {});
        const rows = (res.result as { id: string }[]) ?? [];
        return rows.length > 0 ? rows[0].id : null;
      } finally {
        client.close();
      }
    });

    // Seed the human reply. reply.submit is KNOCK-05; the storage half
    // (Store.createReply) is the path the smoke test already uses.
    const seedDb = new Database(join(home, "knock.db"));
    const seedStore = new Store(seedDb, home);
    seedStore.createReply(caseId, {
      idempotency_key: "test-ask-key",
      choice: "a",
      message: "Ship it.",
      comments: [],
      captures: [],
    });
    seedDb.close();

    const result = await run;

    expect(result.code).toBe(0);
    expect(result.stdout).toContain('Created test review "Pricing card: compact or detailed?"');
    expect(result.stdout).toContain("Delivered to the test session.");
    expect(result.stdout).toContain('Reply to "Pricing card: compact or detailed?"');
    expect(result.stdout).toContain("Choice: a (Compact: one tight card, built for repeat buyers)");
    expect(result.stdout).toContain("Message: Ship it.");

    const checkDb = new Database(join(home, "knock.db"));
    const row = checkDb
      .query(`SELECT state FROM replies WHERE case_id = ?`)
      .get(caseId) as { state: string } | undefined;
    checkDb.close();
    expect(row?.state).toBe("delivered");
  });
});

async function waitForValue<T>(fn: () => Promise<T | null | undefined>, timeoutMs = 8000): Promise<T> {
  const start = Date.now();
  for (;;) {
    const value = await fn();
    if (value !== null && value !== undefined) return value;
    if (Date.now() - start > timeoutMs) {
      throw new Error("condition not met in time");
    }
    await new Promise((r) => setTimeout(r, 50));
  }
}
