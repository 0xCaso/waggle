# Which layout for the shared case page?

Decided: 2026-10-18 · Case: c_d55bbdca-ab8f-42f0-bbb3-f28be7d05783

## Question and choice
Which layout gives the artifact on the shared page (app.waggle.so/d/<id>) the room it needs?

Chosen: "1 plus focus mode". "Layout 1, plus the Expand full-screen view from layout 3."

## Why
- The operator: "difficult to see the artifact in this way, the scroll is limited, the window size of the artifact as well, and i cannot open it / enlarge it."
- The operator on the round tabs: "this doesn't look like history, i think it should be hidden in a dropdown or something, with more focus on last version of the shared link".
- The artifact is the main thing teammates come for. Layout 1 gives it the height; Expand covers decks and big pages.

## Constraints
- The ask folds to one bar (question, option count, recommendation, Show). Show opens the full ask in place; the artifact keeps the rest of the height.
- Only the latest round shows by default, marked "Latest". Earlier rounds are in an "Earlier rounds (N)" dropdown (number, name, time). On an earlier round a bar says "You are viewing round N of M." with "Go to latest".
- Comment on an area, Open in new tab and Expand sit together over the artifact.
- Expand covers the window: a top bar with the round, Earlier rounds, Comment on an area, Open in new tab and Exit (Esc); comments in a slide-over with a floating Comments button.
- The comments panel folds to a thin rail.
- Comments, threads, resolve, the decided block, closed comments, live refresh and the ticket rules stay as they are.
- Phone width still works (one column).

## Ruled out
- 2 Two views: options and artifact never in view together.
- 3 Focus alone: the normal view stays small.
- 4 Long page: the question scrolls away.
- 5 Three columns: the centre is narrow on small screens.

## Comments
- Round tabs do not read as history: covered by the dropdown and the Latest mark.

## Open questions
none

## Sources
- Case c_d55bbdca-ab8f-42f0-bbb3-f28be7d05783.
- design/knock.pen frame "Shared page layouts (WAG-396)" (CR2fn): layout 1 S5GI8F, focus 3b INtVb, earlier round 5b ZsJoL.
- relay/src/page.ts (the page today).
