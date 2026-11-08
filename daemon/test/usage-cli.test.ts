import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { migrate } from "../src/schema";
import { USAGE_OFF_FILE } from "../src/usage";
import { truncateToHour } from "../src/usage";
import { rmrf, tmpHome } from "./helpers";

// End-to-end `waggle report` tests: a spawned binary against a temp KNOCK_HOME.
// The report reads knock.db directly and --off/--on persist a marker file, so
// no daemon needs to run.

const ENTRY = join(import.meta.dir, "..", "src", "index.ts");

const homes: string[] = [];

afterEach(() => {
  for (const home of homes.splice(0)) rmrf(home);
});

interface RunResult {
  code: number;
  stdout: string;
  stderr: string;
}

async function runKnock(args: string[], home: string): Promise<RunResult> {
  const proc = Bun.spawn([process.execPath, ENTRY, ...args], {
    env: { ...process.env, KNOCK_HOME: home },
    stdout: "pipe",
    stderr: "pipe",
    stdin: "pipe",
  });
  proc.stdin.end();
  const code = await proc.exited;
  const stdout = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();
  return { code, stdout, stderr };
}

function seedUsage(home: string): void {
  const db = new Database(join(home, "knock.db"));
  migrate(db);
  db.query(
    `INSERT INTO usage (event, hour, project_h) VALUES ('ask_created', ?, 'deadbeef')`,
  ).run(truncateToHour(new Date()));
  db.close();
}

describe("waggle report", () => {
  test("prints the privacy header and an empty summary on a fresh home", async () => {
    const home = tmpHome();
    homes.push(home);

    const result = await runKnock(["report"], home);

    expect(result.code).toBe(0);
    expect(result.stdout).toContain(
      "Nothing here leaves your Mac unless you paste it. Contains no titles, text, paths or project names.",
    );
    expect(result.stdout).toContain("no asks");
    expect(result.stdout).toContain("Distinct projects: 0");
  });

  test("reports counts for a seeded log", async () => {
    const home = tmpHome();
    homes.push(home);
    seedUsage(home);

    const result = await runKnock(["report", "--days", "3"], home);

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Last 3 days");
    expect(result.stdout).toContain("total: 1");
    expect(result.stdout).toContain("Distinct projects: 1");
  });

  test("rejects an unknown argument and a bad --days value", async () => {
    const home = tmpHome();
    homes.push(home);

    const unknown = await runKnock(["report", "--bogus"], home);
    expect(unknown.code).toBe(2);
    expect(unknown.stderr).toContain("unknown argument");

    const badDays = await runKnock(["report", "--days", "zero"], home);
    expect(badDays.code).toBe(2);
    expect(badDays.stderr).toContain("--days needs a positive whole number");
  });
});

describe("waggle report --off and --on", () => {
  test("--off persists the marker and deletes every usage row", async () => {
    const home = tmpHome();
    homes.push(home);
    seedUsage(home);

    const off = await runKnock(["report", "--off"], home);
    expect(off.code).toBe(0);
    expect(off.stdout).toContain("Usage logging is off.");
    expect(off.stdout).toContain("Deleted 1 usage rows");
    expect(existsSync(join(home, USAGE_OFF_FILE))).toBe(true);

    const db = new Database(join(home, "knock.db"));
    const rows = db.query(`SELECT COUNT(*) AS n FROM usage`).get() as { n: number };
    db.close();
    expect(rows.n).toBe(0);
  });

  test("--on removes the marker", async () => {
    const home = tmpHome();
    homes.push(home);

    await runKnock(["report", "--off"], home);
    const on = await runKnock(["report", "--on"], home);
    expect(on.code).toBe(0);
    expect(on.stdout).toContain("Usage logging is on.");
    expect(existsSync(join(home, USAGE_OFF_FILE))).toBe(false);
  });
});
