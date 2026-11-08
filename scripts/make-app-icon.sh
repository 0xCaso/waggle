#!/usr/bin/env bash
# Regenerates an app icon .icns. The design source is apps/macos/Resources/AppIcon.svg
# (AppIcon-dev.svg for --dev); Sources/MakeAppIcon draws the same geometry through
# KnockMark and a test checks it against the SVG. Run this whenever either changes;
# commit the resulting .icns.
#
#   scripts/make-app-icon.sh          -> apps/macos/Resources/AppIcon.icns (release)
#   scripts/make-app-icon.sh --dev    -> apps/macos/Resources/AppIcon-dev.icns (DEV band, HAIL-26)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"

DEV=0
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dev) DEV=1; shift ;;
        --out) OUT="$2"; shift 2 ;;
        -*) echo "make-app-icon.sh: unknown option: $1" >&2; exit 2 ;;
        *) echo "make-app-icon.sh: unexpected argument: $1" >&2; exit 2 ;;
    esac
done

if [ "$DEV" = "1" ]; then
    ICNS="$APP_DIR/Resources/AppIcon-dev.icns"
    EXTRA=(--dev)
else
    ICNS="$APP_DIR/Resources/AppIcon.icns"
    EXTRA=()
fi
if [ -n "$OUT" ]; then
    ICNS="$OUT"
fi

echo "Building make-app-icon..." >&2
swift build --package-path "$APP_DIR" --product make-app-icon >&2

BIN="$(swift build --package-path "$APP_DIR" --product make-app-icon --show-bin-path)/make-app-icon"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
ICONSET="$WORKDIR/AppIcon.iconset"

echo "Rendering iconset PNGs..." >&2
"$BIN" "$ICONSET" "${EXTRA[@]}" >&2

echo "Building AppIcon.icns..." >&2
iconutil -c icns "$ICONSET" -o "$WORKDIR/AppIcon.icns"

mkdir -p "$(dirname "$ICNS")"
cp "$WORKDIR/AppIcon.icns" "$ICNS"

echo "$ICNS"
