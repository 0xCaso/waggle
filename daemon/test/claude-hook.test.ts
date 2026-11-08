import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import pkg from "../package.json" with { type: "json" };
import { runClaudeHook } from "../src/cli/mod";
import { EventBus } from "../src/events";
import {
  ASK_PREFS_FILE,
  CATCH_QUESTIONS_OFF_FILE,
  RESUME_REMINDER,
  STOP_REASON,
  lastAssistantText,
  readHookAskPrefs,
  sessionStartOutput,
  stopDecision,
  writeHookAskPrefs,
} from "../src/hooks/claude-hooks";
import { startRpcServer, type RpcServer } from "../src/server";
import { Store } from "../src/store";
import { rmrf, rpcConnect, tmpHome, type RpcClient } from "./helpers";

// WAG-265: the Claude Code Stop and SessionStart hooks, under a temp KNOCK_HOME.

const homes: string[] = [];
const servers: RpcServer[] = [];
const clients: RpcClient[] = [];
const savedHome = process.env.KNOCK_HOME;

afterEach(() => {
  for (const c of clients.splice(0)) c.close();
  for (const s of servers.splice(0)) s.stop();
  for (const h of homes.splice(0)) rmrf(h);
  if (savedHome === undefined) delete process.env.KNOCK_HOME;
  else process.env.KNOCK_HOME = savedHome;
});

const home = () => {
  const h = tmpHome();
  homes.push(h);
  return h;
};

const ASKS = "Both layouts work.\n\nWhich one do you want?";
const never = async () => {
  throw new Error("the daemon must not be asked");
};

describe("stopDecision", () => {
  test("blocks a question once, with the Waggle reason", async () => {
    const h = home();
    const out = await stopDecision({ input: { last_assistant_message: ASKS }, home: h, hasOpenAsk: async () => false });
    expect(out).toEqual({ decision: "block", reason: STOP_REASON });
    expect(STOP_REASON).toBe(
      "If this is a new decision, send it with waggle_ask (options and a recommendation). If the person already answered in Waggle or asked for your opinion, just reply.",
    );
  });

  test("never blocks twice in a row: stop_hook_active lets it through", async () => {
    const out = await stopDecision({
      input: { last_assistant_message: ASKS, stop_hook_active: true },
      home: home(),
      hasOpenAsk: never,
    });
    expect(out).toBeNull();
  });

  test("a status report is not blocked, and costs no daemon call", async () => {
    const out = await stopDecision({
      input: { last_assistant_message: "Done. All tests pass." },
      home: home(),
      hasOpenAsk: never,
    });
    expect(out).toBeNull();
  });

  test("an open ask lets the stop through", async () => {
    const out = await stopDecision({ input: { last_assistant_message: ASKS }, home: home(), hasOpenAsk: async () => true });
    expect(out).toBeNull();
  });

  test("fails open when the daemon check throws", async () => {
    const out = await stopDecision({ input: { last_assistant_message: ASKS }, home: home(), hasOpenAsk: never });
    expect(out).toBeNull();
  });

  test("the off switch lets a question through", async () => {
    const h = home();
    writeFileSync(join(h, CATCH_QUESTIONS_OFF_FILE), "");
    const out = await stopDecision({ input: { last_assistant_message: ASKS }, home: h, hasOpenAsk: never });
    expect(out).toBeNull();
  });

  test("reads the last assistant text from the transcript when the message is not given", async () => {
    const h = home();
    const path = join(h, "t.jsonl");
    const line = (o: object) => `${JSON.stringify(o)}\n`;
    writeFileSync(
      path,
      line({ type: "user", message: { role: "user", content: "hi" } }) +
        line({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "Early." }] } }) +
        line({ type: "assistant", message: { role: "assistant", content: [{ type: "tool_use", name: "Bash" }] } }) +
        line({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "Shall I continue?" }] } }) +
        "not json\n",
    );
    expect(lastAssistantText(path)).toBe("Shall I continue?");
    expect(lastAssistantText(join(h, "missing.jsonl"))).toBeUndefined();
    const out = await stopDecision({ input: { transcript_path: path }, home: h, hasOpenAsk: async () => false });
    expect(out?.decision).toBe("block");
  });
});

// WAG-332: the transcript rules.
const jl = (...o: object[]) => o.map((x) => JSON.stringify(x)).join("\n") + "\n";
const user = (text: string, uuid: string, ts = "2026-10-09T10:00:00.000Z") => ({
  type: "user", uuid, timestamp: ts, message: { role: "user", content: text },
});
const say = (text: string, ts = "2026-10-09T10:00:05.000Z") => ({
  type: "assistant", timestamp: ts, message: { role: "assistant", content: [{ type: "text", text }] },
});
const tool = (name: string, ts = "2026-10-09T10:00:03.000Z") => ({
  type: "assistant", timestamp: ts, message: { role: "assistant", content: [{ type: "tool_use", name }] },
});
const NOW = Date.parse("2026-10-09T12:00:00.000Z");

describe("stopDecision transcript rules (WAG-332)", () => {
  const write = (h: string, ...o: object[]) => {
    const path = join(h, "t.jsonl");
    writeFileSync(path, jl(...o));
    return path;
  };
  const run = (h: string, path: string, extra: object = {}) =>
    stopDecision({
      input: { transcript_path: path, session_id: "s1", ...extra },
      home: h,
      hasOpenAsk: async () => false,
      now: NOW,
    });

  test("a plain terminal question is still blocked once", async () => {
    const h = home();
    const path = write(h, user("do the work", "u1"), say("Both layouts work.\n\nWhich one do you want?"));
    expect((await run(h, path))?.decision).toBe("block");
    expect(await run(h, path)).toBeNull(); // rule 3: same prompt
  });

  test("rule 1: a waggle_ask, waggle_update or waggle_check call this turn lets it through, aliases too", async () => {
    for (const name of ["mcp__plugin_waggle_waggle__waggle_ask", "waggle_update", "waggle_check", "mcp__x__knock_ask", "knock_check"]) {
      const h = home();
      const path = write(h, user("go", "u1", "2026-10-09T08:00:00.000Z"), tool(name, "2026-10-09T08:00:03.000Z"), say("Which one do you want?", "2026-10-09T08:00:05.000Z"));
      expect(await run(h, path)).toBeNull();
    }
  });

  test("rule 2: answering the person's own question is not blocked, unless it ends with a direct question", async () => {
    const h = home();
    const path = write(h, user("What do you think of option B?", "u1"), say("I would pick B. It is simpler.\n\nMore detail is in the notes."));
    expect(await run(h, path)).toBeNull();
    const h2 = home();
    const path2 = write(h2, user("What do you think of option B?", "u1"), say("I would pick B.\n\nShould I build it?"));
    expect((await run(h2, path2))?.decision).toBe("block");
  });

  test("rule 3: one block per user prompt, a new prompt can block again", async () => {
    const h = home();
    const q = say("Which one do you want?");
    expect((await run(h, write(h, user("go", "u1"), q)))?.decision).toBe("block");
    expect(await run(h, write(h, user("go", "u1"), q))).toBeNull();
    expect((await run(h, write(h, user("go", "u1"), q, user("fine, continue", "u2"), q)))?.decision).toBe("block");
    expect(await run(h, write(h, user("go", "u1"), q), { session_id: "other" })).not.toBeNull();
  });

  test("rule 4: Waggle activity less than 5 minutes ago lets it through; older does not", async () => {
    const h = home();
    const recent = write(h, tool("waggle_check", "2026-10-09T11:57:00.000Z"), user("go", "u1", "2026-10-09T11:58:00.000Z"), say("Which one do you want?"));
    expect(await run(h, recent)).toBeNull();
    const old = write(h, tool("waggle_check", "2026-10-09T11:50:00.000Z"), user("go", "u2", "2026-10-09T11:58:00.000Z"), say("Which one do you want?"));
    expect((await run(h, old))?.decision).toBe("block");
  });

  test("incident replay: opinion answer after a Waggle reply, then 3 more turns, blocks at most once", async () => {
    const h = home();
    const turns: object[] = [
      user("Answer sent in Waggle", "u0", "2026-10-09T11:00:00.000Z"),
      tool("mcp__plugin_waggle_waggle__waggle_check", "2026-10-09T11:00:02.000Z"),
    ];
    let blocks = 0;
    for (let i = 1; i <= 4; i++) {
      const minute = 10 * i; // 10 minutes apart, so rule 4 alone would not cover it
      const at = (sec: number) => `2026-10-09T11:${String(minute).padStart(2, "0")}:${String(sec).padStart(2, "0")}.000Z`;
      turns.push(user(`Waggle update ${i}`, `p${i}`, at(0)));
      // after a block the agent updates the same case, as it did in the incident
      if (i > 1) turns.push(tool("mcp__plugin_waggle_waggle__waggle_update", at(3)));
      turns.push(say("My take: start with the event notes.\n\nWhich one do you want?", at(5)));
      const out = await stopDecision({
        input: { transcript_path: write(h, ...turns), session_id: "s1" },
        home: h,
        hasOpenAsk: async () => false,
        now: Date.parse(at(9)),
      });
      if (out) blocks++;
    }
    expect(blocks).toBe(1);
  });
});

describe("sessionStartOutput", () => {
  test("adds one line for compact and resume only", () => {
    for (const source of ["compact", "resume"]) {
      expect(sessionStartOutput({ source })).toEqual({
        hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: RESUME_REMINDER },
      });
    }
    for (const source of ["startup", "clear", undefined, 3]) expect(sessionStartOutput({ source })).toBeNull();
    expect(RESUME_REMINDER).toBe(
      "Ask the human through waggle_ask, never in the terminal. Call waggle_guide if you need the details.",
    );
  });

  test("the plugin registers both hooks with the matchers", async () => {
    const file = join(import.meta.dir, "..", "..", "plugins", "claude-code", "waggle", "hooks", "hooks.json");
    const json = JSON.parse(await Bun.file(file).text());
    expect(json.modules).toEqual(["./register.tsx"]);
    expect(json.hooks.SessionStart[0].matcher).toBe("compact|resume");
    expect(json.hooks.SessionStart[0].hooks[0].command).toContain("mod claude-hook SessionStart");
    expect(json.hooks.Stop[0].matcher).toBeUndefined();
    expect(json.hooks.Stop[0].hooks[0].command).toContain("mod claude-hook Stop");
    for (const h of [json.hooks.Stop[0], json.hooks.SessionStart[0]]) {
      expect(h.hooks[0].command).toEndWith("|| true");
    }
  });
});

async function withDaemon() {
  const h = home();
  process.env.KNOCK_HOME = h;
  const store = new Store(new Database(join(h, "knock.db")), h, new EventBus());
  const socketPath = join(h, "knock.sock");
  servers.push(startRpcServer({ socketPath, store, bus: new EventBus(), version: pkg.version }));
  const connect = async () => {
    const c = await rpcConnect(socketPath);
    clients.push(c);
    return c;
  };
  return { home: h, connect };
}

async function hook(event: string, payload: object): Promise<string> {
  const write = process.stdout.write.bind(process.stdout);
  let out = "";
  process.stdout.write = ((chunk: string) => ((out += chunk), true)) as typeof process.stdout.write;
  try {
    expect(await runClaudeHook(event, JSON.stringify(payload))).toBe(0);
  } finally {
    process.stdout.write = write;
  }
  return out;
}

describe("waggle mod claude-hook", () => {
  test("Stop: blocks a question with no open ask, then lets the next stop through", async () => {
    const d = await withDaemon();
    const shim = await d.connect();
    await shim.request("session.hello", { session_id: "s1", cwd: "/tmp/p", parent_pid: process.pid, runtime: "claude" });
    const out = await hook("Stop", { session_id: "s1", cwd: "/tmp/p", last_assistant_message: ASKS });
    expect(JSON.parse(out)).toEqual({ decision: "block", reason: STOP_REASON });
    expect(await hook("Stop", { session_id: "s1", last_assistant_message: ASKS, stop_hook_active: true })).toBe("");
  });

  test("Stop: an open Waggle ask lets the question through", async () => {
    const d = await withDaemon();
    const shim = await d.connect();
    await shim.request("session.hello", { session_id: "s2", cwd: "/tmp/p", parent_pid: process.pid, runtime: "claude" });
    await shim.request("case.create", {
      kind: "question",
      title: "Pick",
      need: "Pick a layout",
      why: "x",
      recommendation: "a",
      recommendation_why: "y",
      options: [
        { id: "a", label: "A layout", title: "A" },
        { id: "b", label: "B layout" },
      ],
    });
    const open = await shim.request("mod.open_ask", { session_id: "s2" });
    expect(open.result).toMatchObject({ open: true });
    expect(await hook("Stop", { session_id: "s2", last_assistant_message: ASKS })).toBe("");
  });

  test("Stop: the daemon is down, so the stop goes through and nothing starts", async () => {
    const h = home();
    process.env.KNOCK_HOME = h;
    expect(await hook("Stop", { session_id: "s3", last_assistant_message: ASKS })).toBe("");
    expect(existsSync(join(h, "knock.sock"))).toBe(false);
  });

  test("Stop: bad input fails open", async () => {
    process.env.KNOCK_HOME = home();
    expect(await runClaudeHook("Stop", "not json")).toBe(0);
    expect(await runClaudeHook("Stop", "[]")).toBe(0);
    expect(await runClaudeHook("Nope", "{}")).toBe(0);
  });

  test("SessionStart: context for compact and resume, nothing for startup", async () => {
    process.env.KNOCK_HOME = home();
    const out = JSON.parse(await hook("SessionStart", { session_id: "s", source: "compact" }));
    expect(out.hookSpecificOutput.additionalContext).toBe(RESUME_REMINDER);
    expect(await hook("SessionStart", { session_id: "s", source: "resume" })).not.toBe("");
    expect(await hook("SessionStart", { session_id: "s", source: "startup" })).toBe("");
  });

  test("settings: catchQuestions defaults on; off writes the marker; on removes it", async () => {
    const d = await withDaemon();
    const app = await d.connect();
    expect((await app.request("settings.get", { key: "catchQuestions" })).result).toEqual({ key: "catchQuestions", value: "on" });
    await app.request("settings.set", { key: "catchQuestions", value: "off" });
    expect(existsSync(join(d.home, CATCH_QUESTIONS_OFF_FILE))).toBe(true);
    expect((await app.request("settings.get", { key: "catchQuestions" })).result).toEqual({ key: "catchQuestions", value: "off" });
    expect(await hook("Stop", { session_id: "s", last_assistant_message: ASKS })).toBe("");
    await app.request("settings.set", { key: "catchQuestions", value: "on" });
    expect(existsSync(join(d.home, CATCH_QUESTIONS_OFF_FILE))).toBe(false);
  });
});

describe("sessionStartOutput with open asks (WAG-268)", () => {
  test("names the open case ids after the reminder", () => {
    const out = sessionStartOutput({ source: "compact" }, ["c_1", "c_2"]) as {
      hookSpecificOutput: { additionalContext: string };
    };
    expect(out.hookSpecificOutput.additionalContext).toStartWith(RESUME_REMINDER);
    expect(out.hookSpecificOutput.additionalContext).toContain("Your open asks are c_1, c_2.");
    expect(out.hookSpecificOutput.additionalContext).toContain("waggle_check");
  });

  test("a fresh start still gets nothing", () => {
    expect(sessionStartOutput({ source: "startup" }, ["c_1"])).toBeNull();
  });
});

// WAG-273: the stop check follows Settings > Requests.
describe("stopDecision follows the Requests choices", () => {
  const ANY = { scope: "any" as const, picked: [] };
  const PICK = { scope: "pick" as const, picked: ["design" as const] };
  const QUICK = "Should I use tabs?";
  const OPTIONS = "Two layouts:\n\n- A: tabs\n- B: spaces\n\nWhich one do you want?";
  const BLOCKED = "Before I continue, which layout do you want?";

  async function blocked(message: string, prefs?: Parameters<typeof writeHookAskPrefs>[1]): Promise<boolean> {
    const h = home();
    if (prefs) writeHookAskPrefs(h, prefs);
    const out = await stopDecision({ input: { last_assistant_message: message }, home: h, hasOpenAsk: async () => false });
    return out !== null;
  }

  test("no file: blocks as before", async () => {
    expect(await blocked(QUICK)).toBe(true);
  });

  test("reach off never blocks", async () => {
    const prefs = { reach: "off" as const, topics: ANY, frequency: "chat" as const };
    expect(await blocked(OPTIONS, prefs)).toBe(false);
    expect(await blocked(QUICK, prefs)).toBe(false);
  });

  test("reach everything blocks, quick questions too", async () => {
    const prefs = { reach: "everything" as const, topics: ANY, frequency: "chat" as const };
    expect(await blocked(QUICK, prefs)).toBe(true);
    expect(await blocked(OPTIONS, prefs)).toBe(true);
  });

  test("visual and written let a quick question through, and block one with options", async () => {
    for (const reach of ["visual", "written"] as const) {
      const prefs = { reach, topics: ANY, frequency: "chat" as const };
      expect(await blocked(QUICK, prefs)).toBe(false);
      expect(await blocked(OPTIONS, prefs)).toBe(true);
    }
  });

  test("picked topics let a quick question through", async () => {
    const prefs = { reach: "everything" as const, topics: PICK, frequency: "chat" as const };
    expect(await blocked(QUICK, prefs)).toBe(false);
    expect(await blocked(OPTIONS, prefs)).toBe(true);
  });

  test("only when blocked: blocks only a message that says it cannot go on", async () => {
    const prefs = { reach: "everything" as const, topics: ANY, frequency: "blocked" as const };
    expect(await blocked(OPTIONS, prefs)).toBe(false);
    expect(await blocked(BLOCKED, prefs)).toBe(true);
  });

  test("a bad or unreadable file fails open to today's behaviour", async () => {
    const h = home();
    writeFileSync(join(h, ASK_PREFS_FILE), "{not json");
    expect(readHookAskPrefs(h)).toBeUndefined();
    const out = await stopDecision({ input: { last_assistant_message: QUICK }, home: h, hasOpenAsk: async () => false });
    expect(out).not.toBeNull();
    writeFileSync(join(h, ASK_PREFS_FILE), JSON.stringify({ reach: "nope" }));
    expect(readHookAskPrefs(h)).toBeUndefined();
  });

  test("the daemon writes the file at start and on each change", async () => {
    const h = home();
    process.env.KNOCK_HOME = h;
    const store = new Store(new Database(join(h, "knock.db")), h, new EventBus());
    const server = startRpcServer({ socketPath: join(h, "k.sock"), store, bus: new EventBus(), version: pkg.version });
    servers.push(server);
    expect(readHookAskPrefs(h)?.reach).toBe("everything");
    const client = await rpcConnect(join(h, "k.sock"));
    clients.push(client);
    await client.request("settings.set", { key: "askReach", value: "visual" });
    expect(readHookAskPrefs(h)?.reach).toBe("visual");
    await client.request("settings.set", { key: "askFrequency", value: "blocked" });
    expect(readHookAskPrefs(h)?.frequency).toBe("blocked");
    await client.request("settings.set", { key: "askTopics", value: PICK });
    expect(readHookAskPrefs(h)?.topics).toEqual(PICK);
  });
});
