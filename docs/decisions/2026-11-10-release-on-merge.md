# How should a merge to main make a release?

Decided: 2026-11-10 · Case: c_06a8fa59-fee2-458b-89cd-8656762045c7

## Question and choice
A merge to main starts a signed, notarized release. Two points.

- Where the keys live: "GitHub runner, secrets". A GitHub macOS runner runs the release. The keys go into
  GitHub secrets in a `release` environment that only main can use. SECURITY.md and RELEASE.md change.
- The version: "Patch on every merge". Every merge bumps the patch. The PR label `release:minor` or
  `release:major` bumps more. The label `skip-release` makes no release.

## Why
- It is the only option that releases when the maintainer's Mac is off.
- A protected environment that only main can use limits who can read the keys.
- A patch on every merge matches "every merge makes a release". `skip-release` covers docs-only PRs.

## Constraints
- The release starts only after CI passes on the push to main, never on a pull request.
- A pull request, a fork included, never sees the keys.
- The workflow cleans up the temporary keychain and the key file, also when a step fails.
- The bump commit carries `[skip ci]`, so it starts no CI run and no second release.
- `release.sh` stays the one release path. The workflow only prepares its keys and calls it.

## Ruled out
- Runner on your Mac: the Mac must be on, and merged code runs with Keychain access.
- Prepare, you publish: not automatic.
- Only with a label: the maintainer must remember the label on each PR.

## Comments
none

## Open questions
- Notary login: the workflow uses an App Store Connect API key. The local setup uses an Apple ID with an
  app-specific password. Both work; the API key does not depend on a personal password.

## Sources
- Case c_06a8fa59-fee2-458b-89cd-8656762045c7.
- SECURITY.md (Signing), docs/RELEASE.md, scripts/release.sh.

## Tasks

1. **Add the release workflow.** Criteria: `.github/workflows/release.yml` runs on a green CI run for a
   push to main only, in the `release` environment; it calls `scripts/release.sh`; it commits the bump with
   `[skip ci]` and pushes the tag. From: Question and choice, point 1.
2. **Compute the version from the PR labels.** Criteria: `scripts/lib/next-version.mjs` gives patch, minor,
   major or skip; `daemon/test/next-version.test.ts` covers each. From: Question and choice, point 2.
3. **Update the docs.** Criteria: SECURITY.md (Signing) says where the keys live in CI; docs/RELEASE.md
   lists each secret and how to make it. From: Question and choice, point 1.
4. **One-time setup (maintainer).** Criteria: the `release` environment exists with deployment branch main;
   the seven secrets are set; the labels `release:minor`, `release:major` and `skip-release` exist; the
   token can push to main. From: Constraints, line 2.
5. **First run.** Criteria: one merge to main publishes the next patch on waggle-so/waggle-releases, and
   main gets the `Release v<version> [skip ci]` commit and the tag. From: Why, line 1.
