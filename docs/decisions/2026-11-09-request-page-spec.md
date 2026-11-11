# Is the spec for the simpler request page correct?

Decided: 2026-11-09 · Case: c_848b3ed3-48ac-4fc5-8791-1d03e9f5c407

## Question and choice
Approve or change each of the 10 sections of `docs/specs/2026-11-09-request-page-spec.md`. The operator chose "Approve" on all 10, with four comments (see Comments). The spec now holds those four changes.

## Why
- The operator approved each section with no change of direction.
- Mine: each section applies a rule of `docs/decisions/2026-11-09-request-page-rules.md`, and Appendix A of the spec puts every function of today's page in a place.

## Constraints
- C1. One decision column on the right, 440 pt, in the pane and in full size; with no artifact the column is the page, 640 pt at most; the answer box and send row stay pinned at the column bottom.
- C2. The header is the top bar plus at most one context line (follow-up or replaces, plan stage track, status). Stepped asks show step numbers only. The previous answer folds to "You chose X · Show".
- C3. The options show once. Pro, con and effect counts are always visible; the popover shows the full pros and cons on hover and focus, as today.
- C4. Lean and Rule out are always visible. They move to hover and focus only when the row is too narrow and one line high for them.
- C5. The 9 chips and quick replies are behind one "Ask for…" button; its panel keeps all of today's keys.
- C6. The answer box height comes from the real text view. It never clips or hides a word. It grows when the text needs it; at rest it shares the row with the buttons as today, and moves to its own row only when the text needs the width. The scroller is visible when text is hidden.
- C7. Quiet buttons go into More when there is no space; they are never cut with "…". All of today's Send labels and keys stay.
- C8. Tabs Decision · Conversation · Comments in the pane and in full size. The Conversation tab follows the AI Elements patterns (message actions on hover, long text folds after 6 lines, tool steps fold, earlier requests at the top), with no left border on the latest message.
- C9. Full size: the column gets narrower (to 340 pt) when the artifact area would drop under 60 % of the window. One / Set and Compare are segmented switches. All keys stay.
- C10. Status is one line in the context line, with a button only when there is something to do. A failed delivery must be easy to see and read: red icon and text with the reason, high contrast, and it stays until Retry works or the operator dismisses it.
- C11. The sidebar still folds (⌘[, rail). Working gets a fold "WORKING · N", closed by default, the choice saved.
- C12. Every function in Appendix A of the spec keeps a place. No function is lost.

## Ruled out
- "Change" on each section: the operator approved all 10.
- Lean and Rule out only on hover (my first draft of section 3): the operator wants them hidden only when the row has no space.
- The answer field always on its own row (my first draft of section 4): the operator wants it wider only when needed.
- A fixed 440 pt column in full size: the operator wants care for the artifact width.

## Comments
- Section 3, Lean and Rule out on hover: "only if they are not visible because the row is narrow and not tall". Done: C4; spec section 3 changed.
- Section 4, answer box: "we need to see how this works; I would widen it when needed". Done: C6; the field moves to its own row only when the text needs the width; the task is checked in the running app.
- Section 7, artifact gets less width: "we actually need to be careful about this". Done: C9; the column narrows to 340 pt to keep the artifact at 60 % of the window, checked on 1440 × 900 and full screen.
- Section 8, failed delivery is less loud: "what matters is being able to read it / see it". Done: C10.

## Open questions
- How the answer box looks when it moves to its own row: checked in the running app during the task, then shown to the operator with a recording.

## Sources
- Case c_848b3ed3-48ac-4fc5-8791-1d03e9f5c407; earlier case c_b8e9f302-bf2b-4b7c-8fd3-2bed78463cd3
- docs/specs/2026-11-09-request-page-spec.md
- docs/decisions/2026-11-09-request-page-rules.md
- design/mockups/2026-11-09-request-page/FUNCTIONS.md
- https://ui.shadcn.com/docs/ai-elements
