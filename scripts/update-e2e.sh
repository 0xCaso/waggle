#!/usr/bin/env bash
# Builds two bundles into a temp dir with a throwaway EdDSA key and a http://127.0.0.1
# appcast, then runs the real Sparkle update end to end (KNOCK-21): install N, launch it,
# wait for the download, quit it, wait for Sparkle to install and relaunch, and assert the
# installed bundle and the running daemon are N+1. Prints PASS only when every assertion
# holds; otherwise prints the update.log tail and FAIL.
#
# HAIL-198: N defaults to the latest published release (newest "Release x.y.z (build N)" commit), a
# Waggle.app build. KNOCK_E2E_OLD_REV=8fb7fbb picks the last Knock.app build (0.1.61); only then do
# the rename steps (HAIL-176 "sparkle-path", HAIL-180 self-rename) run.
#
# HAIL-176: N is an old build (git rev KNOCK_E2E_OLD_REV, built from a
# temporary git worktree with its own scripts), N+1 is this tree built as Waggle (Waggle.app,
# the waggle binary). The test finds out what Sparkle does to the Knock.app path (keeps it, or
# renames it to Waggle.app) and asserts both the bundled binary names and the old shim work
# whichever it does. It prints "sparkle-path: kept|renamed".
#
# HAIL-180: N+1 is a release build that runs from Knock.app (Sparkle keeps the folder). It must move
# itself to Waggle.app, relaunch from there and quit the old process. The test bundle has a temp
# KNOCK_HOME, which a real build refuses, so bundle-app.sh bakes KNOCK_E2E_SELF_RENAME=1 into its
# LSEnvironment (the e2e bundle id only honours it). After the move the test checks Waggle.app is
# there, Knock.app is gone and the old shim still connects. Then it publishes N+2 (patch + 2) and
# checks the update installs into Waggle.app.
#
# Isolation (the test never touches real state):
#   - a separate bundle id (dev.limone.knock.e2e), so Sparkle's defaults and cache
#     never touch the real dev.limone.knock domain;
#   - a temp KNOCK_HOME for the daemon, baked into LSEnvironment so the app Sparkle
#     relaunches keeps using it instead of ~/Library/Application Support/Knock;
#   - a temp EdDSA key; nothing writes to ~/Applications, the Keychain or gh.
#
# Sparkle cannot download a file:// enclosure (its NSURLSession downloader does
# not support that scheme), so the feed and the zip are served over http on
# 127.0.0.1. The ATS exception for that is emitted only when KNOCK_E2E=1, never
# for a release build.
#
# Modes (KNOCK_E2E_MODE, default "quit"):
#   quit  the flow above: download, quit N, Sparkle installs on quit.
#   toast HAIL-80: after the download, N must stay running and stay N for 90 s
#         with the update toast up (no automatic install or relaunch). Then an
#         evidence hook "clicks" Restart now (a file the app watches) and the
#         app must relaunch on N+1.
set -euo pipefail

E2E_MODE="${KNOCK_E2E_MODE:-quit}"
case "$E2E_MODE" in quit|toast) ;; *) echo "update-e2e: unknown KNOCK_E2E_MODE=$E2E_MODE" >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/sparkle-tools.sh"

# WAG-270: the e2e must leave tracked files as it found them, so release.sh can run right after.
# Record them now; cleanup compares at the end.
tracked_status() { git -C "$ROOT" status --porcelain --untracked-files=no; }
START_STATUS="$(tracked_status)"

E2E_BUNDLE_ID="dev.limone.knock.e2e"
# HAIL-198: N is the latest published release: the newest commit whose subject is
# "Release x.y.z (build N)". KNOCK_E2E_OLD_REV overrides it; 8fb7fbb ("Release 0.1.61 (build 64)")
# is the last Knock.app build and keeps the HAIL-176/HAIL-180 rename path testable on demand.
if [ -n "${KNOCK_E2E_OLD_REV:-}" ]; then
    OLD_REV="$KNOCK_E2E_OLD_REV"
else
    OLD_REV="$(git -C "$ROOT" log --format='%H %s' | grep -E '^[0-9a-f]+ Release [0-9.]+ \(build [0-9]+\)$' | head -1 | cut -d' ' -f1 || true)"
    [ -n "$OLD_REV" ] || { echo "update-e2e: no \"Release x.y.z (build N)\" commit found; set KNOCK_E2E_OLD_REV" >&2; exit 2; }
fi

cur_version() {
    grep '"version"' "$ROOT/daemon/package.json" | head -1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

# Increments the patch component of a x.y.z version (0.1.0 -> 0.1.1).
next_version() {
    local v="$1"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$v"
    echo "$major.$minor.$((patch + 1))"
}

# N is the old build (its version and build number come from its own tree, set up below);
# N+1 is this tree with the patch version one higher.
git -C "$ROOT" rev-parse --verify --quiet "$OLD_REV^{commit}" >/dev/null || { echo "update-e2e: git rev $OLD_REV not found" >&2; exit 2; }
# An old rev that predates the rename (its bundle script wraps Knock.app) is a Knock build: the
# rename steps run only for it. A Waggle build is Waggle.app with the waggle binary, and asks as waggle_ask.
if git -C "$ROOT" show "$OLD_REV:scripts/bundle-app.sh" | grep -q 'Waggle\.app'; then
    OLD_APP=Waggle; OLD_BIN=waggle; OLD_ASK_TOOL=waggle_ask
else
    OLD_APP=Knock; OLD_BIN=knock; OLD_ASK_TOOL=knock_ask
fi
echo "e2e: N = $(git -C "$ROOT" log -1 --format='%h %s' "$OLD_REV") ($OLD_APP.app)"
CUR_VERSION="$(git -C "$ROOT" show "$OLD_REV:daemon/package.json" | grep '"version"' | head -1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
NEXT_VERSION="$(next_version "$CUR_VERSION")"
NEXT2_VERSION="$(next_version "$NEXT_VERSION")"
CUR_BUILD="$(git -C "$ROOT" show "$OLD_REV:apps/macos/Resources/BuildNumber")"
NEXT_BUILD=$((CUR_BUILD + 1))
NEXT2_BUILD=$((NEXT_BUILD + 1))

# Strip any trailing slash from TMPDIR so the paths stay single-slash: the
# daemon and app command lines are single-slash, and cleanup's pkill -f must
# match them.
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
OUT="$(mktemp -d "$TMP_BASE/knock-update-e2e-XXXXXX")"
OLD_TREE="$OUT/old-tree"
# Keep KNOCK_HOME short: the unix socket path must stay under 104 bytes.
KNOCK_HOME="$(mktemp -d "$TMP_BASE/knock-XXXXXX")"
# The app logs under KNOCK_HOME (UpdaterLog), never into the real ~/Library/Logs.
LOG="$KNOCK_HOME/logs/update.log"
# Mark this test copy as already set up: the setup window (HAIL-29) would
# otherwise run `knock doctor`, whose `claude mcp list` health check starts the
# operator's real `knock mcp` with this KNOCK_HOME and leaves a stray daemon of
# the installed binary on the test socket.
touch "$KNOCK_HOME/onboarded"
APPS_DIR="$OUT/Applications"
mkdir -p "$OUT/N" "$OUT/N+1" "$OUT/N+2" "$APPS_DIR"

SERVER_PID=""
cleanup() {
    set +e
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    osascript -e "tell application id \"$E2E_BUNDLE_ID\" to quit" 2>/dev/null
    # Any app, Autoupdate helper or daemon started under the temp dirs.
    # (pgrep + kill: only pids whose command line holds the temp paths.)
    kill $(pgrep -f "$OUT") 2>/dev/null
    kill $(pgrep -f "$KNOCK_HOME") 2>/dev/null
    # Stop the N+1 daemon explicitly. pkill -f "$OUT" misses it: its KNOCK_HOME
    # is in its environment, not its command line, so after PASS the daemon the
    # relaunched app started would otherwise keep running. Read the pid from the
    # single-instance lock (daemon.ts) and stop it (KNOCK-17).
    if [ -f "$KNOCK_HOME/knock.lock" ]; then
        DAEMON_PID="$(cat "$KNOCK_HOME/knock.lock" 2>/dev/null || true)"
        [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
    fi
    # Restore package.json if the version bump is still in effect: a failure
    # between the bump and the restore must not leave the tree dirty.
    if [ -n "${PKG_BAK:-}" ] && [ -f "$PKG_BAK" ]; then
        cp "$PKG_BAK" "$ROOT/daemon/package.json"
    fi
    defaults delete "$E2E_BUNDLE_ID" 2>/dev/null
    rm -rf "$HOME/Library/Caches/$E2E_BUNDLE_ID"
    # The temporary worktree of the old build.
    git -C "$ROOT" worktree remove --force "$OLD_TREE" 2>/dev/null
    # WAG-270: the tracked files must equal what they were at the start, else say which and fail.
    END_STATUS="$(tracked_status)"
    if [ "$END_STATUS" != "$START_STATUS" ]; then
        echo "update-e2e: FAIL: tracked files changed during the run:" >&2
        printf 'before:\n%s\nafter:\n%s\n' "$START_STATUS" "$END_STATUS" >&2
        exit 1
    fi
    set -e
}
# Ctrl-C and kill also run cleanup, through the EXIT trap.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "update-e2e: FAIL: $*" >&2
    echo "--- update.log (tail) ---" >&2
    tail -n 40 "$LOG" 2>/dev/null || echo "(no update.log)" >&2
    exit 1
}

# Polls until `check` (a command) succeeds, up to `timeout` seconds.
wait_for() {
    local check="$1" timeout="$2" deadline
    deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        if eval "$check" 2>/dev/null; then return 0; fi
        sleep 1
    done
    return 1
}

# Prints the canonical (symlinks-resolved) path of a file. The daemon reports
# service.status.exec_path as a realpath, so the expected path must be resolved
# the same way (the temp dir may sit behind /tmp -> /private/tmp).
realpath_of() {
    bun -e 'import { realpathSync } from "node:fs"; process.stdout.write(realpathSync(process.argv[1]))' "$1"
}

# N: the old Knock build, from a temporary worktree of $OLD_REV with its own scripts. It reuses
# this tree's installed daemon dependencies (node_modules) and builds its own app executable.
git -C "$ROOT" worktree add --detach "$OLD_TREE" "$OLD_REV" >/dev/null 2>&1 || fail "could not create a worktree of $OLD_REV"
ln -s "$ROOT/daemon/node_modules" "$OLD_TREE/daemon/node_modules"
(
    cd "$OLD_TREE/daemon"
    bun run build
)
OLD_DAEMON="$OUT/daemon-$CUR_VERSION"
cp "$OLD_TREE/daemon/dist/$OLD_BIN" "$OLD_DAEMON"
(
    cd "$OLD_TREE/apps/macos"
    swift build -c release
)
OLD_EXEC="$OLD_TREE/apps/macos/.build/release/Knock" # the SwiftPM target keeps the old name

# N+1: this tree, built at the next version (bump package.json temporarily and restore it; dist/
# is gitignored so the tree stays clean).
PKG_BAK="$OUT/package.json.bak"
cp "$ROOT/daemon/package.json" "$PKG_BAK"
restore_pkg() {
    cp "$PKG_BAK" "$ROOT/daemon/package.json"
}
bun "$ROOT/scripts/lib/bump-version.mjs" "$ROOT/daemon/package.json" "$NEXT_VERSION"
(
    cd "$ROOT/daemon"
    bun run build
)
cp "$ROOT/daemon/dist/waggle" "$OUT/daemon-$NEXT_VERSION"
restore_pkg
# N+2 (HAIL-180): the same tree one patch higher, for the update that must land in Waggle.app.
bun "$ROOT/scripts/lib/bump-version.mjs" "$ROOT/daemon/package.json" "$NEXT2_VERSION"
(
    cd "$ROOT/daemon"
    bun run build
)
cp "$ROOT/daemon/dist/waggle" "$OUT/daemon-$NEXT2_VERSION"
restore_pkg

# The new app executable is built once. A release build keeps the e2e on the same code path a
# real release takes.
(
    cd "$ROOT/apps/macos"
    swift build -c release
)
APP_EXEC="$ROOT/apps/macos/.build/release/Knock"

# A throwaway EdDSA key pair; never the real Keychain.
bun "$ROOT/scripts/lib/sparkle-ed25519.mjs" generate "$OUT" >/dev/null
PUBLIC_KEY="$(cat "$OUT/ed25519.pub")"

# Serve OUT over http on 127.0.0.1 so Sparkle can download a real http enclosure.
bun "$ROOT/scripts/lib/serve.mjs" "$OUT" >"$OUT/port" 2>"$OUT/serve.log" &
SERVER_PID=$!
wait_for 'test -s "$OUT/port"' 10 || fail "http server did not start"
PORT="$(cat "$OUT/port")"
FEED_URL="http://127.0.0.1:$PORT/appcast.xml"
ZIP_URL="http://127.0.0.1:$PORT/Waggle-$NEXT_VERSION.zip"

# bundle_one <script dir> <executable> <version> <build> <daemon binary>: wraps one bundle with
# that tree's own bundle-app.sh (the old tree makes Knock.app, this tree makes Waggle.app).
bundle_one() {
    local tree="$1"
    local exec_path="$2"
    local version="$3"
    local build="$4"
    local daemon="$5"
    KNOCK_DAEMON_BINARY="$daemon" \
    KNOCK_CFBUNDLE_SHORT_VERSION="$version" \
    KNOCK_CFBUNDLE_VERSION="$build" \
    KNOCK_FEED_URL="$FEED_URL" \
    KNOCK_SPARKLE_PUBLIC_KEY="$PUBLIC_KEY" \
    KNOCK_RELEASE=1 \
    KNOCK_SIGN_IDENTITY=- \
    KNOCK_E2E=1 \
    KNOCK_E2E_SELF_RENAME=1 \
    KNOCK_E2E_HOME="$KNOCK_HOME" \
    KNOCK_E2E_RESTART_FILE="$KNOCK_HOME/click-restart-now" \
    KNOCK_BUNDLE_ID="$E2E_BUNDLE_ID" \
    KNOCK_EXECUTABLE="$exec_path" \
        bash "$tree/scripts/bundle-app.sh" >/dev/null
}

bundle_one "$OLD_TREE" "$OLD_EXEC" "$CUR_VERSION" "$CUR_BUILD" "$OLD_DAEMON"
[ -d "$OLD_TREE/apps/macos/.build/$OLD_APP.app" ] || fail "the old tree did not make $OLD_APP.app"
ditto "$OLD_TREE/apps/macos/.build/$OLD_APP.app" "$OUT/N/$OLD_APP.app"
ditto "$OLD_TREE/apps/macos/.build/$OLD_APP.app" "$APPS_DIR/$OLD_APP.app"

bundle_one "$ROOT" "$APP_EXEC" "$NEXT_VERSION" "$NEXT_BUILD" "$OUT/daemon-$NEXT_VERSION"
[ -d "$ROOT/apps/macos/.build/Waggle.app" ] || fail "this tree did not make Waggle.app"
ditto "$ROOT/apps/macos/.build/Waggle.app" "$OUT/N+1/Waggle.app"

# Zip N+1 and sign it exactly as a release would.
ZIP="$OUT/Waggle-$NEXT_VERSION.zip"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$OUT/N+1/Waggle.app" "$ZIP"
SIGN_UPDATE="$(sparkle_tool sign_update)"
SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$OUT/ed25519.seed" -p "$ZIP" | tr -d '\n\r')"
LENGTH="$(wc -c < "$ZIP" | tr -d ' ')"
[ -n "$SIGNATURE" ] || fail "sign_update produced no signature"

# The signature must verify, or the app's Sparkle will reject the update.
"$SIGN_UPDATE" --ed-key-file "$OUT/ed25519.seed" --verify "$ZIP" "$SIGNATURE"

bun "$ROOT/scripts/lib/appcast.mjs" \
    "$OUT/appcast.xml" "$NEXT_VERSION" "$NEXT_BUILD" "$SIGNATURE" "$LENGTH" \
    "$ZIP_URL" "$(date "+%a, %d %b %Y %H:%M:%S %z")"

# N+2: bundled, zipped and signed now, published (appcast swap) only after the rename is checked.
bundle_one "$ROOT" "$APP_EXEC" "$NEXT2_VERSION" "$NEXT2_BUILD" "$OUT/daemon-$NEXT2_VERSION"
ditto "$ROOT/apps/macos/.build/Waggle.app" "$OUT/N+2/Waggle.app"
ZIP2="$OUT/Waggle-$NEXT2_VERSION.zip"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$OUT/N+2/Waggle.app" "$ZIP2"
SIGNATURE2="$("$SIGN_UPDATE" --ed-key-file "$OUT/ed25519.seed" -p "$ZIP2" | tr -d '\n\r')"
LENGTH2="$(wc -c < "$ZIP2" | tr -d ' ')"
[ -n "$SIGNATURE2" ] || fail "sign_update produced no signature for N+2"
ZIP2_URL="http://127.0.0.1:$PORT/Waggle-$NEXT2_VERSION.zip"

# Fresh e2e state: the update log, and Sparkle's defaults + cache for the e2e
# bundle id (the real dev.limone.knock domain is never touched).
rm -f "$LOG"
defaults delete "$E2E_BUNDLE_ID" 2>/dev/null || true
rm -rf "$HOME/Library/Caches/$E2E_BUNDLE_ID"

# Launch N through LaunchServices, as a real user would. KNOCK_HOME and the
# immediate-check hook come from LSEnvironment (baked in by bundle-app.sh), not
# the shell environment, so they survive Sparkle's relaunch.
open -n "$APPS_DIR/$OLD_APP.app" || fail "open could not launch N"

wait_for 'grep -q "didDownloadUpdate" "$LOG"' 60 || fail "no download after 60s"

# The download must be extracted and armed for install-on-quit before the app
# quits; quitting mid-cycle would discard it. The update cycle finishes once the
# silent install is armed. Since 0.1.16 Knock takes the install-on-quit hook
# to show its update toast (willInstallUpdateOnQuit returns true), which
# pauses the cycle instead of finishing it; Sparkle still installs on quit,
# which the rest of this test proves.
wait_for 'grep -qE "didFinishUpdateCycle|willInstallUpdateOnQuit" "$LOG"' 30 || fail "install not armed after 30s"

# HAIL-176: Sparkle may keep the old Knock.app path or rename the bundle to Waggle.app, so the
# installed app is whichever of the two carries the version asked for (else the one that exists).
installed_app() {
    local want="${1:-}" app
    for app in "$APPS_DIR/Waggle.app" "$APPS_DIR/Knock.app"; do
        [ -d "$app" ] || continue
        if [ -z "$want" ] || [ "$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null)" = "$want" ]; then
            echo "$app"
            return 0
        fi
    done
    return 1
}
installed_version() {
    local app
    app="$(installed_app "${1:-}")" || return 1
    defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null
}
installed_build() {
    local app
    app="$(installed_app "${1:-}")" || return 1
    defaults read "$app/Contents/Info" CFBundleVersion 2>/dev/null
}

if [ "$E2E_MODE" = "toast" ]; then
    # HAIL-80: the toast waits. Knock must present it, then do nothing for 90 s.
    wait_for 'grep -q "toastPresented" "$LOG"' 30 || fail "update toast was never presented"
    echo "e2e: $(date "+%H:%M:%S") toast presented, watching for an automatic install for 90 s"
    if wait_for 'grep -qE "willInstallUpdate |updaterShouldRelaunchApplication|updaterWillRelaunchApplication|appLaunch version='"$NEXT_VERSION"'" "$LOG"' 90; then
        fail "Knock installed or relaunched on its own while the toast was up"
    fi
    [ "$(installed_version)" = "$CUR_VERSION" ] || fail "installed bundle changed before Restart now (got $(installed_version))"
    grep -q "willInstallUpdateOnQuit" "$LOG" || fail "no willInstallUpdateOnQuit line before install"
    echo "e2e: $(date "+%H:%M:%S") still $CUR_VERSION after 90 s, clicking Restart now"
    touch "$KNOCK_HOME/click-restart-now"
    wait_for 'grep -q "restartNowClicked" "$LOG"' 30 || fail "the Restart now click never reached the app"
    wait_for '[ "$(installed_version "'"$NEXT_VERSION"'")" = "'"$NEXT_VERSION"'" ] && [ "$(installed_build "'"$NEXT_VERSION"'")" = "'"$NEXT_BUILD"'" ]' 90 \
        || fail "installed bundle is not $NEXT_VERSION (build $NEXT_BUILD) after Restart now"
    wait_for "grep -q 'appLaunch version=${NEXT_VERSION}' \"$LOG\"" 90 || fail "app did not relaunch on $NEXT_VERSION after Restart now"
    # The click must come before the install in the log.
    click_line="$(grep -n "restartNowClicked" "$LOG" | head -1 | cut -d: -f1)"
    install_line="$(grep -n "willInstallUpdate " "$LOG" | head -1 | cut -d: -f1)"
    [ "$click_line" -lt "$install_line" ] || fail "install happened before the Restart now click"
    echo "update-e2e: PASS (toast) N=$CUR_VERSION (build $CUR_BUILD) stayed up 90 s, then Restart now -> N+1=$NEXT_VERSION (build $NEXT_BUILD) in $OUT"
    exit 0
fi

# HAIL-27: keep an old shim (N's binary) alive through the update. Its HOME is a temp dir whose
# Applications is a link to the e2e Applications folder, so the old shim looks for the app exactly
# where a real old shim would (~/Applications/Knock.app/Contents/Resources/knock) and, when it
# reconnects after the update, starts the NEW daemon from there, not the old N binary. The shim
# holds a blocking knock_ask (the old tool name) so its case.wait reconnects when the daemon dies.
SHIM_HOME="$OUT/shim-home"
mkdir -p "$SHIM_HOME"
ln -s "$APPS_DIR" "$SHIM_HOME/Applications"
KNOCK_HOME="$KNOCK_HOME" HOME="$SHIM_HOME" KNOCK_ASK_WAIT_MS=600000 SHIM_ASK_TOOL="$OLD_ASK_TOOL" \
    bun "$ROOT/scripts/lib/shim-ask.mjs" "$OUT/N/$OLD_APP.app/Contents/Resources/$OLD_BIN" \
    >"$OUT/shim.log" 2>&1 &
SHIM_DRIVER_PID=$!
sessions_live() {
    bun "$ROOT/scripts/lib/rpc-call.mjs" "$KNOCK_HOME/knock.sock" service.status 2>/dev/null \
        | sed -E 's/.*"sessions_live":([0-9]+).*/\1/'
}
wait_for '[ "$(sessions_live)" -ge 1 ]' 30 || fail "old shim never connected to the daemon"
echo "e2e: $(date "+%H:%M:%S") old shim connected, quitting N"

# Quit N gracefully so Sparkle installs the downloaded update and relaunches.
echo "e2e: $(date "+%H:%M:%S") quitting N"
osascript -e "tell application id \"$E2E_BUNDLE_ID\" to quit"

# Sparkle replaces the bundle in place and relaunches; the installed Info.plist
# then shows the N+1 version and build.
wait_for '[ "$(installed_version "'"$NEXT_VERSION"'")" = "'"$NEXT_VERSION"'" ] && [ "$(installed_build "'"$NEXT_VERSION"'")" = "'"$NEXT_BUILD"'" ]' 90 \
    || fail "installed bundle is not $NEXT_VERSION (build $NEXT_BUILD)"
INSTALLED="$(installed_app "$NEXT_VERSION")"
echo "e2e: $(date "+%H:%M:%S") bundle installed ($NEXT_VERSION) at $INSTALLED"

# HAIL-176: what did Sparkle do to the Knock.app path?
if [ "$OLD_APP" = Waggle ]; then
    SPARKLE_PATH=none
    [ "$INSTALLED" = "$APPS_DIR/Waggle.app" ] || fail "Waggle.app was not updated in place (got $INSTALLED)"
    echo "e2e: Waggle.app was updated in place (no rename path for this N)"
elif [ "$INSTALLED" = "$APPS_DIR/Knock.app" ]; then
    SPARKLE_PATH=kept
    echo "sparkle-path: kept (Knock.app was updated in place)"
else
    SPARKLE_PATH=renamed
    echo "sparkle-path: renamed (Knock.app became Waggle.app)"
    [ ! -d "$APPS_DIR/Knock.app" ] || fail "both Knock.app and Waggle.app exist after the update"
fi

# Whatever the path, the new bundle must be a Waggle bundle with the binary under both names
# (the knock link is there while the legacy aliases are on), and the plugin folders renamed.
[ "$(defaults read "$INSTALLED/Contents/Info" CFBundleName)" = "Waggle" ] || fail "CFBundleName is not Waggle"
[ -x "$INSTALLED/Contents/MacOS/Waggle" ] || fail "Contents/MacOS/Waggle is missing"
[ -x "$INSTALLED/Contents/Resources/waggle" ] || fail "Contents/Resources/waggle is missing"
[ -L "$INSTALLED/Contents/Resources/knock" ] || fail "Contents/Resources/knock is not a link to waggle"
[ "$(realpath_of "$INSTALLED/Contents/Resources/knock")" = "$(realpath_of "$INSTALLED/Contents/Resources/waggle")" ] \
    || fail "the knock link does not point at the waggle binary"
[ -f "$INSTALLED/Contents/Resources/claude-plugin/waggle/.claude-plugin/plugin.json" ] || fail "the Claude Code plugin folder is not waggle"
[ -f "$INSTALLED/Contents/Resources/codex-plugin/waggle/plugin.json" ] || fail "the Codex plugin folder is not waggle"
echo "e2e: bundle names OK: Waggle, MacOS/Waggle, Resources/waggle, Resources/knock -> waggle"

# Sparkle normally relaunches the app after an install-on-quit update, but that
# relaunch is slow and variable in the temp-directory test environment (77 s to
# 229 s observed, and it can not happen at all under contention). Wait briefly
# for it, then relaunch manually so the daemon handoff is still exercised
# deterministically. LSEnvironment (baked in by bundle-app.sh) gives the manual
# relaunch the same temp KNOCK_HOME.
if ! wait_for "grep -q 'appLaunch version=${NEXT_VERSION}' \"$LOG\"" 60; then
    echo "e2e: $(date "+%H:%M:%S") Sparkle did not relaunch; relaunching manually"
    open -n "$(installed_app "$NEXT_VERSION")" || fail "open could not relaunch N+1"
fi

# HAIL-180: N+1 runs from Knock.app (Sparkle keeps the folder) and must move itself to Waggle.app,
# relaunch from there and quit. If Sparkle already named the bundle Waggle.app, there is nothing to move.
# Only an N that predates the rename (Knock.app) goes through this step.
if [ "$OLD_APP" = Knock ]; then
wait_for '[ -d "$APPS_DIR/Waggle.app" ] && [ ! -e "$APPS_DIR/Knock.app" ]' 90 \
    || fail "the app did not rename itself: Waggle.app missing or Knock.app still there (see $KNOCK_HOME/logs/migration.log)"
INSTALLED="$APPS_DIR/Waggle.app"
if [ "$SPARKLE_PATH" = "kept" ]; then
    grep -q "selfRename moved" "$KNOCK_HOME/logs/migration.log" 2>/dev/null || fail "migration.log has no selfRename moved line"
fi
fi
[ -d "$APPS_DIR/Waggle.app" ] && [ ! -e "$APPS_DIR/Knock.app" ] || fail "Waggle.app missing or Knock.app present after the update"
INSTALLED="$APPS_DIR/Waggle.app"
[ "$(defaults read "$INSTALLED/Contents/Info" CFBundleShortVersionString)" = "$NEXT_VERSION" ] || fail "Waggle.app is not $NEXT_VERSION"
wait_for 'pgrep -f "$INSTALLED/Contents/MacOS/Waggle" >/dev/null' 60 || fail "no process runs from $INSTALLED after the rename"
echo "e2e: $(date "+%H:%M:%S") $INSTALLED exists, Knock.app is gone (sparkle-path: $SPARKLE_PATH)"

# The relaunched app starts the N+1 daemon on demand after the handoff; poll the
# socket until the running daemon reports the N+1 version.
daemon_version() {
    bun "$ROOT/scripts/lib/rpc-call.mjs" "$KNOCK_HOME/knock.sock" service.status 2>/dev/null \
        | sed -E 's/.*"version":"([^"]+)".*/\1/'
}
daemon_exec_path() {
    bun "$ROOT/scripts/lib/rpc-call.mjs" "$KNOCK_HOME/knock.sock" service.status 2>/dev/null \
        | sed -E 's/.*"exec_path":"([^"]+)".*/\1/'
}
wait_for '[ "$(daemon_version)" = "'"$NEXT_VERSION"'" ]' 60 \
    || fail "running daemon did not report $NEXT_VERSION"

# The daemon must be N+1 from the installed app's binary, even though the old
# shim is still alive and reconnects (HAIL-27).
EXPECTED_DAEMON="$(realpath_of "$INSTALLED/Contents/Resources/waggle")"
wait_for '[ "$(daemon_exec_path)" = "'"$EXPECTED_DAEMON"'" ]' 60 \
    || fail "running daemon is not from the installed path (wanted $EXPECTED_DAEMON, got $(daemon_exec_path))"

# HAIL-176: the old shim (N, the knock_ask caller) must still be connected to the N+1 daemon.
wait_for '[ "$(sessions_live)" -ge 1 ]' 60 \
    || fail "the old shim is not connected to the $NEXT_VERSION daemon (sparkle path: $INSTALLED)"
echo "e2e: the old shim is connected to the $NEXT_VERSION daemon"

# HAIL-192: the ask the old shim opened before the update is still open. Answer it now, after the
# relaunch: the old shim must receive the reply, and the reply must end delivered, not failed.
OPEN_CASE="$(bun "$ROOT/scripts/lib/rpc-call.mjs" "$KNOCK_HOME/knock.sock" cases.list '{"status":"needs_you"}' \
    | sed -E 's/.*"id":"(c_[^"]+)".*/\1/')"
[ -n "$OPEN_CASE" ] || fail "the ask the old shim opened is not in the queue after the update"
bun "$ROOT/scripts/lib/rpc-call.mjs" "$KNOCK_HOME/knock.sock" reply.submit \
    '{"case_id":"'"$OPEN_CASE"'","idempotency_key":"update-e2e-hail-192","choice":"a","comments":[],"captures":[]}' >/dev/null \
    || fail "reply.submit failed after the update"
wait_for 'grep -q "shim-ask: ask returned" "$OUT/shim.log"' 30 \
    || fail "the old shim did not receive the reply sent after the update (see $OUT/shim.log)"
echo "e2e: the old shim received the reply sent after the update"

# HAIL-180: a further update (N+1 -> N+2) must land in Waggle.app. Publish N+2, restart N+1 (the
# immediate-check hook asks the feed at launch), let Sparkle download it, quit, and wait for the install.
bun "$ROOT/scripts/lib/appcast.mjs" \
    "$OUT/appcast.xml" "$NEXT2_VERSION" "$NEXT2_BUILD" "$SIGNATURE2" "$LENGTH2" \
    "$ZIP2_URL" "$(date "+%a, %d %b %Y %H:%M:%S %z")"
osascript -e "tell application id \"$E2E_BUNDLE_ID\" to quit"
wait_for '! pgrep -f "$INSTALLED/Contents/MacOS/Waggle" >/dev/null' 30 || fail "N+1 did not quit before the second update"
: > "$LOG"
open -n "$APPS_DIR/Waggle.app" || fail "open could not launch N+1 for the second update"
wait_for 'grep -q "didDownloadUpdate" "$LOG"' 90 || fail "no second download after 90s"
wait_for 'grep -qE "didFinishUpdateCycle|willInstallUpdateOnQuit" "$LOG"' 30 || fail "second install not armed after 30s"
osascript -e "tell application id \"$E2E_BUNDLE_ID\" to quit"
wait_for '[ "$(defaults read "$APPS_DIR/Waggle.app/Contents/Info" CFBundleShortVersionString 2>/dev/null)" = "'"$NEXT2_VERSION"'" ] && [ "$(defaults read "$APPS_DIR/Waggle.app/Contents/Info" CFBundleVersion 2>/dev/null)" = "'"$NEXT2_BUILD"'" ]' 90 \
    || fail "the second update did not land in Waggle.app ($NEXT2_VERSION build $NEXT2_BUILD)"
[ ! -e "$APPS_DIR/Knock.app" ] || fail "Knock.app came back after the second update"
echo "e2e: $(date "+%H:%M:%S") second update landed in $APPS_DIR/Waggle.app ($NEXT2_VERSION)"

echo "update-e2e: PASS N=$CUR_VERSION (build $CUR_BUILD) -> N+1=$NEXT_VERSION (build $NEXT_BUILD) -> Waggle.app N+2=$NEXT2_VERSION (build $NEXT2_BUILD) in $OUT"
