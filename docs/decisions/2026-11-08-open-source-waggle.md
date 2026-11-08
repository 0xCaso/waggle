# How do we open source Waggle?

Decided: 2026-11-08 · Case: c_db661ed3-9976-4a87-9b25-ad492d00fba3

## Question and choice
How do we open source Waggle: license, git history, which internal docs stay public, whether the relay goes public, and where the public repo lives?

- License: "Apache 2.0: permissive, with a patent grant. Anyone may use and fork it, also in closed products."
- History: lean to "Fresh start: one first commit in a new public repo. The private repo stays as the archive."
- Home: "Create a waggle-so org and put the public repo there as waggle-so/waggle. Move waggle-releases there too later."

## Why
- The operator checked tester-army/e2e as the model. It is Apache 2.0 with a NOTICE file, inbound = outbound contributions, no CLA, SECURITY.md with a trust model, and the full set of community files.
- The app is local-first, so adoption is the main goal. Apache 2.0 also gives a patent grant.
- A fresh start leaks nothing from 1,765 private commits (internal docs, local paths, the personal Gmail address, about 20 MB per version of the Pen file). It also needs no consent for old commits by the second author.
- An org reads as a product, not a side project, and gives room for maintainers. A move later would break forks and links.

## Constraints
- The public repo is waggle-so/waggle. The current private repo is renamed to waggle-archive and stays private with its full history.
- LICENSE is Apache 2.0, with a NOTICE file. The third-party notices stay: Mermaid, the two vendored skills (MIT), Inter Tight and JetBrains Mono (OFL).
- The Waggle name and mark stay the operator's: add TRADEMARK.md.
- Users must see no break: the Sparkle feed and downloads stay on limone-eth/waggle-releases until a planned move.
- The signing identity, the notary profile and the Sparkle private key never go into the repo or CI.
- The local-only network rules in AGENTS.md stay true and are stated in the README.

## Ruled out
- MIT: no patent grant, and no gain over Apache 2.0.
- AGPL-3.0: many companies do not allow AGPL code, and that limits adoption.
- FSL: not OSI open source, and the e2e model shows full open source works with paid hosted add-ons.
- Rewrite history: more work, and any missed file becomes public.
- Keep history as is: shows the internal docs, local paths and the personal address.
- limone-eth/waggle: reads as a side project, and a later move breaks forks and links.

## Comments
- "can you check e2e which license it has?": I first checked Waggle's own license (none: all rights reserved, waggle-releases is public with no license). Then the operator named tester-army/e2e, and I checked it (Apache 2.0, NOTICE, no CLA).
- "but how do we call the new repo then?": I proposed to keep the name waggle and rename the private repo to waggle-archive. Then I asked for the owner, and the operator chose the org.

## Follow-up decisions (case c_33b3a143-3066-4204-8e1a-e084dccc04f1, 2026-11-08)
- History: "Yes: one first commit in waggle-so/waggle. The archive keeps the full history."
- Public internal files: "docs/protocol-mvp.md, SERVICE.md, RELEASE.md, sharing.md" and "docs/decisions, with private details removed". Not public: docs/stories, MVP.md, PLAN.md, original-plan.md, docs/research, DOGFOOD, PILOT and brand notes, design/knock.pen.
- Relay: "Yes: relay/ goes public with placeholder ids and a guide to run your own."
- Ruled out: rewrite history (more work, a missed file leaks), relay private (sharing privacy claims cannot be checked).

## Open questions
- Approval from the second author (caso, 13 commits). It is not needed for a fresh start, but they may want credit in the first commit or in the README.
- When to move waggle-releases to the org.

## Sources
- Case c_db661ed3-9976-4a87-9b25-ad492d00fba3.
- Repo scan: git ls-files (no LICENSE), package.json and plugin manifests (no license field), the vendored LICENSE files, relay/wrangler.jsonc (real D1 id), .fleet/config, git history (1,765 commits, 2 authors, design/knock.pen about 20 MB per version).
- gh repo view for limone-eth/waggle, waggle-releases and knock. GitHub users API for waggle-so (free), waggle and wagglehq (taken).
- https://github.com/tester-army/e2e: LICENSE, NOTICE, CONTRIBUTING.md, SECURITY.md, README.md, .github.

## Tasks

1. **Create the org and rename the archive.** Org created 2026-11-08 (operator is admin). The rename waits for the cut: the names do not clash. Criteria: the waggle-so org exists with the operator as owner. limone-eth/waggle is renamed to limone-eth/waggle-archive and is still private. Local remotes, .fleet/config and the release docs point at the new URL. From: Constraints, line 1.
2. ~~Answer the open questions.~~ Done: see Follow-up decisions.
3. **Build the clean tree.** Criteria: a branch where docs/stories, MVP.md, PLAN.md, original-plan.md, docs/research, DOGFOOD, PILOT and brand notes, design/knock.pen, .DS_Store and .fleet/config are removed, and the /Users/limone paths are replaced. Each removed path is in .gitignore or in the archive only. docs/decisions is checked record by record for private details (local paths, personal names). Correction: an earlier scan note said one record quoted a support email; no file does. Links to removed files are fixed. From: Follow-up decisions, line 2.
3b. **Self-hostable relay.** Criteria: relay/wrangler.jsonc has placeholder ids. relay/README.md tells how to deploy your own relay. A release build can use a custom relay URL from a setting, still opt-in, still one host. AGENTS.md and the README name this setting. From: Follow-up decisions, line 3.
4. **Legal files.** Criteria: LICENSE (Apache 2.0), a NOTICE with the copyright holder and the third-party credits, and TRADEMARK.md. Each package.json and plugin manifest has "license": "Apache-2.0". From: Constraints, lines 2 and 3.
5. **Community files.** Criteria: CONTRIBUTING.md (inbound = outbound, no CLA, how to build without signing, the KNOCK_HOME and "never run waggle install" rules), SECURITY.md (private reports, response times, the trust model from docs/protocol-mvp.md), CODE_OF_CONDUCT.md, issue and PR templates, and an AGENTS.md rewritten for outside contributors. From: Why, line 1.
6. **README for strangers.** Criteria: current version, pitch, demo GIF, install, how it works (app, daemon, MCP shim), a "Privacy and network" section that lists every host and when it is called, build from source, and the license. No "friend-pilot 0.1.0" text. From: Constraints, line 6.
7. **Fresh-clone build check.** Criteria: in a clean clone with no Keychain profile, no Sparkle key and no Developer ID, `bun test`, `swift build`, `swift test` and `bash scripts/bundle-app.sh` pass and give an unsigned dev app. Each failing step is fixed or documented. From: Constraints, line 5.
8. **CI.** Criteria: GitHub Actions on a macOS runner run the daemon and app tests on each PR, plus a gitleaks job. No signing secrets are in CI. From: Constraints, line 5.
9. **Cut and publish.** Criteria: gitleaks over the final tree finds nothing. waggle-so/waggle is created with one first commit from the clean tree, using a GitHub noreply author address. The repo is made public, and waggle.so links to it. From: Question and choice, lines 2 and 3.
