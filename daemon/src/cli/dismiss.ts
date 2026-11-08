import { daemonPaths } from "../config";
import { DaemonClient, DaemonRpcError } from "../mcp/client";
import { connectWithOnDemandStart } from "../on-demand";
import type { Case } from "../protocol";

// `waggle dismiss`: clears an ask out of the queue without touching files
// (docs/protocol-mvp.md "Socket RPC" case.dismiss). Like `waggle test-ask`, it
// starts the daemon on demand when the socket is unreachable.

const USAGE = `Usage: waggle dismiss <case-id>
       waggle dismiss --task "<task name>"
`;

export async function runDismiss(argv: string[]): Promise<number> {
  if (argv.length === 0) {
    process.stderr.write(USAGE);
    return 2;
  }
  if (argv[0] === "--task") {
    const taskName = argv[1];
    if (taskName === undefined || argv.length > 2) {
      process.stderr.write(USAGE);
      return 2;
    }
    return runWithClient((client) => dismissByTaskName(client, taskName));
  }
  if (argv[0].startsWith("-") || argv.length > 1) {
    process.stderr.write(USAGE);
    return 2;
  }
  return runWithClient((client) => dismissOne(client, argv[0]));
}

async function runWithClient(body: (client: DaemonClient) => Promise<number>): Promise<number> {
  const client = new DaemonClient();
  try {
    await connectWithOnDemandStart(client, daemonPaths().socket);
    return await body(client);
  } catch (error) {
    process.stderr.write(`waggle dismiss: ${(error as Error).message}\n`);
    if (error instanceof DaemonRpcError) {
      process.stderr.write("Run `waggle doctor` to check the Waggle install.\n");
    }
    return 1;
  } finally {
    client.close();
  }
}

async function dismissOne(client: DaemonClient, caseId: string): Promise<number> {
  const dismissed = (await client.call("case.dismiss", { case_id: caseId }, 5000)) as Case;
  process.stdout.write(`Dismissed "${dismissed.title}" (case ${dismissed.id}).\n`);
  return 0;
}

// Clears every case of one task by name, e.g. `waggle dismiss --task "Waggle
// test"` for the cases `waggle test-ask` creates. Already-resolved cases in
// the match are dismissed again harmlessly (case.dismiss is idempotent).
async function dismissByTaskName(client: DaemonClient, taskName: string): Promise<number> {
  const all = (await client.call("cases.list", {}, 5000)) as Case[];
  const matching = all.filter((c) => c.task_name === taskName);
  if (matching.length === 0) {
    process.stdout.write(`No cases found for task "${taskName}".\n`);
    return 0;
  }
  for (const item of matching) {
    await client.call("case.dismiss", { case_id: item.id }, 5000);
  }
  process.stdout.write(`Dismissed ${matching.length} case(s) for task "${taskName}".\n`);
  return 0;
}
