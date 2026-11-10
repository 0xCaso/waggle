#!/usr/bin/env bun
// The next release version for a merge to main (.github/workflows/release.yml).
// Every merge bumps the patch. The PR label release:minor or release:major bumps more,
// and skip-release makes no release (prints "skip").
//
//   next-version.mjs <current version> [comma-separated PR labels]
export function nextVersion(current, labels = []) {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(current.trim());
  if (!m) throw new Error(`not a version: ${current}`);
  const names = labels.map((l) => l.trim()).filter(Boolean);
  if (names.includes("skip-release")) return "skip";
  let [major, minor, patch] = m.slice(1).map(Number);
  if (names.includes("release:major")) return `${major + 1}.0.0`;
  if (names.includes("release:minor")) return `${major}.${minor + 1}.0`;
  return `${major}.${minor}.${patch + 1}`;
}

if (import.meta.main) {
  const [current, labels = ""] = process.argv.slice(2);
  if (!current) {
    process.stderr.write("usage: next-version.mjs <current version> [labels]\n");
    process.exit(2);
  }
  process.stdout.write(nextVersion(current, labels.split(",")) + "\n");
}
