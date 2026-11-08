import { daemonPaths } from "../config";
import { DaemonClient } from "../mcp/client";
import { connectWithOnDemandStart } from "../on-demand";
import { ModEvent } from "../protocol";
import { latestUsage } from "../usage/transcript";
import { USAGE_OFF_FILE } from "../usage";
import { USAGE_TRANSCRIPT_OFF_FILE } from "../usage/tools";
import { run } from "./exec";
import { REMINDER_SOURCES, sessionStartOutput, stopDecision } from "../hooks/claude-hooks";
import { existsSync } from "node:fs";
import { join } from "node:path";

// `waggle mod ...` (HAIL-134): what the Waggle Claude Code plugin's mod runs through
// `$.process.run`. Each verb makes one RPC and prints one line of JSON. The mod
// never opens the socket itself, and it sends no prompt text: see
// docs/protocol-mvp.md "Claude Code mod". Like `waggle test-ask`, a verb starts the
// daemon on demand when the socket is unreachable.
//
//   waggle mod poll --session <id> [--wait-ms N] [--seen SIG] [--mod-version V]
//   waggle mod report --session <id> --event <turn.start|turn.complete|prompt.submit|tool.call|nudge.failed>
//                    [--tool NAME] [--case ID] [--count N]
//   waggle mod usage --session <id> --tool NAME --transcript PATH   (HAIL-195; reads only the usage numbers
//                    of the latest assistant message, never its content, and sends only those numbers)
//   waggle mod claude-hook <Stop|SessionStart>    (the Claude Code plugin's hooks, WAG-265; see below)
//   waggle mod codex-hook <Event>    (the Codex plugin's hooks; reads Codex's JSON on stdin)
//   waggle mod open [--case <id>]     (no case: bring the app forward on its queue)

// HAIL-137: `waggle mod codex-hook <Event>` is what the Waggle Codex plugin's hooks run. Codex
// writes one JSON object to stdin; this reads it, makes one RPC and prints what Codex expects
// on stdout. It never fails: any problem prints nothing and exits 0, so a hook can never hold
// up or break a Codex turn. Only SessionStart starts the daemon on demand (a hook must not
// wait for a start otherwise). The prompt text of UserPromptSubmit is never read.
//   SessionStart -> turn.complete (idle)   UserPromptSubmit -> turn.start
//   PreToolUse -> tool.call (tool name; PostToolUse is not used: it would count each call twice)
//   Stop -> turn.complete, then mod.stop_check (may print {"decision":"block","reason":...})
//   SessionEnd -> session.end
const HOOK_RPC_MS = 1_500;

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  const timer = new Promise<void>((r) => setTimeout(r, 1_000));
  const read = (async () => {
    for await (const chunk of process.stdin) chunks.push(Buffer.from(chunk));
  })();
  await Promise.race([read, timer]);
  return Buffer.concat(chunks).toString("utf8");
}

export async function runCodexHook(eventName: string | undefined, input?: string): Promise<number> {
  const client = new DaemonClient();
  try {
    let payload: Record<string, unknown> = {};
    try {
      const parsed = JSON.parse(input ?? (await readStdin())) as unknown;
      if (parsed && typeof parsed === "object") payload = parsed as Record<string, unknown>;
    } catch {
      return 0;
    }
    const session = typeof payload.session_id === "string" ? payload.session_id : "";
    const cwd = typeof payload.cwd === "string" && payload.cwd ? payload.cwd : undefined;
    const events: Record<string, ModEvent | undefined> = {
      SessionStart: "turn.complete",
      UserPromptSubmit: "turn.start",
      PreToolUse: "tool.call",
      Stop: "turn.complete",
      SessionEnd: "session.end",
    };
    const event = eventName ? events[eventName] : undefined;
    if (!session || !event) return 0;
    const socket = daemonPaths().socket;
    if (eventName === "SessionStart") await connectWithOnDemandStart(client, socket);
    else await client.connect(socket);
    // Tool name only: tool input and output never leave the hook.
    const tool = eventName === "PreToolUse" ? payload.tool_name : undefined;
    const base = { session_id: session, source: "codex-hooks", ...(cwd ? { cwd } : {}) };
    await client.call(
      "mod.report",
      {
        ...base,
        event,
        ...(typeof tool === "string" && tool ? { tool: tool.slice(0, 200) } : {}),
      },
      HOOK_RPC_MS,
    );
    if (eventName === "Stop") {
      const stop = (await client.call("mod.stop_check", { session_id: session, ...(cwd ? { cwd } : {}) }, HOOK_RPC_MS)) as {
        block?: boolean;
        reason?: string | null;
      };
      if (stop.block && stop.reason) process.stdout.write(`${JSON.stringify({ decision: "block", reason: stop.reason })}\n`);
    }
    return 0;
  } catch {
    return 0;
  } finally {
    client.close();
  }
}

// WAG-265: `waggle mod claude-hook <Stop|SessionStart>` is what the Waggle Claude Code plugin's
// hooks.json runs. Claude Code writes one JSON object to stdin. Like the Codex hook it never
// fails: any problem prints nothing and exits 0, so a hook can never hold up a turn.
//   Stop          -> {"decision":"block","reason":...} once, when the last message asks the human
//                    something and the session has no open ask (and the switch is on)
//   SessionStart  -> one line of context for the `compact` and `resume` sources; nothing otherwise
// The daemon is never started on demand here: a Stop hook must not wait for one.
async function openCaseIdsFor(session: string, cwd?: string): Promise<string[]> {
  const client = new DaemonClient();
  try {
    await client.connect(daemonPaths().socket);
    const result = (await client.call("mod.open_ask", { session_id: session, ...(cwd ? { cwd } : {}) }, HOOK_RPC_MS)) as {
      case_ids?: string[];
    };
    return Array.isArray(result.case_ids) ? result.case_ids.filter((id) => typeof id === "string").slice(0, 5) : [];
  } catch {
    return [];
  } finally {
    client.close();
  }
}

export async function runClaudeHook(eventName: string | undefined, input?: string): Promise<number> {
  try {
    let payload: Record<string, unknown> = {};
    try {
      const parsed = JSON.parse(input ?? (await readStdin())) as unknown;
      if (parsed && typeof parsed === "object") payload = parsed as Record<string, unknown>;
    } catch {
      return 0;
    }
    let out: object | null = null;
    if (eventName === "SessionStart") {
      const session = typeof payload.session_id === "string" ? payload.session_id : "";
      const cwd = typeof payload.cwd === "string" && payload.cwd ? payload.cwd : undefined;
      // WAG-268: best effort. No daemon or no open ask gives the plain reminder.
      const caseIds = REMINDER_SOURCES.includes(String(payload.source)) && session ? await openCaseIdsFor(session, cwd) : [];
      out = sessionStartOutput(payload, caseIds);
    } else if (eventName === "Stop") {
      const session = typeof payload.session_id === "string" ? payload.session_id : "";
      const cwd = typeof payload.cwd === "string" && payload.cwd ? payload.cwd : undefined;
      out = await stopDecision({
        input: payload,
        home: daemonPaths().home,
        hasOpenAsk: async () => {
          // No session id or no daemon: this throws, and stopDecision lets the stop through (fail open).
          if (!session) throw new Error("no session id");
          const client = new DaemonClient();
          try {
            await client.connect(daemonPaths().socket);
            const result = (await client.call("mod.open_ask", { session_id: session, ...(cwd ? { cwd } : {}) }, HOOK_RPC_MS)) as {
              open?: boolean;
            };
            return result.open === true;
          } finally {
            client.close();
          }
        },
      });
    }
    if (out) process.stdout.write(`${JSON.stringify(out)}\n`);
    return 0;
  } catch {
    return 0;
  }
}

const USAGE = `Usage: waggle mod poll --session <id> [--wait-ms N] [--seen SIG] [--mod-version V]
       waggle mod report --session <id> --event <event> [--tool NAME] [--case ID] [--count N]
       waggle mod usage --session <id> --tool NAME --transcript PATH
       waggle mod open [--case <id>]
`;

function flags(argv: string[]): Map<string, string> | null {
  const out = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key.startsWith("--") || value === undefined) return null;
    out.set(key.slice(2), value);
  }
  return out;
}

function intFlag(value: string | undefined): number | undefined {
  if (value === undefined) return undefined;
  const n = Number(value);
  return Number.isInteger(n) ? n : NaN;
}

// HAIL-195: the context a Waggle tool call re-reads. Never fails and never starts the daemon.
// Prints {"ok":true} when it sent numbers, {"ok":false} when it sent none (a switch is off, the
// transcript cannot be read, or the daemon is down). The transcript path stays in this process.
async function runUsage(f: Map<string, string>): Promise<number> {
  const session = f.get("session");
  const tool = f.get("tool");
  const transcript = f.get("transcript");
  if (!session || !tool || !transcript) {
    process.stderr.write(USAGE);
    return 2;
  }
  const home = daemonPaths().home;
  const none = (): number => {
    process.stdout.write(`${JSON.stringify({ ok: false })}\n`);
    return 0;
  };
  if (existsSync(join(home, USAGE_OFF_FILE)) || existsSync(join(home, USAGE_TRANSCRIPT_OFF_FILE))) return none();
  const usage = latestUsage(transcript);
  if (!usage) return none();
  const client = new DaemonClient();
  try {
    await client.connect(daemonPaths().socket);
    await client.call(
      "usage.context",
      {
        session_id: session,
        tool,
        input: usage.input,
        cache_read: usage.cache_read,
        cache_creation: usage.cache_creation,
        output: usage.output,
      },
      HOOK_RPC_MS,
    );
    process.stdout.write(`${JSON.stringify({ ok: true })}\n`);
    return 0;
  } catch {
    return none();
  } finally {
    client.close();
  }
}

export async function runMod(argv: string[]): Promise<number> {
  const [verb, ...rest] = argv;
  if (verb === "codex-hook") return runCodexHook(rest[0]);
  if (verb === "claude-hook") return runClaudeHook(rest[0]);
  const f = flags(rest);
  if (f && verb === "usage") return runUsage(f);
  if (!f || (verb !== "poll" && verb !== "report" && verb !== "open")) {
    process.stderr.write(USAGE);
    return 2;
  }
  let method: string;
  let params: Record<string, unknown>;
  let timeoutMs = 10_000;
  if (verb === "poll") {
    const session = f.get("session");
    const wait = intFlag(f.get("wait-ms"));
    if (!session || Number.isNaN(wait)) {
      process.stderr.write(USAGE);
      return 2;
    }
    method = "mod.poll";
    params = {
      session_id: session,
      ...(wait !== undefined ? { wait_ms: wait } : {}),
      ...(f.has("seen") ? { seen: f.get("seen") } : {}),
      ...(f.has("mod-version") ? { mod_version: f.get("mod-version") } : {}),
    };
    timeoutMs = (wait ?? 0) + 8_000;
  } else if (verb === "report") {
    const session = f.get("session");
    const event = ModEvent.safeParse(f.get("event"));
    const count = intFlag(f.get("count"));
    if (!session || !event.success || Number.isNaN(count)) {
      process.stderr.write(USAGE);
      return 2;
    }
    method = "mod.report";
    params = {
      session_id: session,
      event: event.data,
      ...(f.has("tool") ? { tool: f.get("tool") } : {}),
      ...(f.has("case") ? { case_id: f.get("case") } : {}),
      ...(count !== undefined ? { count } : {}),
    };
  } else {
    const caseId = f.get("case");
    if (rest.length > 0 && !caseId) {
      process.stderr.write(USAGE);
      return 2;
    }
    method = "case.open";
    params = caseId ? { case_id: caseId } : {};
  }

  const client = new DaemonClient();
  try {
    await connectWithOnDemandStart(client, daemonPaths().socket);
    const result = method ? await client.call(method, params, timeoutMs) : { ok: true };
    if (verb === "open") {
      // The app opens the case on the event. `open -b` brings it forward, or starts it.
      run("open", ["-b", process.env.KNOCK_BUNDLE_ID?.trim() || "dev.limone.knock"], 10_000);
    }
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return 0;
  } catch (error) {
    process.stderr.write(`waggle mod ${verb}: ${(error as Error).message}\n`);
    return 1;
  } finally {
    client.close();
  }
}
