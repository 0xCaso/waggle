import { Database } from "bun:sqlite";
import pkg from "../../package.json" with { type: "json" };
import { daemonPaths } from "../config";
import { migrate } from "../schema";
import { UsageLogger } from "../usage";
import { formatReport } from "../usage/report";
import { formatToolReport } from "../usage/tools";
import { exportVersions } from "../usage/versions";

// `waggle report [--days N] [--tools [--cost]] [--export PATH] [--off|--on]` (KNOCK-19, HAIL-195): prints a content-free usage
// summary, or turns the log off (deleting all rows) or back on. The off switch
// is a marker file, so --off works whether or not the daemon is running.

const DEFAULT_DAYS = 7;

interface ReportArgs {
  days: number;
  off: boolean;
  on: boolean;
  tools: boolean;
  cost: boolean;
  export: string | null;
  err: string | null;
}

export async function runReport(args: string[]): Promise<number> {
  const parsed = parseArgs(args);
  if (parsed.err !== null) {
    process.stderr.write(`waggle report: ${parsed.err}\n`);
    return 2;
  }

  const paths = daemonPaths();

  // --on only removes the marker file; it needs no database handle.
  if (parsed.on) {
    const logger = new UsageLogger(new Database(":memory:"), paths.home);
    logger.setEnabled(true);
    process.stdout.write("Usage logging is on.\n");
    return 0;
  }

  const db = new Database(paths.db);
  try {
    migrate(db);
    const logger = new UsageLogger(db, paths.home);

    if (parsed.off) {
      logger.setEnabled(false);
      const deleted = logger.tools.deleteAll();
      process.stdout.write(`Usage logging is off. Deleted ${deleted} usage rows.\n`);
      return 0;
    }

    if (parsed.export !== null) {
      const out = logger.tools.export(parsed.export, exportVersions(pkg.version));
      process.stdout.write(
        `Wrote ${out.tool_calls} tool calls and ${out.usage_events} usage events to ${out.json_path} and ${out.csv_path}.\n` +
          (out.notes > 0
            ? `Nothing has been sent. The file has the text of ${out.notes} replies, because "Include my notes and comments in the export" is on.\n`
            : "Nothing has been sent. The file has no text, titles, paths or names.\n"),
      );
      return 0;
    }

    if (parsed.tools) {
      process.stdout.write(
        formatToolReport(logger.tools.summary(parsed.days), parsed.cost ? logger.tools.costView(parsed.days) : undefined),
      );
      return 0;
    }

    process.stdout.write(formatReport(db, parsed.days));
    return 0;
  } finally {
    db.close();
  }
}

function parseArgs(args: string[]): ReportArgs {
  const out: ReportArgs = { days: DEFAULT_DAYS, off: false, on: false, tools: false, cost: false, export: null, err: null };
  const fail = (err: string): ReportArgs => ({ ...out, err });
  const parseDays = (value: string | undefined): string | null => {
    if (value === undefined) return "--days needs a number";
    const parsed = Number(value);
    if (!Number.isInteger(parsed) || parsed < 1) return `--days needs a positive whole number, got ${value}`;
    out.days = parsed;
    return null;
  };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--off") out.off = true;
    else if (arg === "--on") out.on = true;
    else if (arg === "--tools") out.tools = true;
    else if (arg === "--cost") out.cost = true;
    else if (arg === "--export") {
      const value = args[i + 1];
      if (value === undefined || value.startsWith("--")) return fail("--export needs a file path");
      i += 1;
      out.export = value;
    } else if (arg === "--days") {
      const err = parseDays(args[i + 1]);
      if (err) return fail(err);
      i += 1;
    } else if (arg.startsWith("--days=")) {
      const err = parseDays(arg.slice("--days=".length));
      if (err) return fail(err);
    } else {
      return fail(`unknown argument: ${arg}`);
    }
  }
  if (out.cost && !out.tools) return fail("--cost goes with --tools");
  return out;
}
