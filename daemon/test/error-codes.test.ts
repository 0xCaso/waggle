import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import pkg from "../package.json" with { type: "json" };
import { ArtifactError, resolveIncoming } from "../src/artifacts/ingest";
import { ingestReplyAttachments } from "../src/artifacts/attachments";
import { stageBundle, stageBundleHtml, stageMarkdown, stageMarkdownContent, stageScreenshots } from "../src/artifacts/stage";
import { EventBus } from "../src/events";
import { translateDaemonError } from "../src/mcp/errors";
import { DaemonConnectionError, DaemonRpcError } from "../src/mcp/client";
import { errorCodeOf, errorKind } from "../src/mcp/shim";
import { ARTIFACT_ERROR_CODES, ToolErrorCode } from "../src/protocol";
import { migrate } from "../src/schema";
import { startRpcServer, type RpcServer } from "../src/server";
import { Store } from "../src/store";
import { UsageLogger } from "../src/usage";
import { ToolCallLog, formatToolReport } from "../src/usage/tools";
import { rmrf, tmpHome } from "./helpers";

// WAG-409: every failed tool call has a true result word and a stable code. The code comes from the
// error class or a code, never from words in the text. The text the agent reads does not change.

const homes: string[] = [];
const servers: RpcServer[] = [];
const transports: StdioClientTransport[] = [];

afterEach(async () => {
  for (const t of transports.splice(0)) await t.close().catch(() => {});
  for (const s of servers.splice(0)) s.stop();
  for (const h of homes.splice(0)) rmrf(h);
});

function codeOf(fn: () => unknown): string {
  try {
    fn();
  } catch (err) {
    expect(err).toBeInstanceOf(ArtifactError);
    return (err as ArtifactError).errorCode;
  }
  throw new Error("did not throw");
}

describe("ArtifactError codes", () => {
  test("stage.ts: bundle, html, size and image families", () => {
    const root = mkdtempSync(join(tmpdir(), "wag409-"));
    homes.push(root);
    const incoming = join(root, "incoming");
    mkdirSync(join(root, "b"), { recursive: true });
    writeFileSync(join(root, "b", "page.html"), "<p>x</p>");
    writeFileSync(join(root, "note.txt"), "x");
    writeFileSync(join(root, "fake.png"), "not an image");

    expect(codeOf(() => stageBundle({ dir: "missing", entry: "index.html", cwd: root, incomingDir: incoming }))).toBe("bundle_dir_not_found");
    expect(codeOf(() => stageBundle({ dir: "b", entry: "index.html", cwd: root, incomingDir: incoming }))).toBe("bundle_entry_missing");
    expect(codeOf(() => stageBundle({ dir: "b", entry: "../x.html", cwd: root, incomingDir: incoming }))).toBe("path_traversal");
    expect(codeOf(() => stageBundleHtml({ html: "  ", incomingDir: incoming }))).toBe("html_empty");
    expect(codeOf(() => stageMarkdownContent({ content: "x".repeat(1024 * 1024 + 1), incomingDir: incoming }))).toBe("too_large");
    expect(codeOf(() => stageMarkdown({ path: "note.txt", cwd: root, incomingDir: incoming }))).toBe("markdown_bad_extension");
    expect(
      codeOf(() => stageScreenshots({ items: [{ data_base64: Buffer.from("hello world").toString("base64") }, { data_base64: "AAAA" }], cwd: root, incomingDir: incoming })),
    ).toBe("not_png_or_jpeg");
    expect(codeOf(() => stageScreenshots({ items: [{ data_base64: "***" }, { data_base64: "AAAA" }], cwd: root, incomingDir: incoming }))).toBe("invalid_base64");
    expect(codeOf(() => stageScreenshots({ items: [{ caption: "a" }, { data_base64: "AAAA" }], cwd: root, incomingDir: incoming }))).toBe("screenshot_source_missing");
  });

  test("ingest.ts: an artifact the shim did not stage", () => {
    const root = mkdtempSync(join(tmpdir(), "wag409-"));
    homes.push(root);
    expect(codeOf(() => resolveIncoming({ type: "html_bundle", dir: "/nope" } as never, root))).toBe("not_staged_by_shim");
  });

  test("attachments.ts: a file outside the incoming folder", () => {
    const root = mkdtempSync(join(tmpdir(), "wag409-"));
    homes.push(root);
    const code = codeOf(() =>
      ingestReplyAttachments({ inputs: [{ incoming_path: "/etc/hosts", name: "hosts" }] as never, existing: [], dataRoot: root, replyId: "r_1" }),
    );
    expect(code).toBe("attachment_not_staged");
  });

  test("every code is a valid code and in the artifact family", () => {
    for (const code of ARTIFACT_ERROR_CODES) {
      expect(ToolErrorCode.safeParse(code).success).toBe(true);
      expect(errorKind(code)).toBe("error_artifact");
    }
  });
});

describe("errorKind and errorCodeOf", () => {
  test("the kind comes from the code, not from words in the text", () => {
    expect(errorKind("daemon_unreachable")).toBe("error_connection");
    expect(errorKind("shim_outdated")).toBe("error_connection");
    expect(errorKind("invalid_params")).toBe("error_invalid");
    expect(errorKind("unknown_guide_topic")).toBe("error_invalid");
    expect(errorKind("bundle_dir_not_found")).toBe("error_artifact");
    expect(errorKind("unclassified")).toBe("error_other");
    expect(errorKind(undefined)).toBe("error_other");
  });

  test("error_connection still covers the two user-actionable errors", () => {
    expect(errorCodeOf(translateDaemonError(new DaemonConnectionError("socket closed")))).toBe("daemon_unreachable");
    expect(errorCodeOf(translateDaemonError(new DaemonRpcError(-32004, "x", { error_code: "not_staged_by_shim" })))).toBe("not_staged_by_shim");
    expect(errorKind(errorCodeOf(translateDaemonError(new DaemonConnectionError("x"))))).toBe("error_connection");
  });

  test("a daemon error takes its code from error.data, then from the RPC code, then unclassified", () => {
    expect(errorCodeOf(new DaemonRpcError(-32603, "Internal error", { message: "m", error_code: "unknown_guide_topic" }))).toBe("unknown_guide_topic");
    expect(errorCodeOf(new DaemonRpcError(-32602, "Invalid params", { issues: [] }))).toBe("invalid_params");
    expect(errorCodeOf(new DaemonRpcError(-32603, "Internal error", { message: "boom" }))).toBe("unclassified");
    expect(errorCodeOf(new Error("who knows"))).toBe("unclassified");
  });
});

describe("the tool-call log", () => {
  test("a migrated database without error_code gets the column, and old rows read null", () => {
    const home = tmpHome();
    homes.push(home);
    const db = new Database(join(home, "knock.db"));
    migrate(db);
    db.exec("ALTER TABLE tool_calls DROP COLUMN error_code");
    db.exec(
      `INSERT INTO tool_calls (at, tool, duration_ms, wait_ms, result, request_bytes, response_bytes, images, tokens_written, tokens_received)
       VALUES ('2026-10-01T00:00:00.000Z', 'waggle_ask', 1, 0, 'error_other', 1, 1, 0, 1, 1)`,
    );
    db.exec("PRAGMA user_version = 52");
    migrate(db);
    const log = new ToolCallLog(db, home);
    expect(log.rows()[0].error_code).toBeNull();
    expect(log.summary(3650).errors).toEqual([]);
  });

  test("the export and the report carry the code and no text", () => {
    const home = tmpHome();
    homes.push(home);
    const db = new Database(join(home, "knock.db"));
    migrate(db);
    const log = new ToolCallLog(db, home);
    const base = { tool: "waggle_guide", duration_ms: 1, wait_ms: 0, request_bytes: 10, response_bytes: 10, images: 0 };
    log.record({ ...base, result: "error_invalid", error_code: "unknown_guide_topic" });
    log.record({ ...base, result: "error_invalid", error_code: "unknown_guide_topic" });
    log.record({ ...base, result: "ok" });
    expect(() => log.record({ ...base, result: "error_other", error_code: "Has spaces and /paths" })).toThrow();

    const out = log.export(join(home, "e.json"), { app: "1", plugin: null, macos: "26" });
    const json = JSON.parse(readFileSync(out.json_path, "utf8")) as { format: string; tool_calls: { error_code: string | null }[] };
    expect(json.format).toBe("waggle-usage-export-1");
    expect(json.tool_calls.map((r) => r.error_code)).toEqual(["unknown_guide_topic", "unknown_guide_topic", null]);
    const csv = readFileSync(out.csv_path, "utf8").split("\n");
    expect(csv[0].split(",").at(-1)).toBe("error_code");
    expect(csv[1].split(",").at(-1)).toBe("unknown_guide_topic");

    const summary = log.summary(30);
    expect(summary.errors).toEqual([{ result: "error_invalid", error_code: "unknown_guide_topic", calls: 2 }]);
    expect(formatToolReport(summary)).toContain("unknown_guide_topic (error_invalid): 2 calls");
  });
});

describe("a real shim", () => {
  async function start() {
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
      env: { KNOCK_HOME: home, CLAUDE_CODE_SESSION_ID: "sess-err", KNOCK_ASK_WAIT_MS: "200" },
      cwd,
      stderr: "pipe",
    });
    transports.push(transport);
    const client = new Client({ name: "claude-code", version: "0.0.0" }, { capabilities: {} });
    await client.connect(transport);
    const lastRow = async (count: number) => {
      const deadline = Date.now() + 5000;
      while (store.toolLog!.rows().length < count && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
      return store.toolLog!.rows()[count - 1];
    };
    return { client, lastRow, db };
  }

  const text = (res: unknown): string => (res as { content: { text: string }[] }).content[0].text;

  test("an unknown guide topic is error_invalid with its own code, and the text is unchanged", async () => {
    const { client, lastRow, db } = await start();
    const res = await client.callTool({ name: "waggle_guide", arguments: { topic: "nonsense" } });
    expect((res as { isError?: boolean }).isError).toBe(true);
    expect(text(res)).toMatch(/^Unknown guide topic "nonsense"\. Valid topics: .*artifacts/);
    const row = await lastRow(1);
    expect(row).toMatchObject({ tool: "waggle_guide", result: "error_invalid", error_code: "unknown_guide_topic" });
    expect(JSON.stringify(db.query("SELECT * FROM tool_calls").all())).not.toContain("nonsense");
  });

  test("a bad field is error_invalid / invalid_params", async () => {
    const { client, lastRow } = await start();
    const res = await client.callTool({ name: "waggle_ask", arguments: { kind: "question" } });
    expect((res as { isError?: boolean }).isError).toBe(true);
    const row = await lastRow(1);
    expect(row).toMatchObject({ result: "error_invalid", error_code: "invalid_params" });
  });

  test("a missing bundle dir is error_artifact / bundle_dir_not_found, text unchanged", async () => {
    const { client, lastRow } = await start();
    const res = await client.callTool({
      name: "waggle_ask",
      arguments: {
        kind: "review",
        title: "t",
        need: "n",
        why: "w",
        recommendation: "a",
        recommendation_why: "b",
        options: [{ id: "a", label: "A" }, { id: "b", label: "B" }],
        artifact: { type: "html_bundle", dir: "nowhere", entry: "index.html" },
      },
    });
    expect(text(res)).toBe("bundle dir not found: nowhere");
    expect(await lastRow(1)).toMatchObject({ result: "error_artifact", error_code: "bundle_dir_not_found" });
  });
});
