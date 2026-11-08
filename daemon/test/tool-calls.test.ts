import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import pkg from "../package.json" with { type: "json" };
import { runMod } from "../src/cli/mod";
import { runReport } from "../src/cli/report";
import { EventBus } from "../src/events";
import { toolCallParams, errorKind } from "../src/mcp/shim";
import { migrate } from "../src/schema";
import { startRpcServer, type RpcServer } from "../src/server";
import { Store } from "../src/store";
import { UsageLogger } from "../src/usage";
import {
  BYTES_PER_TOKEN,
  PRICES,
  TOKENS_PER_IMAGE,
  ToolCallLog,
  callCostUsd,
  estimateTokens,
  formatToolReport,
} from "../src/usage/tools";
import { latestUsage } from "../src/usage/transcript";
import { rmrf, rpcConnect, tmpHome } from "./helpers";

// HAIL-195: the tool-call log, the token estimate, the transcript numbers, the cost view, the
// export, delete, retention and the off switches. No test touches the real KNOCK_HOME or ~/.claude.

const SECRET = "SECRET-ASK-TEXT-do-not-store";

const homes: string[] = [];
const servers: RpcServer[] = [];
const transports: StdioClientTransport[] = [];

afterEach(async () => {
  for (const t of transports.splice(0)) await t.close().catch(() => {});
  for (const s of servers.splice(0)) s.stop();
  for (const h of homes.splice(0)) rmrf(h);
});

function logSetup() {
  const home = tmpHome();
  homes.push(home);
  const db = new Database(join(home, "knock.db"));
  migrate(db);
  return { home, db, log: new ToolCallLog(db, home) };
}

const call = (extra: Record<string, unknown> = {}) => ({
  tool: "waggle_check",
  duration_ms: 1200,
  wait_ms: 1000,
  result: "pending",
  session_id: "sess-1",
  client_name: "claude-code",
  case_id: "c_1",
  request_bytes: 40,
  response_bytes: 400,
  images: 0,
  ...extra,
});

describe("token estimate", () => {
  test("bytes / 4 rounded up, plus 1600 tokens per image", () => {
    expect(BYTES_PER_TOKEN).toBe(4);
    expect(TOKENS_PER_IMAGE).toBe(1600);
    expect(estimateTokens(0)).toBe(0);
    expect(estimateTokens(41)).toBe(11);
    const { db, log } = logSetup();
    log.record(call({ request_bytes: 41, response_bytes: 400, images: 2 }));
    const row = log.rows()[0];
    expect(row.tokens_written).toBe(11);
    expect(row.tokens_received).toBe(100 + 2 * 1600);
    db.close();
  });

  test("cost uses the listed prices, and prices the measured context", () => {
    const base = { tokens_written: 1_000_000, tokens_received: 1_000_000, ctx_input: null, ctx_cache_read: null, ctx_cache_creation: null };
    expect(callCostUsd(base)).toBeCloseTo(PRICES.output_per_mtok + PRICES.input_per_mtok);
    const withCtx = { ...base, tokens_written: 0, tokens_received: 0, ctx_input: 0, ctx_cache_read: 1_000_000, ctx_cache_creation: 1_000_000 };
    expect(callCostUsd(withCtx)).toBeCloseTo(PRICES.cache_read_per_mtok + PRICES.cache_write_per_mtok);
  });
});

describe("tool_calls rows", () => {
  test("a row holds sizes and ids, and rejects any extra key (no content fits)", () => {
    const { db, log } = logSetup();
    expect(() => log.record(call({ text: SECRET }))).toThrow();
    expect(() => log.record(call({ client_name: SECRET + "/Users/me/x" }))).toThrow();
    log.record(call());
    const raw = JSON.stringify(db.query(`SELECT * FROM tool_calls`).all());
    expect(raw).not.toContain(SECRET);
    expect(log.rows()).toHaveLength(1);
    db.close();
  });

  test("off switch stops new rows; on starts them again; delete clears rows and hourly events", () => {
    const { db, home, log } = logSetup();
    const usage = new UsageLogger(db, home);
    usage.record({ event: "ask_created", kind: "question" });
    log.record(call());
    expect(log.control({ record: false })).toMatchObject({ record: false });
    log.record(call());
    usage.record({ event: "ask_created", kind: "question" });
    expect(log.count()).toEqual({ tool_calls: 1, usage_events: 1 });
    log.control({ record: true });
    log.record(call());
    expect(log.count().tool_calls).toBe(2);
    const result = log.control({ delete: true });
    expect(result.deleted).toBe(3);
    expect(log.count()).toEqual({ tool_calls: 0, usage_events: 0 });
    db.close();
  });

  test("retention deletes rows older than the limit", () => {
    const { db, log } = logSetup();
    log.record(call());
    db.query(`UPDATE tool_calls SET at = ?`).run(new Date(Date.now() - 91 * 86_400_000).toISOString());
    log.record(call());
    expect(log.deleteOlderThan(90)).toBe(1);
    expect(log.rows()).toHaveLength(1);
    db.close();
  });
});

describe("transcript usage", () => {
  const fixture = (lines: unknown[]) => {
    const home = tmpHome();
    homes.push(home);
    const path = join(home, "session.jsonl");
    writeFileSync(path, lines.map((l) => (typeof l === "string" ? l : JSON.stringify(l))).join("\n") + "\n");
    return path;
  };
  const assistant = (usage: object, text = SECRET) => ({
    type: "assistant",
    message: { role: "assistant", content: [{ type: "text", text }], usage },
  });

  test("reads only the numbers of the latest assistant message", () => {
    const path = fixture([
      assistant({ input_tokens: 1, cache_read_input_tokens: 2, cache_creation_input_tokens: 3, output_tokens: 4 }),
      { type: "user", message: { content: SECRET } },
      assistant({ input_tokens: 5, cache_read_input_tokens: 419_000, cache_creation_input_tokens: 700, output_tokens: 80 }),
      { type: "user", message: { content: "tool result" } },
    ]);
    const usage = latestUsage(path);
    expect(usage).toEqual({ input: 5, cache_read: 419_000, cache_creation: 700, output: 80 });
    expect(JSON.stringify(usage)).not.toContain(SECRET);
  });

  test("skips a cut or broken line, and gives null when nothing can be read", () => {
    expect(latestUsage(fixture(['{"type":"assistant","message":{"usage":{"input_tok', "not json"]))).toBeNull();
    expect(latestUsage(join(tmpHome(), "missing.jsonl"))).toBeNull();
  });

  test("a hook reading joins the next row of the same session and tool; the transcript switch blocks it", () => {
    const { db, log } = logSetup();
    const ctx = { session_id: "sess-1", tool: "waggle_check", input: 5, cache_read: 1000, cache_creation: 10, output: 7 };
    log.noteContext(ctx);
    log.record(call());
    expect(log.rows()[0]).toMatchObject({ ctx_input: 5, ctx_cache_read: 1000, ctx_cache_creation: 10, ctx_output: 7 });
    log.noteContext({ ...ctx, tool: "waggle_ask" });
    log.record(call());
    expect(log.rows()[1].ctx_cache_read).toBeNull();

    log.control({ transcript: false });
    log.noteContext(ctx);
    log.control({ transcript: true });
    log.record(call());
    expect(log.rows()[2].ctx_cache_read).toBeNull();
    db.close();
  });
});

describe("waggle mod usage", () => {
  test("sends only the numbers to the daemon, and sends nothing while a switch is off", async () => {
    const home = tmpHome();
    homes.push(home);
    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    const store = new Store(db, home, bus, new UsageLogger(db, home));
    servers.push(startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: pkg.version }));
    const transcript = join(home, "t.jsonl");
    writeFileSync(
      transcript,
      JSON.stringify({
        type: "assistant",
        message: { content: [{ type: "text", text: SECRET }], usage: { input_tokens: 3, cache_read_input_tokens: 900, cache_creation_input_tokens: 4, output_tokens: 6 } },
      }) + "\n",
    );
    const saved = process.env.KNOCK_HOME;
    process.env.KNOCK_HOME = home;
    const orig = process.stdout.write.bind(process.stdout);
    const out: string[] = [];
    process.stdout.write = ((c: string) => (out.push(String(c)), true)) as typeof process.stdout.write;
    const args = ["usage", "--session", "sess-m", "--tool", "waggle_check", "--transcript", transcript];
    try {
      expect(await runMod(args)).toBe(0);
      store.toolLog!.record(call({ session_id: "sess-m" }));
      store.toolLog!.control({ transcript: false });
      expect(await runMod(args)).toBe(0);
    } finally {
      process.stdout.write = orig;
      if (saved === undefined) delete process.env.KNOCK_HOME;
      else process.env.KNOCK_HOME = saved;
    }
    expect(out.join("")).toBe('{"ok":true}\n{"ok":false}\n');
    expect(store.toolLog!.rows()[0]).toMatchObject({ ctx_input: 3, ctx_cache_read: 900, ctx_cache_creation: 4, ctx_output: 6 });
  });
});

describe("summary, report and export", () => {
  test("calls per tool, cost, wait share and top sessions", () => {
    const { db, log } = logSetup();
    log.noteContext({ session_id: "sess-1", tool: "waggle_check", input: 0, cache_read: 1_000_000, cache_creation: 0, output: 0 });
    log.record(call());
    log.record(call({ tool: "waggle_ask", result: "answered", session_id: "sess-2", wait_ms: 0, artifact_kind: "markdown" }));
    const s = log.summary(7);
    expect(s.calls).toBe(2);
    expect(s.tools.map((t) => t.tool)).toEqual(["waggle_check", "waggle_ask"]);
    expect(s.wait_calls).toBe(1);
    expect(s.wait_share).toBeGreaterThan(0.9);
    expect(s.context_measured_calls).toBe(1);
    expect(s.top_sessions[0].session_id).toBe("sess-1");
    expect(JSON.stringify(s)).not.toMatch(/cost|usd|price/i);
    const text = formatToolReport(s);
    expect(text).toContain("waggle_check: 1 calls");
    expect(text).not.toContain("$");
    expect(text).not.toContain("Prices per million tokens");
    const withCost = formatToolReport(s, log.costView(7));
    expect(withCost).toContain("Prices per million tokens");
    expect(withCost).toMatch(/waggle_check: 1 calls.*, \$/);
    db.close();
  });

  test("export has rows, events, versions and a random install id, and no path or text", () => {
    const { db, home, log } = logSetup();
    new UsageLogger(db, home).record({ event: "ask_created", kind: "question" });
    log.record(call());
    const out = log.export(join(home, "out", "usage"), { app: "9.9.9", plugin: "0.2.0", macos: "15.0" });
    expect(out.json_path.endsWith("usage.json")).toBe(true);
    expect(out.csv_path.endsWith("usage.csv")).toBe(true);
    const body = JSON.parse(readFileSync(out.json_path, "utf8"));
    expect(body.tool_calls).toHaveLength(1);
    expect(body.usage_events).toHaveLength(1);
    expect(body).toMatchObject({ app_version: "9.9.9", plugin_version: "0.2.0", macos_version: "15.0" });
    expect(body.install_id).toMatch(/^[0-9a-f]{32}$/);
    expect(log.installId()).toBe(body.install_id);
    const csv = readFileSync(out.csv_path, "utf8");
    expect(csv.split("\n")[0]).toContain("tool,duration_ms");
    expect(csv.split("\n")).toHaveLength(3);
    expect(JSON.stringify(body)).not.toContain(home);
    expect(JSON.stringify(body)).not.toMatch(/cost|usd|price/i);
    expect(body.tool_calls[0].tokens_written).toBeGreaterThan(0);
    db.close();
  });

  test("waggle report --tools and --export run against KNOCK_HOME", async () => {
    const { home, db, log } = logSetup();
    log.record(call());
    db.close();
    const saved = process.env.KNOCK_HOME;
    process.env.KNOCK_HOME = home;
    const written: string[] = [];
    const orig = process.stdout.write.bind(process.stdout);
    process.stdout.write = ((chunk: string) => (written.push(String(chunk)), true)) as typeof process.stdout.write;
    try {
      expect(await runReport(["--tools", "--days", "3"])).toBe(0);
      expect(await runReport(["--tools", "--cost"])).toBe(0);
      expect(await runReport(["--cost"])).toBe(2);
      expect(await runReport(["--export", join(home, "e.json")])).toBe(0);
    } finally {
      process.stdout.write = orig;
      if (saved === undefined) delete process.env.KNOCK_HOME;
      else process.env.KNOCK_HOME = saved;
    }
    expect(written.join("")).toContain("Tool calls, last 3 days");
    expect(written.join("")).toContain("Prices per million tokens");
    expect(written.join("").split("Prices per million tokens")).toHaveLength(2);
    expect(existsSync(join(home, "e.json"))).toBe(true);
    expect(existsSync(join(home, "e.csv"))).toBe(true);
  });
});

describe("shim recording", () => {
  test("errorKind sorts an error code into a closed word", () => {
    expect(errorKind("daemon_unreachable")).toBe("error_connection");
    expect(errorKind("bundle_entry_missing")).toBe("error_artifact");
    expect(errorKind("invalid_params")).toBe("error_invalid");
    expect(errorKind("unclassified")).toBe("error_other");
  });

  test("toolCallParams measures sizes and drops the text", () => {
    const params = toolCallParams(
      { sessionId: "s1", runtime: "claude", clientName: "claude-code" },
      "knock_ask",
      { title: SECRET, artifact: { type: "markdown", path: "/Users/me/secret.md" } },
      { content: [{ type: "text", text: "héllo" }, { type: "image", data: "AAAA", mimeType: "image/png" }] },
      12,
      { waitMs: 5, caseId: "c_9", result: "answered" },
    )!;
    expect(params).toMatchObject({
      tool: "waggle_ask",
      session_id: "s1",
      client_name: "claude-code",
      case_id: "c_9",
      artifact_kind: "markdown",
      response_bytes: 6,
      images: 1,
      result: "answered",
      wait_ms: 5,
    });
    expect(JSON.stringify(params)).not.toContain(SECRET);
    expect(JSON.stringify(params)).not.toContain("/Users");
  });

  test("a real shim reports waggle_ask and the knock_check alias without any ask text", async () => {
    const home = tmpHome();
    homes.push(home);
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });
    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    const store = new Store(db, home, bus, new UsageLogger(db, home));
    servers.push(startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: pkg.version }));
    const transport = new StdioClientTransport({
      command: process.execPath,
      args: [join(import.meta.dir, "..", "src", "index.ts"), "mcp"],
      env: { KNOCK_HOME: home, CLAUDE_CODE_SESSION_ID: "sess-rec", KNOCK_ASK_WAIT_MS: "200" },
      cwd,
      stderr: "pipe",
    });
    transports.push(transport);
    const client = new Client({ name: "claude-code", version: "0.0.0" }, { capabilities: {} });
    await client.connect(transport);

    const asked = await client.callTool({
      name: "waggle_ask",
      arguments: {
        kind: "question",
        title: SECRET,
        need: SECRET,
        why: "why",
        recommendation: "a",
        recommendation_why: "because",
        options: [
          { id: "a", label: "Compact" },
          { id: "b", label: "Detailed" },
        ],
      },
    });
    const caseId = JSON.stringify(asked).match(/case_id\\?":\\?"(c_[^"\\]+)/)![1];
    await client.callTool({ name: "knock_check", arguments: { case_id: caseId } });

    const deadline = Date.now() + 5000;
    while (store.toolLog!.rows().length < 2 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
    const rows = store.toolLog!.rows();
    expect(rows.map((r) => r.tool)).toEqual(["waggle_ask", "waggle_check"]);
    expect(rows[0]).toMatchObject({ result: "pending", session_id: "sess-rec", client_name: "claude-code", case_id: caseId });
    expect(rows[0].wait_ms).toBeGreaterThanOrEqual(150);
    expect(rows[0].request_bytes).toBeGreaterThan(SECRET.length);
    expect(rows[1].case_id).toBe(caseId);
    expect(JSON.stringify(db.query(`SELECT * FROM tool_calls`).all())).not.toContain(SECRET);

    // The control RPC reaches the same log.
    const rpc = await rpcConnect(join(home, "knock.sock"));
    const summary = await rpc.request("usage.summary", { days: 1 });
    expect((summary.result as { calls: number }).calls).toBe(2);
    const off = await rpc.request("usage.control", { record: false });
    expect(off.result).toMatchObject({ record: false });
    rpc.close();
  });
});
