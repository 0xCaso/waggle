// The git footprint of a session folder (HAIL-72, moved by HAIL-222).
//
// Run by the shim only. The shim lives inside the agent's process, which already
// has access to the project folder. The daemon and the app never run git on a
// session cwd: macOS would ask "Waggle would like to access files in your
// Desktop folder". The shim sends the result in session.hello (`changes`).
import { existsSync } from "node:fs";
import type { SessionChanges } from "../protocol";
import { clamp } from "./context";

const GIT_TIMEOUT_MS = 2_000;
const LAST_COMMIT_MAX = 80;

async function git(cwd: string, args: string[]): Promise<string | null> {
  try {
    const proc = Bun.spawn(["git", "-C", cwd, ...args], { stdout: "pipe", stderr: "ignore", stdin: "ignore" });
    const timer = setTimeout(() => proc.kill(), GIT_TIMEOUT_MS);
    const out = await new Response(proc.stdout).text();
    const code = await proc.exited;
    clearTimeout(timer);
    return code === 0 ? out.trim() : null;
  } catch {
    return null;
  }
}

// Null when the folder is not a repository or git failed.
export async function gitFootprint(cwd: string): Promise<SessionChanges | null> {
  if (!cwd || !existsSync(cwd)) return null;
  const [status, numstat, subject] = await Promise.all([
    git(cwd, ["status", "--porcelain"]),
    git(cwd, ["diff", "--numstat", "HEAD"]),
    git(cwd, ["log", "-1", "--format=%s"]),
  ]);
  if (status === null) return null;
  let added = 0;
  let removed = 0;
  let tracked = 0;
  for (const line of (numstat ?? "").split("\n").filter(Boolean)) {
    const [a, d] = line.split("\t");
    added += Number(a) || 0; // "-" for binary files
    removed += Number(d) || 0;
    tracked++;
  }
  const untracked = status.split("\n").filter((l) => l.startsWith("??")).length;
  const files = tracked + untracked;
  return {
    files,
    added,
    removed,
    clean: files === 0,
    last_commit: subject ? clamp(subject, LAST_COMMIT_MAX) : null,
  };
}
