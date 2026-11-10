# Releasing Waggle

Waggle updates itself with Sparkle 2. A release is one command after a one-time setup. This file is for
the maintainer.

## One-time key setup

Run this once on the Mac that publishes releases. It makes an EdDSA signing key and keeps the private
half in the Keychain.

```bash
SPARKLE_BIN_DIR=<path-to-Sparkle-bin> # see "Sparkle tools" below
"$SPARKLE_BIN_DIR/generate_keys"
```

`generate_keys` prints the public key. Save that public key: every release build passes it to the
build as `KNOCK_SPARKLE_PUBLIC_KEY`. The private key stays in the Keychain, and one copy goes into the
`release` environment secrets for the release workflow (see "Release on merge"). Never commit either
key, and never put the private key in any other file, variable or repository.

The same key signs every Waggle update. Generate it once, no matter how many releases you publish.

## Public releases repo

Host the updates in a public GitHub repo, `waggle-so/waggle-releases`. It moved there from
`limone-eth/waggle-releases` on 2026-11-08 (before that, `limone-eth/knock-releases`). GitHub redirects both old
URLs, so builds that read an old feed URL still find the appcast. Never create a new repo under an old name: that
ends the redirect and stops updates for those builds. Create it once and leave it
public, or the app cannot download updates from a friend's Mac. It holds nothing but the release
assets: each `Waggle-<version>.zip` and `appcast.xml`, plus `Waggle.zip` and `Waggle.dmg` under names that
never change. The install page links `Waggle.dmg` (the app and a link to Applications, signed, notarized
and stapled like the app). Updates keep the zip.

## Sparkle tools

`release.sh` finds Sparkle's command-line tools next to the Sparkle framework that `swift build`
fetches. After you run `swift build` once, they are at
`apps/macos/.build/artifacts/sparkle/Sparkle/bin/`. To use another copy, set `SPARKLE_BIN_DIR` to a
directory that holds `sign_update`, `generate_appcast` and `generate_keys`.

## Release on merge

A merge to main makes a release (docs/decisions/2026-11-10-release-on-merge.md). The workflow
`.github/workflows/release.yml` starts when CI passes on the merge commit, and it runs `release.sh` on a
GitHub macOS runner.

- Every merge bumps the patch (0.2.65 to 0.2.66). The PR label `release:minor` or `release:major`
  bumps more. The label `skip-release` makes no release. Create the three labels once.
- Notes come from `docs/release-notes/<version>.md` when the PR adds it, else from the PR title.
- After the release, the workflow commits the bumped `daemon/package.json` and `BuildNumber` as
  `Release v<version> [skip ci]`, pushes it to main, and pushes the tag.
- Only the tip of main releases. When two merges land close together, the newer run releases both.

One-time setup, in Settings, Environments, `release` (deployment branches: `main` only):

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application certificate and its private key, exported from Keychain Access as .p12, then `base64 -i devid.p12 \| pbcopy`. |
| `DEVELOPER_ID_P12_PASSWORD` | The password you set on that export. |
| `NOTARY_KEY_P8_BASE64` | An App Store Connect API key (Users and Access, Integrations, role Developer), `base64 -i AuthKey_<id>.p8 \| pbcopy`. |
| `NOTARY_KEY_ID` | That key's id. |
| `NOTARY_ISSUER_ID` | The issuer id on the same page. |
| `SPARKLE_ED_PRIVATE_KEY` | `generate_keys -x sparkle.key`, then the file's one line. Delete the file after. |
| `RELEASE_TOKEN` | A fine-grained token with Contents read and write on `waggle-so/waggle` and `waggle-so/waggle-releases`, and Pull requests read on `waggle-so/waggle`. If main is protected, let this token's owner bypass the rule, or the bump push fails. |

The job imports the certificate and the notary key into a temporary keychain and deletes it at the end.

## Releasing by hand

```bash
scripts/release.sh 0.1.1
```

With the public key from the key setup:

```bash
KNOCK_SPARKLE_PUBLIC_KEY="<public-key>" scripts/release.sh 0.1.1
```

The command:

1. bumps `CFBundleVersion` and the daemon version,
2. builds the daemon and the app,
3. zips `Waggle.app`,
4. signs the zip with Sparkle `sign_update` (the private key comes from the Keychain),
5. writes `appcast.xml`,
6. creates a GitHub release `v0.1.1` on `waggle-so/waggle-releases` with the zip and `appcast.xml`,
   marked latest,
7. tags the private repo `v0.1.1`.

Release notes come from `docs/release-notes/<version>.md` when that file exists, from `--notes <file>`
when you pass it, or from the commit subjects since the last tag otherwise. A release should always
write its version notes file first.

Try the whole pipeline without publishing:

```bash
KNOCK_SPARKLE_PUBLIC_KEY="<public-key>" scripts/release.sh 0.1.1 --dry-run
```

The dry run does every step except the GitHub upload and the tag, and prints the appcast. It refuses
to run with a dirty tree. A dry run without a public key mints a throwaway key so it never touches the
real Keychain.

## The Claude Code plugin ships inside the app

`scripts/bundle-app.sh` copies `plugins/claude-code/waggle/` (without tests and `tsconfig.json`) and
`plugins/claude-code/bundle/marketplace.json` into `Waggle.app/Contents/Resources/claude-plugin`, so
`release.sh` ships it with no extra step. The files are plain resources, and the bundle still signs.
Check a bundle with `claude plugin validate --strict apps/macos/.build/Waggle.app/Contents/Resources/claude-plugin`.

When the mod, the skill or the launcher changes, bump `version` in
`plugins/claude-code/waggle/.claude-plugin/plugin.json` (and the root `.claude-plugin/marketplace.json`).
Claude Code installs by version: an unchanged version means an updated Mac keeps the old plugin. At
launch the new app runs `waggle install claude --refresh`, which updates the installed plugin when its
version differs from the bundled one.

## The Codex plugin ships inside the app

`scripts/bundle-app.sh` copies `plugins/codex/waggle/` and `plugins/codex/bundle/.agents/plugins/marketplace.json`
into `Waggle.app/Contents/Resources/codex-plugin`: a local marketplace named `waggle`. `waggle install codex`
runs `codex plugin marketplace add <that path>` and `codex plugin add waggle@waggle` when `codex plugin --help`
works; otherwise it keeps the `[mcp_servers.waggle]` entry.

Bump `version` in `plugins/codex/waggle/plugin.json` whenever the hooks, the MCP config, the skill or the
launcher change. Codex has no plugin update command for a local marketplace: `waggle install codex` (and
the launch refresh, `waggle install codex --refresh`, which never installs a missing plugin) runs
`codex plugin add` again when the installed version differs from the bundled one. **A change to
`hooks/hooks.json` also needs a version bump for another reason:** Codex trusts a hook by its hash, and the
user must trust the changed hooks again (`/hooks` in Codex).

## Rolling back

There is no "downgrade" in Sparkle. To roll back, publish a higher version that contains the old code.
Bump the version, build the old revision, and release it normally. The next launch updates every Mac
to that higher version.

## Signing and notarization

A release signed with a Developer ID Application certificate keeps its macOS privacy permissions
(Desktop, Documents) across updates, because the signature gives the app a stable identity. An
ad-hoc build has none, so macOS asks again after every update.

One-time steps for the operator (team `7W9497VVEF`):

1. In Xcode, Settings, Accounts, Manage Certificates, add a **Developer ID Application** certificate
   (or create it at developer.apple.com and import it). Check it with
   `security find-identity -v -p codesigning`.
2. Create an app-specific password at appleid.apple.com, then store the notary profile once:
   `xcrun notarytool store-credentials waggle-notary --apple-id <id> --team-id 7W9497VVEF`.

After that, `scripts/release.sh` does the rest:

- `scripts/bundle-app.sh` picks the identity from `KNOCK_SIGN_IDENTITY`, else the first
  "Developer ID Application" identity in the keychain, else ad-hoc (`-`). It prints which one it used.
  Force ad-hoc with `KNOCK_SIGN_IDENTITY=-`.
- A real identity signs inside-out with the hardened runtime and a timestamp: the `waggle` daemon
  (entitlements in `scripts/entitlements/`), the Sparkle helpers, Sparkle.framework, then the app.
- `release.sh` notarizes the zip with the profile `KNOCK_NOTARY_PROFILE` (default `waggle-notary`),
  staples the app, zips it again, and only then does the Sparkle signature and the appcast. If the
  profile is missing, it stops. It never publishes a signed but un-notarized build.
- A `--dry-run` signs but does not call Apple.

Without the certificate, the build stays ad-hoc and the first install still needs right-click, Open.

## Release day for the rename (HAIL-171, Waggle 0.2.0)

1. Rename the GitHub repo `limone-eth/knock-releases` to `waggle-so/waggle-releases`. GitHub redirects the
   old URL, so builds before 0.2.0 (which read the old feed URL) still find the appcast. Do this before
   you run `scripts/release.sh`, which publishes to the new name.
2. Write `docs/release-notes/0.2.0.md`. It must list what a person changes by hand (see that file).
3. Run `scripts/release.sh 0.2.0`. It also uploads `Knock.zip`, so old install links keep working, while
   `LEGACY_KNOCK_ALIASES` is on (`daemon/src/protocol/legacy-aliases.ts`).
4. About two weeks later, set `LEGACY_KNOCK_ALIASES` to false (and the Swift twin
   `apps/macos/Sources/Knock/Support/LegacyNames.swift`), then delete the code that reads them: the
   `knock_*` tool aliases, the `knock` link in `scripts/bundle-app.sh`, the legacy plugin and entry moves,
   and the `knock` lines in the plugin launchers.
