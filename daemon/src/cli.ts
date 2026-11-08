import pkg from "../package.json" with { type: "json" };
import { runDaemon } from "./daemon";
import { runMcp } from "./mcp/shim";
import { runDismiss } from "./cli/dismiss";
import { runDesignHelpers } from "./cli/design-helpers";
import { runDoctor } from "./cli/doctor";
import { runInstall } from "./cli/install";
import { runMod } from "./cli/mod";
import { runRule } from "./cli/rule";
import { runTestAsk } from "./cli/test-ask";
import { runUninstall } from "./cli/uninstall";
import { runReport } from "./cli/report";

// The subcommands named in docs/protocol-mvp.md "Components", plus report
// (KNOCK-19) and dismiss (HAIL-32).
const USAGE = `Usage: waggle <subcommand> [args]

Subcommands:
  daemon              Run the Waggle daemon
  mcp                 Run the MCP shim for one agent session
  install [claude|codex]  Install one connector, or every one found on PATH
  doctor              Check the local install
  design-helpers <status|add|remove>  Add or remove the optional Impeccable design plugin for Claude Code
  test-ask            Send a test ask
  dismiss <case-id>   Dismiss an ask, or --task "<task name>" to dismiss every
                      ask of that task (e.g. --task "Waggle test")
  rule <verb>         Add or remove the optional Waggle rule in your agent instructions (status, add, remove)
  mod <verb>          Used by the Waggle Claude Code and Codex plugins (poll, report, usage, open, claude-hook, codex-hook)
  report              Print a private usage summary (--tools: tool calls, add --cost for dollars; --export PATH)
  uninstall           Remove the Waggle install

Options:
  --version, -v  Print the version and exit
  --help, -h     Print this help and exit
`;

export async function main(argv: string[]): Promise<number> {
  const [cmd, ...rest] = argv;

  if (cmd === undefined) {
    process.stderr.write(USAGE);
    return 2;
  }
  if (cmd === "--help" || cmd === "-h") {
    process.stdout.write(USAGE);
    return 0;
  }
  if (cmd === "--version" || cmd === "-v" || cmd === "-V") {
    process.stdout.write(`${pkg.version}\n`);
    return 0;
  }
  if (cmd === "daemon") {
    return runDaemon(rest);
  }
  if (cmd === "mcp") {
    return runMcp();
  }
  if (cmd === "install") {
    return runInstall(rest);
  }
  if (cmd === "doctor") {
    return runDoctor();
  }
  if (cmd === "design-helpers") {
    return runDesignHelpers(rest);
  }
  if (cmd === "test-ask") {
    return runTestAsk();
  }
  if (cmd === "dismiss") {
    return runDismiss(rest);
  }
  if (cmd === "mod") {
    return runMod(rest);
  }
  if (cmd === "rule") {
    return runRule(rest);
  }
  if (cmd === "report") {
    return runReport(rest);
  }
  if (cmd === "uninstall") {
    return runUninstall(rest);
  }
  process.stderr.write(`waggle: unknown command: ${cmd}\n${USAGE}`);
  return 2;
}
