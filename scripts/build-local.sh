#!/usr/bin/env bash
# Local build (KNOCK-17): builds the daemon and dist/Waggle.app for a source
# install, without signing an update or uploading. `release.sh` is the one
# release path; this is the source-build command INSTALL.md names.
#
# The zip it writes is named Waggle-<version>.zip to match the appcast enclosure,
# but it is NOT Sparkle-signed: no update feed is written and nothing uploads.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Build the daemon (its version is baked from package.json).
(
    cd "$ROOT/daemon"
    bun run build:release
)

# Build the app executable in release, then wrap the bundle. bundle-app.sh
# ad-hoc signs it and ships the daemon at Contents/Resources/knock.
(
    cd "$ROOT/apps/macos"
    swift build -c release
)
bash "$ROOT/scripts/bundle-app.sh" >/dev/null

VERSION="$(grep '"version"' "$ROOT/daemon/package.json" | head -1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
DIST="$ROOT/dist"
mkdir -p "$DIST"
rm -rf "$DIST/Waggle.app"
ditto "$ROOT/apps/macos/.build/Waggle.app" "$DIST/Waggle.app"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$DIST/Waggle.app" "$DIST/Waggle-$VERSION.zip"

echo "$DIST/Waggle.app"
echo "$DIST/Waggle-$VERSION.zip"
