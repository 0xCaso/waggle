#!/usr/bin/env bash
# Waggle release (KNOCK-21): bumps the build number, builds the daemon and the app,
# zips Waggle.app, signs the zip with Sparkle sign_update, writes appcast.xml, wraps the app
# in Waggle.dmg for the first install, and (unless --dry-run) publishes a GitHub release and
# tags the repo.
#
#   scripts/release.sh <version> [--dry-run] [--notes <file>] [--ed-key-file <file>] [--feed-url <url>]
#
# --dry-run does every step except the GitHub upload and the tag, and prints the
# appcast. It never touches the Keychain: it mints a throwaway EdDSA key.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/sparkle-tools.sh"

VERSION=""
DRY_RUN=0
NOTES_FILE=""
ED_KEY_FILE=""
FEED_URL="https://github.com/waggle-so/waggle-releases/releases/latest/download/appcast.xml"
DOWNLOAD_URL_PREFIX=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --notes) NOTES_FILE="$2"; shift 2 ;;
        --ed-key-file) ED_KEY_FILE="$2"; shift 2 ;;
        --feed-url) FEED_URL="$2"; shift 2 ;;
        --download-url-prefix) DOWNLOAD_URL_PREFIX="$2"; shift 2 ;;
        -*) echo "release.sh: unknown option: $1" >&2; exit 2 ;;
        *) VERSION="$1"; shift ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "usage: release.sh <version> [--dry-run] [--notes <file>] [--ed-key-file <file>] [--feed-url <url>]" >&2
    exit 2
fi

# Refuse to run with a dirty tree (KNOCK-21).
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "error: working tree is dirty; commit or stash first." >&2
    exit 1
fi

# Signing key. Dry-run without a key mints a throwaway pair so it never touches
# the real Keychain; a real release signs with the Keychain unless --ed-key-file
# (tests) is given.
SIGN_ARGS=()
KEYDIR=""
if [ -n "$ED_KEY_FILE" ]; then
    SIGN_ARGS=(--ed-key-file "$ED_KEY_FILE")
elif [ "$DRY_RUN" = "1" ]; then
    KEYDIR="$(mktemp -d "${TMPDIR:-/tmp}/knock-release-XXXXXX")"
    bun "$ROOT/scripts/lib/sparkle-ed25519.mjs" generate "$KEYDIR" >/dev/null
    ED_KEY_FILE="$KEYDIR/ed25519.seed"
    SIGN_ARGS=(--ed-key-file "$ED_KEY_FILE")
    PUBLIC_KEY="$(cat "$KEYDIR/ed25519.pub")"
    echo "release.sh: dry-run using a temporary signing key" >&2
fi

# The public key (SUPublicEDKey). A real release reads it from the environment,
# else from the committed scripts/sparkle-public-key file; a dry-run already
# minted one above (and must keep using it, so the file is read only when the
# variable and the minted key are both empty).
PUBLIC_KEY="${KNOCK_SPARKLE_PUBLIC_KEY:-${PUBLIC_KEY:-}}"
if [ -z "$PUBLIC_KEY" ] && [ -f "$ROOT/scripts/sparkle-public-key" ]; then
    PUBLIC_KEY="$(cat "$ROOT/scripts/sparkle-public-key")"
fi
if [ -z "$PUBLIC_KEY" ]; then
    echo "error: KNOCK_SPARKLE_PUBLIC_KEY is required. Run generate_keys once" >&2
    echo "(docs/RELEASE.md) and set KNOCK_SPARKLE_PUBLIC_KEY to its public key." >&2
    exit 1
fi

CURRENT_BUILD="$(cat "$ROOT/apps/macos/Resources/BuildNumber")"
NEXT_BUILD=$((CURRENT_BUILD + 1))

# Version bump. A dry-run never writes the tree: it passes the next values to
# the build as overrides instead, so the produced app and appcast carry the
# bumped version without leaving the repository dirty.
APP_VERSION="$VERSION"
APP_BUILD="$NEXT_BUILD"
if [ "$DRY_RUN" = "0" ]; then
    bun "$ROOT/scripts/lib/bump-version.mjs" "$ROOT/daemon/package.json" "$VERSION"
    printf '%s\n' "$NEXT_BUILD" > "$ROOT/apps/macos/Resources/BuildNumber"
fi

# Build the daemon (its version is baked from package.json) and the app.
(
    cd "$ROOT/daemon"
    # The release binary must not read the fake-service env variables (HAIL-148).
    bun run build:release
)
(
    cd "$ROOT/apps/macos"
    swift build -c release
)
KNOCK_CFBUNDLE_SHORT_VERSION="$APP_VERSION" \
KNOCK_CFBUNDLE_VERSION="$APP_BUILD" \
KNOCK_FEED_URL="$FEED_URL" \
KNOCK_SPARKLE_PUBLIC_KEY="$PUBLIC_KEY" \
KNOCK_RELEASE=1 \
    bash "$ROOT/scripts/bundle-app.sh" >/dev/null

BUNDLE="$ROOT/apps/macos/.build/Waggle.app"

# Zip the bundle with --keepParent so the archive contains Waggle.app at the top.
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/knock-release-stage-XXXXXX")"
trap 'rm -rf "$KEYDIR" "$STAGING"' EXIT
ZIP_NAME="Waggle-$VERSION.zip"
ZIP_PATH="$STAGING/$ZIP_NAME"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$BUNDLE" "$ZIP_PATH"

# Notarize (HAIL-223). A Developer ID build must be notarized and stapled before it ships; an
# ad-hoc build (no certificate) skips this step and stays as before. A dry-run never calls Apple.
# Read the signature into a variable first: with pipefail, `codesign | grep -q` fails when grep
# exits early and codesign gets SIGPIPE, which read a Developer ID build as ad-hoc (0.2.8).
SIGN_INFO="$(codesign -dvv "$BUNDLE" 2>&1 || true)"

# WAG-319: macOS keys privacy answers (Documents, Desktop) on the designated requirement. For a
# Developer ID build the app and the bundled daemon must each have a requirement made of an
# identifier and the team, never a cdhash, or every update asks again.
if [[ "$SIGN_INFO" == *$'\n'"Authority=Developer ID Application"* ]]; then
    check_requirement() { # <path> <identifier>
        local req
        req="$(codesign -d -r- "$1" 2>&1 | grep '^designated' || true)"
        if [[ "$req" != *"identifier \"$2\""* && "$req" != *"identifier $2 "* ]] || [[ "$req" == *cdhash* ]] || [[ "$req" != *"certificate leaf[subject.OU]"* ]]; then
            echo "error: $1 has an unstable designated requirement: $req" >&2
            echo "macOS would forget its privacy answers after this update (WAG-319). Nothing was published." >&2
            exit 1
        fi
    }
    check_requirement "$BUNDLE" "dev.limone.knock"
    check_requirement "$BUNDLE/Contents/Resources/waggle" "waggle"
fi
if [[ "$SIGN_INFO" == *$'\n'"Authority=Developer ID Application"* ]]; then
    if [ "$DRY_RUN" = "1" ]; then
        echo "release.sh: dry-run: the build is Developer ID signed; skipping notarization" >&2
    else
        NOTARY_PROFILE="${KNOCK_NOTARY_PROFILE:-waggle-notary}"
        if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
            echo "error: the build is Developer ID signed but the notarytool profile '$NOTARY_PROFILE' is missing or invalid." >&2
            echo "Create it once: xcrun notarytool store-credentials $NOTARY_PROFILE (docs/RELEASE.md, Signing and notarization)." >&2
            echo "Refusing to publish a signed but un-notarized build." >&2
            exit 1
        fi
        echo "release.sh: notarizing $ZIP_NAME (profile $NOTARY_PROFILE)" >&2
        NOTARY_OUT="$(xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" \
            || { printf '%s\n' "$NOTARY_OUT" >&2; echo "error: notarization failed; nothing was published." >&2; exit 1; }
        printf '%s\n' "$NOTARY_OUT" >&2
        # notarytool can exit 0 for a rejected submission; only "Accepted" may continue.
        printf '%s\n' "$NOTARY_OUT" | grep -q 'status: Accepted' \
            || { echo "error: Apple did not accept the build; nothing was published." >&2; exit 1; }
        xcrun stapler staple "$BUNDLE"
        # Re-zip so the archive carries the stapled ticket.
        rm -f "$ZIP_PATH"
        ditto -c -k --norsrc --noextattr --noqtn --keepParent "$BUNDLE" "$ZIP_PATH"
    fi
else
    echo "release.sh: ad-hoc build, skipping notarization" >&2
fi

# Disk image for the first install (WAG-369). The install page links Waggle.dmg; Sparkle keeps the
# zip. Built after the staple, so the app inside carries its ticket. A Developer ID build signs the
# image, and a real release notarizes and staples it too, so it opens with no warning offline.
DMG_PATH="$STAGING/Waggle.dmg"
DMG_IDENTITY="-"
if [[ "$SIGN_INFO" == *$'\n'"Authority=Developer ID Application"* ]]; then
    DMG_IDENTITY="${KNOCK_SIGN_IDENTITY:-}"
    if [ -z "$DMG_IDENTITY" ]; then
        DMG_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | awk '/"Developer ID Application/ { print $2; exit }')"
    fi
    [ -n "$DMG_IDENTITY" ] || { echo "error: no Developer ID identity to sign the disk image; nothing was published." >&2; exit 1; }
fi
bash "$ROOT/scripts/lib/make-dmg.sh" "$BUNDLE" "$DMG_PATH" "$DMG_IDENTITY"
if [ "$DMG_IDENTITY" != "-" ] && [ "$DRY_RUN" = "0" ]; then
    echo "release.sh: notarizing Waggle.dmg (profile $NOTARY_PROFILE)" >&2
    DMG_NOTARY_OUT="$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" \
        || { printf '%s\n' "$DMG_NOTARY_OUT" >&2; echo "error: notarization of the disk image failed; nothing was published." >&2; exit 1; }
    printf '%s\n' "$DMG_NOTARY_OUT" >&2
    printf '%s\n' "$DMG_NOTARY_OUT" | grep -q 'status: Accepted' \
        || { echo "error: Apple did not accept the disk image; nothing was published." >&2; exit 1; }
    xcrun stapler staple "$DMG_PATH"
fi

# Sign the zip with sign_update. -p prints just the EdDSA signature.
SIGN_UPDATE="$(sparkle_tool sign_update)"
SIGNATURE="$("$SIGN_UPDATE" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} -p "$ZIP_PATH" | tr -d '\n\r')"
LENGTH="$(wc -c < "$ZIP_PATH" | tr -d ' ')"
[ -n "$SIGNATURE" ] || { echo "error: sign_update produced no signature" >&2; exit 1; }

# Release notes: --notes wins, then the per-version notes file
# (docs/release-notes/<version>.md), then the commit subjects since the last
# tag. A release should always ship a version notes file (KNOCK-17 fold pass 2).
NOTES=""
if [ -n "$NOTES_FILE" ]; then
    NOTES="$(cat "$NOTES_FILE")"
elif [ -f "$ROOT/docs/release-notes/$VERSION.md" ]; then
    NOTES_FILE="$ROOT/docs/release-notes/$VERSION.md"
    NOTES="$(cat "$NOTES_FILE")"
else
    LAST_TAG="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
    if [ -n "$LAST_TAG" ]; then
        NOTES="$(git -C "$ROOT" log --pretty=format:'- %s' "$LAST_TAG..HEAD")"
    else
        NOTES="$(git -C "$ROOT" log --pretty=format:'- %s' -1)"
    fi
fi
NOTES_PATH="$STAGING/notes.txt"
printf '%s\n' "$NOTES" > "$NOTES_PATH"

# The download URL prefix is the releases repo's per-release asset path.
if [ -z "$DOWNLOAD_URL_PREFIX" ]; then
    DOWNLOAD_URL_PREFIX="https://github.com/waggle-so/waggle-releases/releases/download/v$VERSION/"
fi
ZIP_URL="${DOWNLOAD_URL_PREFIX}${ZIP_NAME}"
PUBDATE="$(date "+%a, %d %b %Y %H:%M:%S %z")"

APPCAST="$STAGING/appcast.xml"
bun "$ROOT/scripts/lib/appcast.mjs" \
    "$APPCAST" "$APP_VERSION" "$APP_BUILD" "$SIGNATURE" "$LENGTH" "$ZIP_URL" "$PUBDATE" "$NOTES_PATH"

if [ "$DRY_RUN" = "1" ]; then
    echo "=== appcast.xml ==="
    cat "$APPCAST"
    echo "=== zip: $ZIP_PATH ($LENGTH bytes) ==="
    echo "=== dmg: $DMG_PATH ($(wc -c < "$DMG_PATH" | tr -d ' ') bytes) ==="
    echo "release.sh: dry run complete (no upload, no tag)"
    exit 0
fi

# Real release: publish to waggle-so/waggle-releases and tag this repo.
# The install page links releases/latest/download/Waggle.dmg, a name that never goes stale.
# The same zip also goes up as Waggle.zip, for the agent install and for older guides. Sparkle
# keeps the versioned name from the appcast.
STABLE_ZIP="$STAGING/Waggle.zip"
cp "$ZIP_PATH" "$STABLE_ZIP"
# HAIL-176: old install guides link releases/latest/download/Knock.zip. Keep that name too while
# the legacy aliases are on (daemon/src/protocol/legacy-aliases.ts), so the old link does not break.
LEGACY_ZIP="$STAGING/Knock.zip"
RELEASE_ASSETS=("$ZIP_PATH" "$STABLE_ZIP" "$DMG_PATH")
if grep -q 'LEGACY_KNOCK_ALIASES = true' "$ROOT/daemon/src/protocol/legacy-aliases.ts"; then
    cp "$ZIP_PATH" "$LEGACY_ZIP"
    RELEASE_ASSETS+=("$LEGACY_ZIP")
fi
gh release create "v$VERSION" "${RELEASE_ASSETS[@]}" "$APPCAST" \
    --repo "waggle-so/waggle-releases" \
    --title "v$VERSION" \
    --notes "$NOTES" \
    --latest

git -C "$ROOT" tag "v$VERSION"
echo "release.sh: published v$VERSION and tagged the repo"
