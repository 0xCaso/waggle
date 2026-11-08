import { randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stageBundle } from "../artifacts";
import { daemonPaths } from "../config";
import { DaemonClient, DaemonRpcError } from "../mcp/client";
import { connectWithOnDemandStart } from "../on-demand";
import type { Case, McpContent } from "../protocol";
import { gitRoot } from "../sessions";
import { TEST_FIXTURE } from "./test-ask-fixture";

// `waggle test-ask`: creates the KNOCK-03 sample review case as a built-in test
// session, waits for the human's reply, and acks it so the reply shows
// delivered. It exercises the same session path a real shim uses, without an
// agent (docs/protocol-mvp.md "MCP tools" and KNOCK-06 acceptance). Like the
// shim, it starts the daemon on demand when the socket is unreachable and
// retries for up to 3 s (docs/SERVICE.md, KNOCK-17).

const DEFAULT_WAIT_MS = 15 * 60 * 1000;
const POLL_MS = 1000;

// The built-in sample (WAG-338, "Try a sample instead"): one ask in the three blocks shape. It has a need,
// a why, one item with its options and a recommendation, and an artifact (added in runTestAsk). It is the
// pricing-card fixture, so the tour has an artifact box, options and a pick to point at.
export const TEST_CASE = {
  title: "Pricing card: compact or detailed?",
  need: "Pick the pricing card layout to ship: Compact or Detailed.",
  why: "Both layouts meet the spec. Compact is faster on repeat purchases. Detailed explains the membership tiers.",
  items: [
    {
      id: "layout",
      select: "one" as const,
      options: [
        { id: "a", title: "Compact", label: "Compact: one tight card, built for repeat buyers" },
        { id: "b", title: "Detailed", label: "Detailed: the card also explains each membership tier" },
      ],
      recommendation: "a",
      recommendation_why:
        "Compact ships faster and reads cleaner on repeat visits. Detailed gives new visitors room to compare.",
    },
  ],
};

export async function runTestAsk(): Promise<number> {
  const client = new DaemonClient();
  let temp: { root: string; cwd: string } | null = null;
  try {
    await connectWithOnDemandStart(client, daemonPaths().socket);

    temp = writeFixture();
    const incoming = join(daemonPaths().home, "incoming");
    const staged = stageBundle({
      dir: "proto",
      entry: "index.html",
      cwd: temp.cwd,
      incomingDir: incoming,
    });
    await client.call(
      "session.hello",
      {
        session_id: randomUUID(),
        cwd: temp.cwd,
        branch: "Waggle test",
        git_root: gitRoot(temp.cwd),
        parent_pid: process.pid,
      },
      5000,
    );
    const created = (await client.call(
      "case.create",
      { ...TEST_CASE, artifact: { type: "html_bundle", dir: staged.path, entry: staged.entry } },
      15000,
    )) as Case;

    process.stdout.write(`Created test review "${created.title}" (case ${created.id}).\n`);
    process.stdout.write("Reply in Waggle to finish the loop.\n");

    const reply = await waitForReply(client, created.id);
    if (reply === null) {
      process.stdout.write("No reply yet. The case stays in Waggle. Reply in the app when ready.\n");
      return 0;
    }
    await client.call("reply.ack", { reply_id: reply.reply_id }, 5000);
    process.stdout.write("Delivered to the test session.\n");
    for (const block of reply.content) {
      if (block.type === "text") {
        process.stdout.write(`${block.text}\n`);
      }
    }
    return 0;
  } catch (error) {
    process.stderr.write(`waggle test-ask: ${(error as Error).message}\n`);
    if (error instanceof DaemonRpcError) {
      process.stderr.write("Run `waggle doctor` to check the Waggle install.\n");
    }
    return 1;
  } finally {
    client.close();
    if (temp !== null) {
      rmSync(temp.root, { recursive: true, force: true });
    }
  }
}

// Writes the checkout-proto fixture into <tmp>/Waggle/proto so the artifact dir
// "proto" resolves against the session cwd and the project shows as "Waggle".
function writeFixture(): { root: string; cwd: string } {
  const root = mkdtempSync(join(tmpdir(), "knock-test-ask-"));
  const cwd = join(root, "Waggle");
  const proto = join(cwd, "proto");
  mkdirSync(proto, { recursive: true });
  writeFileSync(join(proto, "index.html"), TEST_FIXTURE["index.html"]);
  writeFileSync(join(proto, "style.css"), TEST_FIXTURE["style.css"]);
  writeFileSync(join(proto, "app.js"), TEST_FIXTURE["app.js"]);
  return { root, cwd };
}

// Polls case.wait so a reply that lands between waits is still picked up
// (case.wait returns any already-queued reply first). Returns null on timeout.
async function waitForReply(
  client: DaemonClient,
  caseId: string,
): Promise<{ reply_id: string; content: McpContent[] } | null> {
  const deadline = Date.now() + readWaitMs();
  for (;;) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) return null;
    const waitMs = Math.max(1, Math.floor(Math.min(remaining, POLL_MS)));
    const result = await client.call(
      "case.wait",
      { case_id: caseId, wait_ms: waitMs },
      waitMs + 15000,
    );
    if (isPending(result)) continue;
    return result as { reply_id: string; content: McpContent[] };
  }
}

function isPending(result: unknown): result is { status: "pending"; case_id: string } {
  return (
    typeof result === "object" &&
    result !== null &&
    (result as { status?: unknown }).status === "pending"
  );
}

function readWaitMs(): number {
  const raw = process.env.KNOCK_ASK_WAIT_MS;
  if (!raw) return DEFAULT_WAIT_MS;
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : DEFAULT_WAIT_MS;
}
