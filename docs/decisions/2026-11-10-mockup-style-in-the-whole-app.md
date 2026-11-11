# How far do I take the mockup style in the rest of the app?

Decided: 2026-11-10 · Case: c_574c7c3c-91c7-4528-8693-934b8892b913

## Question and choice
The operator wants the mockup style in the whole app, not only in the decision column. Two questions:
- Screens that no mockup draws (Home, Settings, Onboarding, New idea, Plan, Usage, menu bar): the operator chose a mix of "Same style, no mockups" and "Mockups first, then build": "mix di 1 e 2, i nuovi mockup devono essere sullo stile del mockup B, e l'app però non deve cambiare troppo dal punto di vista funzionale".
- Pane borders: "Both borders, saved": "Both borders move: sidebar and artifact, artifact and decision column. The app keeps the widths. A double click sets the default width again."

## Why
- The operator: the first mockups were "for the whole app, not only the right part" (mockup B, attached again in the reply).
- The operator, in a recording: drag this border to resize the left and the middle part, and this border to resize the whole right part or the middle part.
- Mine: the sidebar, top bar and pane header that mockup B and the case-map mockup draw get matched with no new question; the other screens get mockups first, because no mockup shows them.

## Constraints
- The sidebar, top bar, pane header and artifact pane match `design/mockups/2026-11-09-request-page/index.html` (variant `inplace`) and `design/mockups/2026-11-09-request-page-cases/index.html`, checked side by side at the same size.
- The screens without a mockup get new mockups in the style of mockup B first; the operator picks; then I build. This is the next step, not PR #1 (see Comments).
- Those mockups change style, not function: each screen keeps its controls, flows and layout as far as the style allows.
- Both pane borders move by drag; the widths stay after a restart; a double click sets the default width again.
- The decision column keeps a minimum of 360 pt and a maximum of 640 pt.
- No function is lost (FUNCTIONS-CHECK).

## Ruled out
- Same style with no mockups only: the operator wants to see the other screens in the style of B first.
- Mockups with new layouts and flows: "l'app però non deve cambiare troppo dal punto di vista funzionale".
- A second PR for the other screens: not chosen.
- Sidebar border only: the operator wants both borders to move.

## Comments
- "Can you get back the first mockup? You made it for the whole app": done; it is mockup B. The sidebar and header now get matched to it (task 12).

- 2026-11-10, after the pick: "forse lascerei stare perché effettivamente il redesign di tutta l'app può essere troppo grossa come task e in caso possiamo dire nella pull request che quello sarebbe il next step". The other screens leave PR #1; the PR names them as the next step. The first canvas stays in `design/mockups/2026-11-10-other-screens/`. PR #1 keeps the sidebar, header and both pane borders.

## Open questions
- Which direction for each screen without a mockup: the next mockup round, in the next PR.

## Sources
- Case c_574c7c3c-91c7-4528-8693-934b8892b913
- design/mockups/2026-11-09-request-page/index.html (variant inplace)
- design/mockups/2026-11-09-request-page-cases/index.html
- docs/decisions/2026-11-10-match-request-page-to-mockups.md
