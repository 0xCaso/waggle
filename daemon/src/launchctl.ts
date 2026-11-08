import { spawnSync } from "node:child_process";

// The result of running launchctl. `status` is null when the command could not
// be started; `error` carries the spawn failure message (for example ENOENT).
export interface LaunchctlResult {
  status: number | null;
  stdout: string;
  stderr: string;
  error?: string;
}

// A function that runs one launchctl command. The only real caller is the
// legacy-LaunchAgent cleanup in service.ts; tests inject a fake so no real
// launchctl ever runs from a test (KNOCK-18 acceptance).
export type LaunchctlRunner = (args: string[], env?: NodeJS.ProcessEnv) => LaunchctlResult;

// The real launchctl runner. It refuses to run when KNOCK_HOME is set and
// KNOCK_ALLOW_LAUNCHCTL is not exactly "1". KNOCK_HOME is set only in test and
// verification environments (config.ts); production never sets it. This guards
// the 2026-09-26 incident, where a manual verification ran `waggle install
// claude` with a temporary HOME and the real launchctl still loaded the agent
// into the real gui domain.
export function realLaunchctl(
  args: string[],
  env: NodeJS.ProcessEnv = process.env,
): LaunchctlResult {
  if (env.KNOCK_HOME !== undefined && env.KNOCK_HOME !== "" && env.KNOCK_ALLOW_LAUNCHCTL !== "1") {
    throw new Error(
      "refusing to run launchctl in a test environment (KNOCK_HOME is set); " +
        "set KNOCK_ALLOW_LAUNCHCTL=1 to allow it",
    );
  }
  const result = spawnSync("launchctl", args, { encoding: "utf8", env });
  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    error: result.error ? result.error.message : undefined,
  };
}
