import { existsSync, rmSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { join } from "node:path";
import { realLaunchctl, type LaunchctlRunner } from "./launchctl";

export const SERVICE_LABEL = "dev.limone.knock.daemon";

// The LaunchAgent label the pre-rename build wrote. The pilot no longer
// installs a LaunchAgent (docs/SERVICE.md); this label only matters for
// removing a plist left behind by an older build.
export const PRE_RENAME_LABEL = "dev.hail.daemon";

// Every label whose plist the pilot removes: the current label, then the
// pre-rename label.
const LEGACY_LABELS = [SERVICE_LABEL, PRE_RENAME_LABEL];

export function launchAgentPath(
  home: string = homedir(),
  label: string = SERVICE_LABEL,
): string {
  return join(home, "Library", "LaunchAgents", `${label}.plist`);
}

// Removes a legacy LaunchAgent for each label in LEGACY_LABELS: boots it out of
// launchd and deletes its plist. Bootout is best effort (an agent that is not
// loaded fails bootout); the plist is always deleted. Returns the labels whose
// plist was present.
//
// The runner is injected so tests never call the real launchctl (KNOCK-18
// acceptance). The real runner refuses to run in a test environment unless
// KNOCK_ALLOW_LAUNCHCTL=1 is set explicitly, which is what prevents the
// 2026-09-26 incident from repeating.
export function removeLegacyLaunchAgent(
  runner: LaunchctlRunner = realLaunchctl,
  home: string = homedir(),
): string[] {
  const removed: string[] = [];
  for (const label of LEGACY_LABELS) {
    const path = launchAgentPath(home, label);
    if (!existsSync(path)) continue;
    try {
      runner(["bootout", `gui/${uid()}/${label}`]);
    } catch {
      // The runner may refuse (test environment) or bootout may fail because the
      // agent is not loaded. Either way, deleting the plist is the safe half: it
      // stops the item reloading on the next login.
    }
    rmSync(path, { force: true });
    removed.push(label);
  }
  return removed;
}

function uid(): number {
  try {
    return userInfo().uid;
  } catch {
    return 0;
  }
}
