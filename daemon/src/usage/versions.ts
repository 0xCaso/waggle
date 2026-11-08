import { execFileSync } from "node:child_process";
import { release as osRelease } from "node:os";
import { bundledPluginDir, bundledPluginVersion } from "../cli/claude-plugin";

// The versions the usage export names: the app (the daemon ships inside it), the bundled Claude
// Code plugin when it can be found, and macOS. Nothing here names the user or a path.
export function exportVersions(app: string): { app: string; plugin: string | null; macos: string } {
  const dir = bundledPluginDir();
  let macos = `darwin ${osRelease()}`;
  try {
    const out = execFileSync("sw_vers", ["-productVersion"], { encoding: "utf8", timeout: 2000 }).trim();
    if (/^[0-9][0-9.]*$/.test(out)) macos = out;
  } catch {
    // Not macOS, or no sw_vers: keep the Darwin release.
  }
  return { app, plugin: dir ? bundledPluginVersion(dir) : null, macos };
}
