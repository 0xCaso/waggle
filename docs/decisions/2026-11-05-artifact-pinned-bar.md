# Where should the artifact go in a narrow window?

Decided: 2026-11-05 · Case: c_6485ef9f-61de-405a-adbd-2e7c55cdde52

## Question and choice

Which change do we build so that the operator can find and open an ask's artifact at once?

The operator chose "Pinned bar": "Move the artifact into a bar directly above the answers, with its name and a dark Open button. One click shows it full size."

## Why

The operator said: "i always find it difficult to find the artifacts in this type of asks".

Agent's reasons: below 1000 pt of decision width the artifact folds into one small grey row under the question. Show then opens it low on the page. The bar fixes both problems, keeps the question first (WAG-333), and leaves the queue in place.

## Constraints

- The bar stays on screen while the question scrolls.
- One click on Open shows the artifact full size.
- The two-column layout at 1000 pt and wider does not change.
- The question stays first on a narrow page.

## Ruled out

- Preview near the top: it moves the question down, which reverses the WAG-333 order, and it does not suit a long write-up.
- Two columns sooner: the queue disappears without the operator asking, and it does not help under 860 pt.

## Comments

none

## Open questions

none

## Sources

- Case c_6485ef9f-61de-405a-adbd-2e7c55cdde52
- `apps/macos/Sources/Knock/Plan/AskArtifactLayout.swift` (lines 20-31 and 113-131)
- The operator's screenshot of 5 Nov 2026
