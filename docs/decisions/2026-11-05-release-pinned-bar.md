# Does Open work, so that the pinned bar can ship?

Decided: 2026-11-05 · Case: c_aa9e1aba-4a27-40cc-af6c-219dcc415fc5

## Question and choice

Does Open in the test copy show the artifact full size, so that 0.2.64 can ship?

The operator chose "It opens: release": "The prototype opened full size. Merge to main, run the update check, push main, and publish 0.2.64."

## Why

The operator said: "let's push and release?"

Agent's reasons: Open is the main control of the pinned bar. Synthetic clicks changed nothing in the window, but they may not reach SwiftUI, so one real click from the operator was the proof.

## Constraints

- Merge to main, run the update check, push main, then publish 0.2.64.
- The push sends every commit that origin/main does not have, which includes the work of 0.2.60 to 0.2.63.
- Uncommitted changes in the main checkout (`design/knock.pen`, `docs/plans/`) stay out of the release.

## Ruled out

- Release without the click: a broken Open removes access to artifacts on narrow windows for all users.
- Stop and fix first: the operator saw Open work.

## Comments

none

## Open questions

The menu for several artifacts was not tried in the running app. The test copy has one artifact.

## Sources

- Case c_aa9e1aba-4a27-40cc-af6c-219dcc415fc5
- `docs/decisions/2026-11-05-artifact-pinned-bar.md`
- App tests: 2669 passed. Daemon tests: 1592 of 1593 passed with `KNOCK_HOME` set for the whole run. The other test needs it unset and passes that way.
