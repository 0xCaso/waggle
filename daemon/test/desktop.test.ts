import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { Database } from "bun:sqlite";
import { mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { Artifact, RUNTIME_NOTES, instructionsFor, KnockAskInput } from "../src/protocol";
import { DEFAULT_ASK_PREFERENCES, askAgentText } from "../src/guide/asks";
import { DESKTOP_GUIDE_SECTION, DESKTOP_RUNTIME_NOTE } from "../src/guide/desktop";
import { decodeScreenshotBase64 } from "../src/artifacts";
import { clientNameFor, isClaudeCodeClient, isDesktopSession, pendingText } from "../src/mcp/shim";
import pkg from "../package.json" with { type: "json" };
import { rmrf, tmpHome } from "./helpers";

// HAIL-163: Waggle from the Claude desktop app and Cowork. The shim runs with no CLAUDE_CODE_*
// variable and cwd "/": inline artifacts, a topic that names the task, and the desktop guide.

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const tinyPng = (label: string) => Buffer.concat([PNG_SIG, Buffer.from(label)]).toString("base64");

const question = {
  kind: "question",
  title: "Pick a subject line",
  need: "Pick a subject line",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is short",
  options: [
    { id: "a", label: "Short" },
    { id: "b", label: "Long" },
  ],
};

const homes: string[] = [];
const servers: RpcServer[] = [];
const clients: { client: Client; transport: StdioClientTransport }[] = [];

afterEach(async () => {
  for (const c of clients.splice(0)) {
    try {
      await c.transport.close();
      await c.client.close();
    } catch {
      // Already closed.
    }
  }
  for (const server of servers.splice(0)) server.stop();
  for (const home of homes.splice(0)) rmrf(home);
});

function setup(): { home: string; store: Store } {
  const home = tmpHome();
  homes.push(home);
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  servers.push(
    startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: pkg.version }),
  );
  return { home, store };
}

// `claudeCode` true adds the variable Claude Code sets; false is the desktop app (an empty environment).
async function startShim(
  home: string,
  cwd: string,
  claudeCode: boolean,
  env: Record<string, string> = {},
  clientName = "knock-test",
) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(import.meta.dir, "..", "src", "index.ts"), "mcp"],
    env: {
      KNOCK_HOME: home,
      KNOCK_ASK_WAIT_MS: "300",
      ...(claudeCode ? { CLAUDE_CODE_SESSION_ID: `sess-${Math.random()}` } : {}),
      ...env,
    },
    cwd,
    stderr: "pipe",
  });
  const client = new Client({ name: clientName, version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);
  clients.push({ client, transport });
  return client;
}

type ToolResult = Awaited<ReturnType<Client["callTool"]>>;
function textOf(result: ToolResult): string {
  if (!("content" in result)) return "";
  return (result.content as { type: string; text?: string }[])
    .filter((c) => c.type === "text")
    .map((c) => c.text ?? "")
    .join("\n");
}
function caseIdOf(result: ToolResult): string {
  const match = textOf(result).match(/case_id":"(c_[^"]+)"/);
  if (!match) throw new Error(`no case id: ${textOf(result)}`);
  return match[1];
}

describe("desktop flavour", () => {
  test("a desktop session gets the desktop note, a Claude Code session today's text", async () => {
    const { home } = setup();
    const desktop = await startShim(home, "/", false);
    const claudeCode = await startShim(home, "/", true);
    const asks = askAgentText(DEFAULT_ASK_PREFERENCES);

    expect(desktop.getInstructions()).toBe(instructionsFor("claude", asks, true));
    expect(desktop.getInstructions()).toContain("keep calling waggle_check");
    expect(desktop.getInstructions()).toContain("not as paths");
    expect(desktop.getInstructions()).toContain("Pass a topic");
    expect(desktop.getInstructions()).toContain("paste the line Waggle gives you here so I can continue");
    expect(desktop.getInstructions()).not.toContain(RUNTIME_NOTES.claude);

    expect(claudeCode.getInstructions()).toBe(instructionsFor("claude", asks));
    expect(claudeCode.getInstructions()).toContain(RUNTIME_NOTES.claude);
    expect(claudeCode.getInstructions()).not.toContain(DESKTOP_RUNTIME_NOTE);
  });

  test("a codex session keeps its own note", async () => {
    const { home } = setup();
    const codex = await startShim(home, "/", false, { KNOCK_RUNTIME: "codex" });
    expect(codex.getInstructions()).toContain(RUNTIME_NOTES.codex);
    expect(codex.getInstructions()).not.toContain(DESKTOP_RUNTIME_NOTE);
  });

  test("isDesktopSession needs claude, no nudge and no CLAUDE_CODE_ variable", () => {
    const state = { runtime: "claude" as const, nudge: { canNudge: false } };
    expect(isDesktopSession(state, { PATH: "/usr/bin" })).toBe(true);
    expect(isDesktopSession(state, { CLAUDE_CODE_SESSION_ID: "x" })).toBe(false);
    expect(isDesktopSession({ ...state, nudge: { canNudge: true } }, {})).toBe(false);
    expect(isDesktopSession({ ...state, runtime: "codex" as never }, {})).toBe(false);
  });

  test("waggle_guide for a desktop session adds the desktop section to the index and artifacts", async () => {
    const { home } = setup();
    const desktop = await startShim(home, "/", false);
    const claudeCode = await startShim(home, "/", true);

    for (const args of [{}, { topic: "artifacts" }]) {
      const d = textOf(await desktop.callTool({ name: "waggle_guide", arguments: args }));
      expect(d).toContain(DESKTOP_GUIDE_SECTION);
      expect(d).toContain("Keep calling waggle_check until the reply arrives");
      expect(d).toContain("Send artifacts as content");
      expect(d).toContain("Pass a topic");
      expect(d).toContain("When you answer in Waggle, paste the line Waggle gives you here so I can continue.");
      const c = textOf(await claudeCode.callTool({ name: "waggle_guide", arguments: args }));
      expect(c).not.toContain("Desktop app note");
    }
    // Other topics are the same for both.
    const a = textOf(await desktop.callTool({ name: "waggle_guide", arguments: { topic: "reviews" } }));
    const b = textOf(await claudeCode.callTool({ name: "waggle_guide", arguments: { topic: "reviews" } }));
    expect(a).toBe(b);
  });
});

describe("inline artifacts", () => {
  test("markdown content stages as revision 1 and keeps its text", async () => {
    const { home, store } = setup();
    const client = await startShim(home, "/", false);
    const result = await client.callTool({
      name: "waggle_ask",
      arguments: { ...question, kind: "review", artifact: { type: "markdown", content: "# Plan\n\nHello" } },
    });
    expect(result.isError).toBeFalsy();
    const id = caseIdOf(result);
    const detail = store.getCase(id)!;
    expect(detail.revisions.map((r) => r.n)).toEqual([1]);
    expect(detail.case.artifact_kind).toBe("markdown");
    expect(readFileSync(store.artifactPath(id, 1)!.root, "utf8")).toBe("# Plan\n\nHello");
  });

  test("an html string stages as a one-file bundle with its viewport", async () => {
    const { home, store } = setup();
    const client = await startShim(home, "/", false);
    const html = "<!doctype html><title>x</title><h1>Hi</h1>";
    const result = await client.callTool({
      name: "waggle_ask",
      arguments: {
        ...question,
        kind: "review",
        artifact: { type: "html_bundle", html, viewport: { width: 390, height: 844 } },
      },
    });
    expect(result.isError).toBeFalsy();
    const id = caseIdOf(result);
    const path = store.artifactPath(id, 1)!;
    expect(path.kind).toBe("html_bundle");
    expect(readFileSync(path.entry, "utf8")).toBe(html);
  });

  test("a base64 screenshot and a screenshots gallery stage", async () => {
    const { home, store } = setup();
    const client = await startShim(home, "/", false);
    const one = await client.callTool({
      name: "waggle_ask",
      arguments: { ...question, kind: "review", artifact: { type: "screenshot", data_base64: tinyPng("a") } },
    });
    expect(store.getCase(caseIdOf(one))!.case.artifact_kind).toBe("screenshot");

    const many = await client.callTool({
      name: "waggle_ask",
      arguments: {
        ...question,
        title: "Pick a gallery",
        kind: "review",
        artifact: {
          type: "screenshots",
          items: [{ data_base64: `data:image/png;base64,${tinyPng("b")}`, caption: "one" }, { data_base64: tinyPng("c") }],
        },
      },
    });
    expect(many.isError).toBeFalsy();
    const gallery = store.artifactPath(caseIdOf(many), 1)!;
    expect(gallery.items?.length).toBe(2);
    expect(gallery.items?.[0]?.caption).toBe("one");
  });

  test("a bad image, an empty html string and oversize markdown are rejected, with no case", async () => {
    const { home, store } = setup();
    const client = await startShim(home, "/", false);
    const bad = async (artifact: unknown) => {
      const r = await client.callTool({ name: "waggle_ask", arguments: { ...question, kind: "review", artifact } });
      expect(r.isError).toBe(true);
      return textOf(r);
    };
    expect(await bad({ type: "screenshot", data_base64: "!!!not base64!!!" })).toContain("not valid base64");
    expect(await bad({ type: "screenshot", data_base64: Buffer.from("hello world").toString("base64") })).toContain(
      "not a PNG or JPEG",
    );
    expect(await bad({ type: "html_bundle", html: "   " })).toContain("html must not be empty");
    expect(await bad({ type: "markdown", content: "x".repeat(1024 * 1024 + 1) })).toContain("larger than 1 MB");
    expect(store.listCases("needs_you")).toEqual([]);
  });

  test("decodeScreenshotBase64 holds the 20 MB limit on the decoded bytes", () => {
    const big = Buffer.concat([PNG_SIG, Buffer.alloc(20 * 1024 * 1024)]).toString("base64");
    expect(() => decodeScreenshotBase64(big)).toThrow("screenshot is larger than 20 MB");
    expect(() => decodeScreenshotBase64(big, "screenshot 2")).toThrow("screenshot 2 is larger than 20 MB");
    expect(decodeScreenshotBase64(tinyPng("ok")).ext).toBe("png");
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]).toString("base64");
    expect(decodeScreenshotBase64(jpeg).ext).toBe("jpg");
  });

  test("waggle_update takes inline content for a new revision", async () => {
    const { home, store } = setup();
    const client = await startShim(home, "/", false);
    const id = caseIdOf(
      await client.callTool({
        name: "waggle_ask",
        arguments: { ...question, kind: "review", artifact: { type: "markdown", content: "v1" } },
      }),
    );
    const updated = await client.callTool({
      name: "waggle_update",
      arguments: { case_id: id, message: "Changed it", artifact: { type: "markdown", content: "v2" } },
    });
    expect(updated.isError).toBeFalsy();
    expect(store.getCase(id)!.revisions.map((r) => r.n)).toEqual([1, 2]);
    expect(readFileSync(store.artifactPath(id, 2)!.root, "utf8")).toBe("v2");
  });

  test("paths keep working for a Claude Code session", async () => {
    const { home, store } = setup();
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });
    Bun.write(join(cwd, "note.md"), "from a file");
    await Bun.sleep(20);
    const client = await startShim(home, cwd, true);
    const id = caseIdOf(
      await client.callTool({
        name: "waggle_ask",
        arguments: { ...question, kind: "review", artifact: { type: "markdown", path: "note.md" } },
      }),
    );
    expect(readFileSync(store.artifactPath(id, 1)!.root, "utf8")).toBe("from a file");
  });

  test("the schema takes exactly one form", () => {
    const ok = (a: unknown) => Artifact.safeParse(a).success;
    expect(ok({ type: "markdown", path: "a.md" })).toBe(true);
    expect(ok({ type: "markdown", content: "x" })).toBe(true);
    expect(ok({ type: "markdown" })).toBe(false);
    expect(ok({ type: "markdown", path: "a.md", content: "x" })).toBe(false);
    expect(ok({ type: "screenshot", path: "a.png" })).toBe(true);
    expect(ok({ type: "screenshot", data_base64: "AAAA" })).toBe(true);
    expect(ok({ type: "screenshot", path: "a.png", data_base64: "AAAA" })).toBe(false);
    expect(ok({ type: "html_bundle", dir: "d", entry: "index.html" })).toBe(true);
    expect(ok({ type: "html_bundle", html: "<p>x</p>" })).toBe(true);
    expect(ok({ type: "html_bundle", dir: "d" })).toBe(false);
    expect(ok({ type: "html_bundle", html: "<p>x</p>", dir: "d", entry: "i.html" })).toBe(false);
    expect(ok({ type: "html_bundle", html: "<p>x</p>", preview: "p.html" })).toBe(false);
    expect(ok({ type: "screenshots", items: [{ path: "a.png" }, { data_base64: "AAAA" }] })).toBe(true);
    expect(ok({ type: "screenshots", items: [{ path: "a.png" }, {}] })).toBe(false);
  });

  test("the daemon refuses inline content that did not come through the shim", () => {
    const { store } = setup();
    store.createTask({ id: "t_x", name: "n", project: "p" });
    expect(() =>
      store.createCase("t_x", { ...question, kind: "review", artifact: { type: "markdown", content: "x" } } as KnockAskInput),
    ).toThrow(/staged by the shim/);
  });
});

describe("topic outside git", () => {
  test("the topic names the task and project, and the same topic groups together", async () => {
    const { home, store } = setup();
    const client = await startShim(home, "/", false);
    const ask = (topic?: string) =>
      client.callTool({ name: "waggle_ask", arguments: { ...question, ...(topic ? { topic } : {}) } });

    const a = store.getCase(caseIdOf(await ask("Syllotips launch email")))!.case;
    const b = store.getCase(caseIdOf(await ask("syllotips LAUNCH email")))!.case;
    const c = store.getCase(caseIdOf(await ask("Interview synthesis")))!.case;
    const plain = store.getCase(caseIdOf(await ask()))!.case;

    expect(a.task_name).toBe("Syllotips launch email");
    expect(a.project).toBe("Syllotips launch email");
    expect(b.task_id).toBe(a.task_id);
    expect(c.task_id).not.toBe(a.task_id);
    expect(c.task_name).toBe("Interview synthesis");
    // No topic: today's blank names, in the session's own task.
    expect(plain.task_name).toBe("");
    expect(plain.task_id).not.toBe(a.task_id);
  });

  test("the session can check, update and follow up its topic cases", async () => {
    const { home, store } = setup();
    const client = await startShim(home, "/", false);
    const id = caseIdOf(
      await client.callTool({ name: "waggle_ask", arguments: { ...question, topic: "Launch email" } }),
    );
    // Another topic in between must not break ownership of the first.
    await client.callTool({ name: "waggle_ask", arguments: { ...question, topic: "Other job" } });

    const checked = await client.callTool({ name: "waggle_check", arguments: { case_id: id } });
    expect(checked.isError).toBeFalsy();
    expect(textOf(checked)).toContain("pending");
    const updated = await client.callTool({ name: "waggle_update", arguments: { case_id: id, message: "More" } });
    expect(updated.isError).toBeFalsy();
    // follows without a topic stays in the followed case's task.
    const follow = caseIdOf(
      await client.callTool({ name: "waggle_ask", arguments: { ...question, follows: id } }),
    );
    expect(store.getCase(follow)!.case.task_id).toBe(store.getCase(id)!.case.task_id);
  });

  test("a topic case is waiting-on-session aware: an ended session fails its queued reply", async () => {
    const { home, store } = setup();
    const client = await startShim(home, "/", false);
    const id = caseIdOf(
      await client.callTool({ name: "waggle_ask", arguments: { ...question, topic: "Launch email" } }),
    );
    const sessionId = store.listSessions()[0]!.id;
    expect(store.getCase(id)!.case.session_state).toBe("live");
    store.setSessionState(sessionId, "ended");
    expect(store.getCase(id)!.case.session_state).toBe("ended");
  });

  test("another session cannot check a topic case", async () => {
    const { home } = setup();
    const owner = await startShim(home, "/", false);
    const other = await startShim(home, "/", false);
    const id = caseIdOf(await owner.callTool({ name: "waggle_ask", arguments: { ...question, topic: "Mine" } }));
    const r = await other.callTool({ name: "waggle_check", arguments: { case_id: id } });
    expect(r.isError).toBe(true);
  });

  test("inside git the topic is ignored and the names do not change", async () => {
    const { home, store } = setup();
    const repo = join(home, "omea-web");
    mkdirSync(repo, { recursive: true });
    spawnSync("git", ["init", "-q", repo]);
    const client = await startShim(home, repo, true);
    const c = store.getCase(
      caseIdOf(await client.callTool({ name: "waggle_ask", arguments: { ...question, topic: "Some topic" } })),
    )!.case;
    expect(c.project).toBe("omea-web");
    expect(c.task_name).not.toBe("Some topic");
  });

  test("topic is optional and limited to 80 characters", () => {
    expect(KnockAskInput.safeParse({ ...question }).success).toBe(true);
    expect(KnockAskInput.safeParse({ ...question, topic: "x".repeat(81) }).success).toBe(false);
    expect(KnockAskInput.safeParse({ ...question, topic: "   " }).success).toBe(false);
  });
});

// HAIL-170: a desktop session cannot be woken, so a pending result says to call waggle_check again.
describe("desktop pending loop", () => {
  const FIRM = "Call waggle_check again now. Do not end your turn. Stop only if the result says the case is closed.";

  test("pending text: desktop is firm and names the wait, Claude Code is unchanged", () => {
    const pending = { status: "pending" as const, case_id: "c_1", waited_s: 135 };
    const desktop = pendingText(pending, "desktop");
    expect(desktop).toContain(FIRM);
    expect(desktop).toContain("waited 2 minutes");
    expect(pendingText({ ...pending, waited_s: 20 }, "desktop")).toContain("waited 20 seconds");
    expect(pendingText({ status: "pending", case_id: "c_1" }, "desktop")).toContain(FIRM);
    const code = pendingText(pending, "poll");
    expect(code).toContain("Call waggle_check with this case_id to get the human's reply.");
    expect(code).not.toContain("Do not end your turn");
  });

  test("waggle_ask and waggle_check pending, end to end, and the check time", async () => {
    const { home, store } = setup();
    const desktop = await startShim(home, "/", false);
    const claudeCode = await startShim(home, "/", true);

    const asked = await desktop.callTool({ name: "waggle_ask", arguments: { ...question, topic: "Launch email" } });
    expect(textOf(asked)).toContain(FIRM);
    expect(textOf(asked)).toMatch(/waited \d+ seconds/);
    const caseId = caseIdOf(asked);
    const checked = await desktop.callTool({ name: "waggle_check", arguments: { case_id: caseId } });
    expect(textOf(checked)).toContain(FIRM);

    const row = store.getCase(caseId)!.case;
    expect(row.last_check_at).not.toBeNull();
    expect(row.session_can_nudge).toBe(false);

    const code = await claudeCode.callTool({ name: "waggle_ask", arguments: question });
    expect(textOf(code)).toContain("Call waggle_check with this case_id to get the human's reply.");
    expect(textOf(code)).not.toContain("Do not end your turn");
  });
});

// HAIL-173: the MCP client name, and no style warnings in a desktop chat.
const longNeed = Array.from({ length: 25 }, (_, i) => `word${i}`).join(" ") + ".";

async function waitFor(check: () => boolean): Promise<void> {
  for (let i = 0; i < 100 && !check(); i++) await new Promise((r) => setTimeout(r, 50));
  expect(check()).toBe(true);
}

describe("client name (HAIL-173)", () => {
  test("the shim stores the MCP client name on its session", async () => {
    const { home, store } = setup();
    await startShim(home, "/", false, {}, "claude-ai");
    await waitFor(() => store.listSessions().some((s) => s.client_name === "claude-ai"));
    await startShim(home, "/", true, {}, "claude-code");
    await waitFor(() => store.listSessions().some((s) => s.client_name === "claude-code"));
  });

  test("the shim stores the Cowork client names unchanged (HAIL-186)", async () => {
    const { home, store } = setup();
    await startShim(home, "/", false, {}, "local-agent-mode-waggle");
    await waitFor(() => store.listSessions().some((s) => s.client_name === "local-agent-mode-waggle"));
    await startShim(home, "/", false, {}, "local-agent-mode-knock");
    await waitFor(() => store.listSessions().some((s) => s.client_name === "local-agent-mode-knock"));
  });

  test("a case carries its session's client name", async () => {
    const { home, store } = setup();
    const client = await startShim(home, "/", false, {}, "Claude Cowork");
    await waitFor(() => store.listSessions().some((s) => s.client_name === "Claude Cowork"));
    const id = caseIdOf(await client.callTool({ name: "waggle_ask", arguments: question }));
    expect(store.getCase(id)!.case.session_client_name).toBe("Claude Cowork");
    expect(store.listCases().find((c) => c.id === id)!.session_client_name).toBe("Claude Cowork");
  });

  test("clientNameFor and isClaudeCodeClient", () => {
    expect(clientNameFor({ runtime: "claude", clientName: "claude-ai" }, {})).toBe("claude-ai");
    expect(clientNameFor({ runtime: "claude", clientName: null }, { CLAUDE_CODE_SESSION_ID: "x" })).toBe("claude-code");
    expect(clientNameFor({ runtime: "claude", clientName: null }, {})).toBeUndefined();
    expect(clientNameFor({ runtime: "codex", clientName: null }, { CLAUDE_CODE_SESSION_ID: "x" })).toBeUndefined();
    expect(isClaudeCodeClient("claude-code")).toBe(true);
    expect(isClaudeCodeClient("claude-ai")).toBe(false);
    expect(isClaudeCodeClient(null)).toBe(false);
    const state = { runtime: "claude" as const, nudge: { canNudge: false } };
    expect(isDesktopSession({ ...state, clientName: "claude-code" }, {})).toBe(false);
    expect(isDesktopSession({ ...state, clientName: "claude-ai" }, {})).toBe(true);
  });
});

describe("style warnings (HAIL-173)", () => {
  const warnsOf = (text: string) => text.includes("ASD-STE100");

  test("a desktop client does not see the warning on waggle_ask or waggle_update", async () => {
    const { home } = setup();
    const client = await startShim(home, "/", false, {}, "claude-ai");
    const ask = await client.callTool({ name: "waggle_ask", arguments: { ...question, need: longNeed } });
    expect(warnsOf(textOf(ask))).toBe(false);
    const id = caseIdOf(ask);
    const update = await client.callTool({
      name: "waggle_update",
      arguments: {
        case_id: id,
        message: "More choices",
        options: Array.from({ length: 7 }, (_, i) => ({ id: `o${i}`, label: `Option ${i}` })),
        recommendation: "o0",
      },
    });
    expect(textOf(update)).toContain("updated");
    expect(warnsOf(textOf(update))).toBe(false);
  });

  test("a Claude Code client keeps the warning on waggle_ask and waggle_update", async () => {
    const { home } = setup();
    const client = await startShim(home, "/", true, {}, "claude-code");
    const ask = await client.callTool({ name: "waggle_ask", arguments: { ...question, need: longNeed } });
    expect(warnsOf(textOf(ask))).toBe(true);
    const update = await client.callTool({
      name: "waggle_update",
      arguments: {
        case_id: caseIdOf(ask),
        message: "More choices",
        options: Array.from({ length: 7 }, (_, i) => ({ id: `o${i}`, label: `Option ${i}` })),
        recommendation: "o0",
      },
    });
    expect(warnsOf(textOf(update))).toBe(true);
  });

  test("a Codex client keeps the warning", async () => {
    const { home } = setup();
    const client = await startShim(home, "/", false, { KNOCK_RUNTIME: "codex" }, "codex-mcp-client");
    const ask = await client.callTool({ name: "waggle_ask", arguments: { ...question, need: longNeed } });
    expect(warnsOf(textOf(ask))).toBe(true);
  });
});
