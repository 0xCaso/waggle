#!/usr/bin/env bun
// Rewrites the "version" field of daemon/package.json (KNOCK-21 release). The
// version is the single source: `waggle --version`, service.status.version and
// the app's CFBundleShortVersionString all read it (via bundle-app.sh).
import { readFileSync, writeFileSync } from "node:fs";

const [file, version] = process.argv.slice(2);
if (!file || !version) {
  process.stderr.write("usage: bump-version.mjs <package.json> <version>\n");
  process.exit(2);
}
const pkg = JSON.parse(readFileSync(file, "utf8"));
pkg.version = version;
writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n");
