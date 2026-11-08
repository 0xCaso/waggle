import { spawnSync } from "node:child_process";
import { basename } from "node:path";

// Task and project naming (docs/protocol-mvp.md "Nouns"):
//   task name  = Linear key in the branch (`ome-412-x` -> `OME-412`), else the
//                branch, else the cwd folder name.
//   project    = git root folder name of the task's cwd (a tag only).

// A Linear key starts a branch: a team key followed by an issue number, e.g.
// `ome-412-...` or `ENG-412-...`. The whole key is uppercased.
const LINEAR_KEY = /^([a-z][a-z0-9]*-\d+)/i;

export function linearKey(branch: string | null | undefined): string | null {
  if (!branch) return null;
  const match = branch.match(LINEAR_KEY);
  return match ? match[1].toUpperCase() : null;
}

export function taskName(branch: string | null | undefined, cwd: string): string {
  const key = linearKey(branch);
  if (key) return key;
  if (branch) return branch;
  return basename(cwd);
}

// The project is a tag: the git root folder name when the shim reported one,
// else the basename of the cwd as a string (no filesystem access). The shim
// runs `git -C <cwd> rev-parse --show-toplevel` and sends the result in
// session.hello as git_root (HAIL-26); the daemon never runs git itself.
export function projectName(gitRoot: string | null | undefined, cwd: string): string {
  return basename(gitRoot ?? cwd);
}

// Runs `git -C <cwd> rev-parse --show-toplevel`. Returns the absolute root, or
// null when the cwd is not inside a git repository. Called by the shim only.
export function gitRoot(cwd: string): string | null {
  try {
    const result = spawnSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], {
      encoding: "utf8",
    });
    if (result.status !== 0) return null;
    const out = result.stdout.trim();
    return out === "" ? null : out;
  } catch {
    return null;
  }
}

// The current branch of a working tree, or null when git cannot report one
// (detached HEAD or not a repository).
export function gitBranch(cwd: string): string | null {
  try {
    const result = spawnSync("git", ["-C", cwd, "branch", "--show-current"], {
      encoding: "utf8",
    });
    if (result.status !== 0) return null;
    const out = result.stdout.trim();
    return out === "" ? null : out;
  } catch {
    return null;
  }
}
