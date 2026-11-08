# Waggle service

This file explains how the Waggle background service runs, why it no longer uses a LaunchAgent, and
the planned path to `SMAppService`.

## Root cause of the background-item incident

The pilot first shipped `knock daemon` (now `waggle daemon`) as a LaunchAgent. That caused a "Software from Jarred Sumner
can run in the background" notice, and a stray `bun` item in Login Items & Extensions.

The cause is the way the binary is built. `bun build --compile` does not produce a new signed
program. It produces a copy of the Bun runtime with the script appended, and that copy keeps Bun's
signing identity ("Jarred Sumner", item name `bun`). A plain plist in `~/Library/LaunchAgents` is
labelled with that identity, because launchd reads the signing identity of the `ProgramArguments`
binary. So the item shows the Bun identity, not Waggle, and it stays in Login Items.

There is no way for an unsigned Waggle binary to change that label: the label is the binary's signing
identity. The fix is to stop registering a background item entirely during the pilot.

## How the service runs now

There is no LaunchAgent and no login item. The Waggle daemon starts on demand:

- `waggle mcp` (the shim) connects to the daemon socket. If the socket is unreachable, the shim starts
  `waggle daemon` detached and retries the connection for up to 3 s.
- `Waggle.app` does the same on its connect path: when the socket is unreachable, the app starts
  `waggle daemon` detached and retries for up to 3 s. The M11 "Start service" button starts
  `waggle daemon` directly.
- Starting a daemon when one is already running is safe: the extra process sees the live socket and
  exits (the single-instance rule). Two shims starting at once still end with exactly one daemon.

The daemon exits by itself after 30 minutes with no connected shim, no app client and no queued
reply. Set `KNOCK_IDLE_EXIT_MIN` to change that (minutes; `0` = never exit). Queued replies and cases
persist in the database across the exit, so nothing is lost when the daemon idles out and a later
shim or app starts it again. A connected shim holds an open socket, so a daemon with a live shim
never idles out.

For sharing (WAG-394), the daemon also stays up while the app is connected, Sharing is on and at least one case is shared, so team comments keep arriving. With the app closed it idles out as above and fetches the comments at the next start.

A shim stays listed as live between tool calls (HAIL-63). When its daemon connection closes (a
restart for an update, a crash) or the startup hello failed, the shim retries a plain connect in the
background: every 2 s for the first 30 s, then every 15 s, for as long as it runs. This loop never
starts a daemon: on-demand start stays with tool calls, so an app-driven update or quit is never
raced by a shim respawning an old daemon. On success the shim re-sends `session.hello` with the same
session id (the row goes back to `live`) and refreshes the manifest. While connected and idle, the
shim sends `session.hello` again every 60 s so `last_seen_at` stays fresh. The timers are unref'd and
never keep the process alive.

`waggle install claude` no longer writes or loads a LaunchAgent. It installs the Claude Code plugin that
ships in the app (`Contents/Resources/claude-plugin`, a local marketplace named `waggle`): `claude plugin
marketplace add <that path>`, then `claude plugin install waggle@waggle --scope user`, and it removes an
older user-level `waggle` or `knock` MCP entry, and the old `knock@knock` plugin with its `knock`
marketplace. A Claude Code without `claude plugin` still gets
`claude mcp add` (the plugin brings its own MCP server, so there is never both). `waggle install claude
--refresh` updates a plugin that is installed and does nothing otherwise; the app runs it at launch, so a
Sparkle update brings the new plugin. `waggle uninstall` removes the plugin, its marketplace and the MCP
entry. `waggle doctor` reports plugin or MCP-entry mode and flags a marketplace path that no longer exists
(the app moved: run `waggle install claude`). It also removes
also removes a legacy LaunchAgent left by an older build (bootout + delete the plist): the current
label `dev.limone.knock.daemon` and the pre-rename label `dev.hail.daemon`. `waggle uninstall` removes
the same.

## Guard: launchctl in tests

Any code path that could call `launchctl` goes through an injected runner. The real runner refuses
to run when `KNOCK_HOME` is set (the test environment) unless `KNOCK_ALLOW_LAUNCHCTL=1` is set
explicitly. This guards the 2026-09-26 incident, where a manual verification ran `waggle install
claude` with a temporary HOME and the real `launchctl` still registered a login item.

## Later: SMAppService

To show "Waggle" with the app icon in Login Items (not the Bun identity), sign and register the
service properly:

1. Sign the daemon with a Developer ID, and notarize it.
2. Place the signed daemon at `Waggle.app/Contents/MacOS/`.
3. Ship `Contents/Library/LaunchAgents/dev.limone.knock.daemon.plist` inside the app, with
   `AssociatedBundleIdentifiers = dev.limone.knock` (so macOS labels the item with the app's identity).
4. Register it with `SMAppService.agent(plistName:)`.

Login Items then show "Waggle" with the app icon. This is not built in the current story.
