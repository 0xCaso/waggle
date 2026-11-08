import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EventBus } from "../src/events";
import { startRpcServer, type RpcServer } from "../src/server";
import {
  cwdSlug,
  findTranscript,
  firstSentence,
  goalOf,
  humanizeCommand,
  isGrowing,
  parseLines,
  parseTranscriptText,
  plain,
  readTranscript,
  sessionContext,
} from "../src/sessions/context";
import { gitFootprint } from "../src/sessions/footprint";
import { Store } from "../src/store";
import { rmrf, rpcConnect, tmpHome } from "./helpers";

const dirs: string[] = [];
const servers: RpcServer[] = [];
const savedProjects = process.env.KNOCK_CLAUDE_PROJECTS;

afterEach(() => {
  for (const s of servers.splice(0)) s.stop();
  for (const d of dirs.splice(0)) rmrf(d);
  process.env.KNOCK_CLAUDE_PROJECTS = savedProjects;
});

function tmp(): string {
  const d = mkdtempSync(join(tmpdir(), "knock-ctx-"));
  dirs.push(d);
  return d;
}

const line = (o: object) => JSON.stringify(o);
const asst = (blocks: object[], at = "2026-09-30T10:00:00.000Z") =>
  line({ type: "assistant", timestamp: at, message: { role: "assistant", content: blocks } });
const tool = (name: string, input: object) => ({ type: "tool_use", name, input });
const user = (content: unknown, extra: object = {}) =>
  line({ type: "user", turnOrigin: "human", message: { role: "user", content }, ...extra });

const TRANSCRIPT = [
  line({ type: "summary", whatever: 1 }),
  line({ type: "some-future-record", data: [1, 2, 3] }),
  user("<system-reminder>ignore me</system-reminder>", { isMeta: true }),
  user("Show what each **live session** is working on in the `Sessions` popover, please."),
  line({ type: "ai-title", aiTitle: "Session context in the popover" }),
  asst([tool("TodoWrite", { todos: [
    { content: "Read code", activeForm: "Reading code", status: "completed" },
    { content: "Write parser", activeForm: "Writing the parser", status: "in_progress" },
    { content: "Ship", activeForm: "Shipping", status: "pending" },
  ] })]),
  asst([tool("Read", { file_path: "/a/b/Foo.swift" })], "2026-09-30T10:01:00.000Z"),
  asst([tool("Bash", { command: "fleet board 2>&1 | grep -E 'a|b'" })], "2026-09-30T10:02:00.000Z"),
  asst([tool("Bash", { command: "ls -la /x | wc -l", description: "Count the files" })], "2026-09-30T10:03:00.000Z"),
  asst([{ type: "text", text: "**Done** with the parser. Next I will wire it up." }, tool("Edit", { file_path: "/a/Bar.ts" })], "2026-09-30T10:04:00.000Z"),
].join("\n");

describe("plain text helpers", () => {
  test("strips markers and takes the first sentence", () => {
    expect(plain("**Bold** and `code`, _it_ [link](http://x.y) ![img](a.png)")).toBe("Bold and code, it link img");
    expect(plain("- one\n- two\n\n## Head")).toBe("one two Head");
    expect(firstSentence("First one. Second one.")).toBe("First one.");
    expect(firstSentence("No end")).toBe("No end");
  });

  test("humanises shell commands: no pipes, redirects or flags", () => {
    expect(humanizeCommand("fleet board 2>&1 | grep -E 'x|y'")).toBe("Ran fleet board");
    expect(humanizeCommand("cd /a && swift test --filter Foo")).toBe("Ran swift test");
    expect(humanizeCommand("FOO=1 /usr/bin/git commit -m \"hi there\" > out.txt")).toBe("Ran git commit");
    expect(humanizeCommand("cat <<'EOF'\nhello\nEOF")).toBe("Ran a small script");
    expect(humanizeCommand("")).toBe("Ran a command");
  });

  test("humanizeCommand unwraps perl, env, timeout and bash -c", () => {
    expect(humanizeCommand("perl -e 'alarm 1200; exec @ARGV' swift test")).toBe("Ran swift test");
    expect(humanizeCommand("cd app && perl -e 'alarm 1200; exec @ARGV' swift test --filter X")).toBe("Ran swift test");
    expect(humanizeCommand("env FOO=1 BAR=2 bun test")).toBe("Ran bun test");
    expect(humanizeCommand("timeout 30 git status")).toBe("Ran git status");
    expect(humanizeCommand("bash -c 'cd x && npm run build'")).toBe("Ran npm run build");
    expect(humanizeCommand("env -u KNOCK_HOME timeout 60 bun test")).toBe("Ran bun test");
    expect(humanizeCommand("perl -e 'alarm 5; exec @ARGV' bash -lc \"swift build\"")).toBe("Ran swift build");
  });
});

describe("transcript parser", () => {
  const recs = parseLines(TRANSCRIPT, false, false);
  const facts = parseTranscriptText(recs, recs);

  test("title, goal, last sentence, action trail and plan", () => {
    expect(facts.title).toBe("Session context in the popover");
    expect(facts.goal).toBe("Show what each live session is working on in the Sessions popover, please.");
    expect(facts.said).toBe("Done with the parser.");
    expect(facts.last_action).toBe("Edited Bar.ts");
    expect(facts.last_action_at).toBe("2026-09-30T10:04:00.000Z");
    expect(facts.recent).toEqual(["Ran fleet board", "Count the files", "Edited Bar.ts"]);
    expect(facts.plan).toEqual({ done: 1, total: 3, current: "Writing the parser" });
  });

  test("a truncated last line and unknown records are ignored", () => {
    const cut = parseLines(TRANSCRIPT + "\n" + asst([tool("Read", { file_path: "/z/Last.swift" })]).slice(0, 40), false, false);
    expect(cut.length).toBe(recs.length);
    expect(parseTranscriptText(cut, cut).last_action).toBe("Edited Bar.ts");
  });

  test("a sidechain prompt and a tool result are not the goal", () => {
    const r = parseLines(
      [user("sidechain prompt here", { isSidechain: true }), user([{ type: "tool_result", content: "x" }]), user("The real goal text")].join("\n"),
      false,
      false,
    );
    expect(parseTranscriptText(r, r).goal).toBe("The real goal text");
  });

  test("an empty transcript gives empty facts", () => {
    expect(parseTranscriptText([], [])).toEqual({
      title: null, goal: null, said: null, last_action: null, last_action_at: null, recent: [], plan: null,
    });
  });

  test("a huge file reads only the head and tail, and caches by size and mtime", () => {
    const dir = tmp();
    const file = join(dir, "big.jsonl");
    const filler = line({ type: "user", isMeta: true, message: { content: "x".repeat(1000) } });
    const body = [user("Head goal is here"), ...Array(4000).fill(filler), line({ type: "ai-title", aiTitle: "Tail title" }), asst([tool("Read", { file_path: "/q/End.ts" })])].join("\n");
    writeFileSync(file, body);
    const first = readTranscript(file);
    expect(first?.goal).toBe("Head goal is here");
    expect(first?.title).toBe("Tail title");
    expect(first?.last_action).toBe("Read End.ts");
    expect(readTranscript(file)).toBe(first!); // same object: cache hit
    writeFileSync(file, body + "\n" + asst([tool("Read", { file_path: "/q/Newer.ts" })]));
    expect(readTranscript(file)?.last_action).toBe("Read Newer.ts");
  });

  test("a missing or unreadable file gives null", () => {
    expect(readTranscript(join(tmp(), "none.jsonl"))).toBeNull();
    expect(readTranscript(tmp())).toBeNull(); // a directory
  });
});

describe("transcript lookup", () => {
  test("the slug replaces every non-alphanumeric character with a dash", () => {
    expect(cwdSlug("/Users/a b/.fleet/wt/HAIL-72")).toBe("-Users-a-b--fleet-wt-HAIL-72");
  });

  test("exact by session id, else the newest file that is still growing", () => {
    const root = tmp();
    const cwd = "/work/proj.x";
    const dir = join(root, cwdSlug(cwd));
    mkdirSync(dir, { recursive: true });
    const now = Date.now();
    const put = (name: string, ageMs: number, body = "{}") => {
      writeFileSync(join(dir, name), body);
      utimesSync(join(dir, name), new Date(now - ageMs), new Date(now - ageMs));
    };
    put("old.jsonl", 60 * 60_000);
    put("mid.jsonl", 30_000);
    put("new.jsonl", 5_000);
    put("empty.jsonl", 1_000, "");
    expect(findTranscript("new", cwd, root, now)).toEqual({ path: join(dir, "new.jsonl"), how: "session-id" });
    expect(findTranscript("old", cwd, root, now)?.how).toBe("session-id");
    expect(findTranscript("unknown-uuid", cwd, root, now)).toEqual({ path: join(dir, "new.jsonl"), how: "cwd-newest" });
    expect(findTranscript("x", "/nowhere", root, now)).toBeNull();
    expect(findTranscript("../../etc/passwd", cwd, root, now)?.how).toBe("cwd-newest");
  });

  test("a folder whose files are all stale gives null", () => {
    const root = tmp();
    const dir = join(root, cwdSlug("/w"));
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "a.jsonl"), "{}");
    utimesSync(join(dir, "a.jsonl"), new Date(0), new Date(0));
    expect(findTranscript("nope", "/w", root)).toBeNull();
  });
});

describe("git footprint", () => {
  const git = (cwd: string, ...a: string[]) =>
    execFileSync("git", ["-C", cwd, "-c", "user.email=t@t", "-c", "user.name=t", ...a], { stdio: "ignore" });

  test("counts changed files and lines, and names the last commit", async () => {
    const repo = tmp();
    git(repo, "init", "-q");
    writeFileSync(join(repo, "a.txt"), "one\ntwo\n");
    git(repo, "add", ".");
    git(repo, "commit", "-q", "-m", "First commit");
    expect(await gitFootprint(repo)).toEqual({ files: 0, added: 0, removed: 0, clean: true, last_commit: "First commit" });
    writeFileSync(join(repo, "a.txt"), "one\nthree\nfour\n");
    writeFileSync(join(repo, "new.txt"), "n\n");
    expect(await gitFootprint(repo)).toEqual({ files: 2, added: 2, removed: 1, clean: false, last_commit: "First commit" });
  });

  test("null for a folder that is not a repository, or is missing", async () => {
    expect(await gitFootprint(tmp())).toBeNull();
    expect(await gitFootprint(join(tmp(), "gone"))).toBeNull();
  });
});

describe("sessions.list context", () => {
  function setup(): { home: string } {
    const home = tmpHome();
    dirs.push(home);
    const bus = new EventBus();
    const store = new Store(new Database(join(home, "knock.db")), home, bus);
    servers.push(startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0" }));
    return { home };
  }

  test("a live Claude session gets context; Codex and a session without a transcript get null; a malformed file never fails the list", async () => {
    const root = tmp();
    process.env.KNOCK_CLAUDE_PROJECTS = root; // a fake ~/.claude/projects under a temp dir
    const cwd = tmp();
    const dir = join(root, cwdSlug(cwd));
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "sess-claude.jsonl"), TRANSCRIPT);
    const cwd2 = tmp();
    mkdirSync(join(root, cwdSlug(cwd2)), { recursive: true });
    writeFileSync(join(root, cwdSlug(cwd2), "sess-bad.jsonl"), "\u0000\u0001 not json {{{\n{\"type\":");

    const { home } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    const hello = (session_id: string, cwd: string, runtime: string) =>
      client.request("session.hello", { session_id, cwd, parent_pid: process.pid, runtime });
    await hello("sess-claude", cwd, "claude");
    await hello("sess-codex", cwd, "codex");
    await hello("sess-none", tmp(), "claude");
    await hello("sess-bad", cwd2, "claude");

    const res = await client.request("sessions.list", {});
    expect(res.error).toBeUndefined();
    const byId = Object.fromEntries((res.result as any[]).map((s) => [s.id, s]));
    expect(byId["sess-claude"].context.title).toBe("Session context in the popover");
    expect(byId["sess-claude"].context.plan.done).toBe(1);
    expect(byId["sess-codex"].context).toBeNull();
    expect(byId["sess-none"].context).toBeNull();
    expect(byId["sess-bad"].context).toBeNull();
    client.close();
  });

  test("the footprint in session.hello shows as context.changes; a hello without one keeps the last value (HAIL-222)", async () => {
    const root = tmp();
    process.env.KNOCK_CLAUDE_PROJECTS = root;
    const cwd = tmp();
    const dir = join(root, cwdSlug(cwd));
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "sess-fp.jsonl"), TRANSCRIPT);
    const { home } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    const changes = { files: 3, added: 10, removed: 2, clean: false, last_commit: "Add a thing" };
    const hello = (extra: object) =>
      client.request("session.hello", { session_id: "sess-fp", cwd, parent_pid: process.pid, ...extra });
    const list = async () =>
      ((await client.request("sessions.list", {})).result as any[]).find((s) => s.id === "sess-fp").context;
    await hello({});
    expect((await list()).changes).toBeNull(); // the daemon never reads git itself, even for a real repo
    await hello({ changes });
    expect((await list()).changes).toEqual(changes);
    await hello({}); // an older shim omits it
    expect((await list()).changes).toEqual(changes);
    await hello({ changes: null }); // the shim says: not a repository
    expect((await list()).changes).toBeNull();
    client.close();
  });

  test("sessionContext never throws for odd input", async () => {
    expect(await sessionContext({ id: "x", cwd: "", runtime: "claude", state: "live" })).toBeNull();
    expect(await sessionContext({ id: "x", cwd: "/a", runtime: "claude", state: "ended" })).toBeNull();
  });
});

describe("goal of a headless prompt (HAIL-124)", () => {
  const brief = [
    "# Brief for HAIL-123",
    "",
    "```text",
    "run this first",
    "```",
    "",
    "Objective: Agents can send \"pick several\" asks; the operator ticks options and sends them together.",
    "",
    "## Paths",
  ].join("\n");

  test("an Objective line wins", () => {
    expect(goalOf(brief)).toBe('Agents can send "pick several" asks; the operator ticks options and sends them together.');
  });

  test("without Objective, headings, fences and empty lines are skipped", () => {
    expect(goalOf("# Title\n\n```\ncode\n```\n\nFix the **popover** layout.\n## More")).toBe("Fix the popover layout.");
    expect(goalOf("# Only a heading\n```\nx\n```")).toBeNull();
  });

  test("a plain prompt is unchanged", () => {
    expect(goalOf("Show what each live session is working on.")).toBe("Show what each live session is working on.");
  });

  test("the transcript parser uses it, and ai-title still comes first", () => {
    const head = [JSON.parse(user(brief))];
    expect(parseTranscriptText(head, head).goal).toStartWith("Agents can send");
    const titled = [...head, { type: "ai-title", aiTitle: "My title" }];
    expect(parseTranscriptText(titled, titled).title).toBe("My title");
  });
});

describe("growing flag (HAIL-124)", () => {
  test("a recent write or a recent action means growing", () => {
    const root = tmp();
    const file = join(root, "t.jsonl");
    writeFileSync(file, "{}");
    const now = Date.now();
    utimesSync(file, new Date(now - 10_000), new Date(now - 10_000));
    expect(isGrowing(file, null, now)).toBe(true);
    utimesSync(file, new Date(now - 10 * 60_000), new Date(now - 10 * 60_000));
    expect(isGrowing(file, null, now)).toBe(false);
    expect(isGrowing(file, new Date(now - 30_000).toISOString(), now)).toBe(true);
    expect(isGrowing(file, new Date(now - 5 * 60_000).toISOString(), now)).toBe(false);
    expect(isGrowing(join(root, "missing.jsonl"), "not a date", now)).toBe(false);
  });

  test("sessionContext carries it", async () => {
    const root = tmp();
    const cwd = "/work/grow";
    const dir = join(root, cwdSlug(cwd));
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "s1.jsonl"), [user("Build the thing for me"), asst([tool("Read", { file_path: "/a/B.swift" })])].join("\n") + "\n");
    const ctx = await sessionContext({ id: "s1", cwd, runtime: "claude", state: "live" }, { root });
    expect(ctx?.growing).toBe(true);
  });
});
