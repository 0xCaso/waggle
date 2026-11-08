// End-to-end smoke test of the compiled binaries: `./dist/waggle daemon` plus
// `./dist/waggle mcp` over stdio, driven by the MCP SDK client. It calls
// waggle_ask, submits the human reply through reply.submit, then calls
// waggle_check and asserts the reply arrives and the shim's ack marks it
// delivered.
//
// Run it after `bun run build`:
//   bun test/smoke.ts

import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { rpcConnect, rmrf, tmpHome } from "./helpers";

const BIN = join(import.meta.dir, "..", "dist", "knock");

const question = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact" },
    { id: "b", label: "Detailed" },
  ],
};

function textOf(result: unknown): string {
  if (typeof result !== "object" || result === null || !("content" in result)) return "";
  const content = (result as { content: unknown }).content;
  if (!Array.isArray(content)) return "";
  return (content as { type: string; text?: string }[])
    .filter((c) => c.type === "text")
    .map((c) => c.text ?? "")
    .join("\n");
}

async function waitForSocket(socketPath: string, timeoutMs = 10000): Promise<void> {
  const start = Date.now();
  for (;;) {
    try {
      const probe = await rpcConnect(socketPath);
      probe.close();
      return;
    } catch {
      if (Date.now() - start > timeoutMs) {
        throw new Error("daemon socket never became connectable");
      }
      await new Promise((r) => setTimeout(r, 25));
    }
  }
}

async function main(): Promise<void> {
  const home = tmpHome();
  const cwd = join(home, "work");
  mkdirSync(cwd, { recursive: true });

  const daemon = Bun.spawn([BIN, "daemon"], {
    env: { ...process.env, KNOCK_HOME: home },
    stdout: "pipe",
    stderr: "pipe",
  });
  const socketPath = join(home, "knock.sock");
  await waitForSocket(socketPath);

  const transport = new StdioClientTransport({
    command: BIN,
    args: ["mcp"],
    env: {
      ...process.env,
      KNOCK_HOME: home,
      CLAUDE_CODE_SESSION_ID: "smoke-session",
      KNOCK_ASK_WAIT_MS: "400",
    },
    cwd,
    stderr: "pipe",
  });
  const client = new Client({ name: "knock-smoke", version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);

  try {
    // waggle_ask times out quickly and returns the pending text with the case id.
    const pending = await client.callTool({ name: "waggle_ask", arguments: question });
    if (pending.isError) {
      throw new Error(`waggle_ask errored: ${JSON.stringify(pending)}`);
    }
    const pendingText = textOf(pending);
    const caseId = pendingText.match(/case_id":"(c_[^"]+)"/)?.[1];
    if (!caseId) throw new Error(`no case id in pending text: ${pendingText}`);

    // Submit the human reply through the RPC (KNOCK-05 reply.submit).
    const app = await rpcConnect(socketPath);
    const submitted = await app.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "smoke-key",
      choice: "a",
      message: "Go with A.",
      comments: [],
      captures: [],
    });
    app.close();
    if ((submitted.result as { state?: string }).state !== "queued") {
      throw new Error(`reply.submit did not queue: ${JSON.stringify(submitted)}`);
    }

    // waggle_check resumes the wait and gets the reply payload.
    const result = await client.callTool({ name: "waggle_check", arguments: { case_id: caseId } });
    if (result.isError) {
      throw new Error(`waggle_check errored: ${JSON.stringify(result)}`);
    }
    const replyText = textOf(result);

    console.log("--- pending from waggle_ask ---");
    console.log(pendingText);
    console.log("--- reply from waggle_check ---");
    console.log(replyText);

    if (!replyText.includes('Reply to "Pick a layout"')) throw new Error("reply title missing");
    if (!replyText.includes("Choice: a (Compact)")) throw new Error("reply choice missing");
    if (!replyText.includes("Message: Go with A.")) throw new Error("reply message missing");

    // The shim acked the reply, so the daemon must have marked it delivered.
    const checkDb = new Database(join(home, "knock.db"));
    const row = checkDb
      .query(`SELECT state FROM replies WHERE case_id = ?`)
      .get(caseId) as { state: string } | undefined;
    checkDb.close();
    if (!row || row.state !== "delivered") {
      throw new Error(`reply not delivered, state = ${row?.state ?? "missing"}`);
    }
    console.log("--- reply state ---");
    console.log(`state=${row.state} (shim acked, daemon delivered)`);
    console.log("smoke: OK");
  } finally {
    try {
      await client.close();
    } catch {
      // Already closed.
    }
    try {
      await transport.close();
    } catch {
      // Already closed.
    }
    daemon.kill();
    await daemon.exited;
    rmrf(home);
  }
}

main().catch((err) => {
  console.error(`smoke: FAILED: ${(err as Error).message}`);
  process.exit(1);
});
