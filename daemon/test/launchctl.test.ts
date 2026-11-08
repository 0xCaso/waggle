import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { realLaunchctl } from "../src/launchctl";
import { rmrf } from "./helpers";

// The launchctl guard (KNOCK-18): the real runner refuses to run in a test
// environment (KNOCK_HOME set) unless KNOCK_ALLOW_LAUNCHCTL=1 is set explicitly.
// A fake `launchctl` on PATH proves the runner spawns the command only when
// allowed, so no real launchctl is ever touched here.

const LAUNCHCTL_SH = `#!/bin/sh
printf 'launchctl %s\\n' "$*" >> "$LAUNCHCTL_LOG"
exit 0
`;

const dirs: string[] = [];

afterEach(() => {
  for (const dir of dirs.splice(0)) rmrf(dir);
});

function fakeEnv(): { dir: string; env: NodeJS.ProcessEnv; log: string } {
  const dir = mkdtempSync(join(tmpdir(), "knock-launchctl-"));
  dirs.push(dir);
  const log = join(dir, "launchctl.log");
  writeFileSync(join(dir, "launchctl"), LAUNCHCTL_SH);
  chmodSync(join(dir, "launchctl"), 0o755);
  return {
    dir,
    log,
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, LAUNCHCTL_LOG: log },
  };
}

describe("realLaunchctl guard", () => {
  test("refuses to run in a test environment unless KNOCK_ALLOW_LAUNCHCTL=1", () => {
    const { env } = fakeEnv();
    expect(() => realLaunchctl(["bootout", "gui/501/dev.limone.knock.daemon"], { ...env, KNOCK_HOME: "/tmp/knock" })).toThrow(
      /refusing to run launchctl/,
    );
  });

  test("runs when KNOCK_ALLOW_LAUNCHCTL=1 is set explicitly", () => {
    const { env, log } = fakeEnv();
    const result = realLaunchctl(["bootout", "gui/501/dev.limone.knock.daemon"], {
      ...env,
      KNOCK_HOME: "/tmp/knock",
      KNOCK_ALLOW_LAUNCHCTL: "1",
    });
    expect(result.status).toBe(0);
    expect(readFileSync(log, "utf8")).toContain("launchctl bootout gui/501/dev.limone.knock.daemon");
  });

  test("runs in production when KNOCK_HOME is not set", () => {
    const { env, log } = fakeEnv();
    const result = realLaunchctl(["bootout", "gui/501/dev.limone.knock.daemon"], env);
    expect(result.status).toBe(0);
    expect(readFileSync(log, "utf8")).toContain("launchctl bootout gui/501/dev.limone.knock.daemon");
  });
});
