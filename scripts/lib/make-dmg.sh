#!/usr/bin/env bash
# Waggle disk image (WAG-369): wraps Waggle.app in a DMG for the first install. The image holds the
# app and a link to /Applications, so the person drags one onto the other. Updates do not use it:
# Sparkle keeps the zip from the appcast.
#
#   scripts/lib/make-dmg.sh <Waggle.app> <out.dmg> [<signing identity>]
#
# With a signing identity (not "-") the image is signed too. Notarizing and stapling the image is
# the caller's job (scripts/release.sh). It never opens Finder and never mounts the image.
set -euo pipefail

BUNDLE="${1:-}"
OUT="${2:-}"
SIGN_IDENTITY="${3:--}"

if [ -z "$BUNDLE" ] || [ -z "$OUT" ]; then
    echo "usage: make-dmg.sh <Waggle.app> <out.dmg> [<signing identity>]" >&2
    exit 2
fi
[ -d "$BUNDLE" ] || { echo "error: no app bundle at $BUNDLE" >&2; exit 1; }

SRC="$(mktemp -d "${TMPDIR:-/tmp}/knock-dmg-XXXXXX")"
trap 'rm -rf "$SRC"' EXIT

# ditto keeps the signature and the stapled ticket of the bundle.
ditto "$BUNDLE" "$SRC/$(basename "$BUNDLE")"
ln -s /Applications "$SRC/Applications"

rm -f "$OUT"
hdiutil create -volname "Waggle" -srcfolder "$SRC" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null

if [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT"
fi
echo "make-dmg.sh: wrote $OUT" >&2
