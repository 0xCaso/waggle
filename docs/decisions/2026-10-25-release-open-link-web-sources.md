# Release the "Open link" fix for web sources?

Decided: 2026-10-25 · Case: c_274047fd-e422-4ee3-a520-1c600acc3f35

## Question and choice
WAG-407 lets a web source show its host and an "Open link" action. Merge it and release 0.2.60?
The operator chose: "Merge WAG-407 into main and release 0.2.60 now. Do not push main."

## Why
The operator asked for it on a source card ("if it's an external website source, can you allow me following the link?").
The change is small and only adds a row. The address filter has tests and blocks every scheme except http and https.

## Constraints
- Only an http or https `ref.url` with a host and no user:password gets the row. Other schemes never open.
- The app opens the page only on a click, in the default browser. Waggle makes no network call for it.
- The host shows next to the action for every source state, "Seen by Waggle" and "Stated by the agent".
- Agent text still renders with no links (operator decision 29 Sep).
- Main is not pushed.

## Ruled out
- Let me look first: the operator did not ask for a look before release.
- Merge only: the operator wanted the link now, not in a later release.

## Comments
none

## Open questions
- Nobody has looked at the card in the running app yet.

## Sources
- Case c_274047fd-e422-4ee3-a520-1c600acc3f35
- Code: apps/macos/Sources/Knock/Protocol/Sources.swift (`SourceLink`), apps/macos/Sources/Knock/AskDoc/SourcesViews.swift (`SourceLinkRow`)
