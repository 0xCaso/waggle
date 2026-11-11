# Which base rules does every request page follow?

Decided: 2026-11-09 · Case: c_b8e9f302-bf2b-4b7c-8fd3-2bed78463cd3

## Question and choice
Which layout, conversation and text rules apply to every case of the request page (direction B, "options in place")? The operator chose:
- Layout: "Always the right column": "The decision is always in a right column of the same width with the same tabs. With no artifact, the column is the page. Full size uses the same column."
- Conversation: "Tab in the decision column": Decision / Conversation / Comments tabs, a one-line latest agent message and a dot on the tab when there is news.
- Text: "Cut as in the table": remove repeated labels and crumbs, fold the previous answer to one line, put the 9 chips behind one "Ask for…" button. The agent's own text stays as it is.
- Design check (before/after mockups of 4 real cases): "The cuts are OK", with changes (see Comments).

## Why
- The operator: "the decision is always on the right… it is always a column fixed on the right, even today". The rule only makes the stacked and full-size cases match.
- The operator: "the text is usually fine. it's that there are many small pieces of text shown all around". On one real page there were 16 pieces of text before the first option; the cut leaves 8.
- The operator: "we must be careful not to actually remove Waggle's functions… change what we show, but the functions must stay".
- Mine: one layout for all cases removes the three sets of rules (stacked, side by side, full size) and the second copy of the options.

## Constraints
- No function of today's request page is lost. Each control, shortcut and hover keeps a place, even if it moves or folds.
- The decision column has one width and the same tabs in the pane and in full size.
- The options show once. Each row keeps the pro and con counts; hover shows the pros and cons, as today.
- The answer box shows all the text the operator writes: it wraps and grows, and never clips or hides a word.
- The answer buttons that work today stay (Decide with changes, Ask, Back, Review and send, attachments).
- The left sidebar can collapse, as today.
- The Working section in the sidebar is collapsible and collapsed by default.
- The agent's own text in the need box is not shortened by the UI.
- The table fix in the need box (2026-11-09-request-page-ui-cleanup) stays.

## Ruled out
- Keep today's three layouts: the options dock and the full-size column would stay different.
- A 380 pt conversation column that opens by itself: it takes space from the artifact on every new reply.
- Limit the agent's text in the waggle_ask guide: the operator finds the text itself usually fine; the problem is the small pieces around it.
- Put some cut pieces back: the operator found nothing important gone, apart from the points under Comments.

## Comments
- [1] Plan follow-up, header block (follow-up line, stage track, step bar): "this still looks a bit full to me, we need to see if all of this is useful". Done: the spec merges these three lines into fewer and says what each one is for.
- [2] Sidebar: "here I would bring back the option to collapse the left sidebar". Done: constraint above; the toggle stays next to "Needs you".
- [3] Sidebar Working: "working can be expanded if you choose, and by default it is not expanded". Done: constraint above.
- [4] Answer area: "the text box is still critical, it needs a fix (e.g. it expands or wraps and something breaks / a word gets cut), and today the buttons work well (e.g. decide with changes, ask, etc...)". Done: the text box fix is its own task; today's buttons stay.
- [5] Option rows: "here I would always keep the number of pros and the number of cons; on hover it must show them, as it does today". Done: constraint above.
- [6] Conversation, latest message: "watch this border, it must go". Done: no left border on the latest message.
- [7] Conversation: "for the chat we can take ideas from https://ui.shadcn.com/docs/ai-elements". Done: the spec takes the message, reasoning and tool patterns from AI Elements as the reference for the Conversation tab (built in SwiftUI).
- [8] Full size, One / Compare: "qui forse userei comunque degli switch". Done: a segmented switch, not separate buttons.
- [9] Answer box: "in the text box I always want to be able to read everything I wrote". Done: constraint above.

## Open questions
- How the header block of a plan follow-up becomes shorter (comment 1): in the spec.
- The cases the mockups do not show (text only, reply only, review, offline, sent and done): in the spec.

## Sources
- Case c_b8e9f302-bf2b-4b7c-8fd3-2bed78463cd3
- design/mockups/2026-11-09-request-page/CASES.md
- design/mockups/2026-11-09-request-page/TEXT-PIECES.md
- design/mockups/2026-11-09-request-page-cases/index.html (before and after, 4 real cases)
- docs/decisions/2026-11-09-request-page-direction.md
- https://ui.shadcn.com/docs/ai-elements
