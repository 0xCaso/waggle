# How do I match the request page to mockup B?

Decided: 2026-11-10 · Case: c_85293341-be6c-4e69-8de4-5b4ac7a4deb2

## Question and choice
The app moved away from mockup B (chosen 9 Nov, case c_2611be01) and from the case map mockup. How do I match it, and what do I do where the mockups conflict with the spec or the operator's notes?
- Lean and Rule out: "Small icons on each card": small ◐ and × icons on each card, next to the key number on the right, always visible.
- Answer box: "Field on its own row": the field on its own row. Under it: Let's discuss · Show me more · Ask for… on the left, "Send: <option> ↵" on the right.
- Need text: "Quiet honey box": a honey box as in the case map mockup, with the bold lead sentence and "Why you"; the rest behind "▸ Show …"; the table styled as in mockup B.

## Why
- The operator: "I want everything identical, really all the style must be perfectly identical, so font, font weight, layout and so on. We must find all the style differences and apply them again, because I really want it identical."
- The operator, earlier on 10 Nov: the field on its own row "is the best version, I would keep it by default", and the half-moon "shown by default".
- Mine: the app column is the column of the case map mockup, so that mockup sets the sizes; mockup B sets the parts the case map does not show.

## Constraints
- Every font, font weight, size, line height, color, border, radius, padding and gap in the decision column equals the mockup CSS: `design/mockups/2026-11-09-request-page-cases/index.html` (column, 440 pt) first, `design/mockups/2026-11-09-request-page/index.html` variant `inplace` for what the case map does not show.
- Option cards as in the mockups: radio (box for many), title 13.5 pt semibold, "★ Recommended" tag next to the title, key on the right; the picked card opens with description, pros and cons in 2 columns, dashed line, "Why I recommend it"; the other cards show the first pro, the first con, "+N more".
- Lean ◐ and Rule out × stay on each card, always visible, next to the key (the only part not in the mockups).
- The answer field stays on its own row; the row under it holds the tools on the left and "Send: <option> ↵" on the right.
- The need is a quiet honey box; tables in it have a grey header row, borders and numbers aligned right.
- No function is lost (spec C12; `design/mockups/2026-11-09-request-page/FUNCTIONS-CHECK.md`).
- Each difference is checked by a side-by-side render: mockup and app at the same size.

## Ruled out
- Lean and Rule out only on the open card: two clicks to lean on a closed option.
- Lean and Rule out on hover: the operator does not want icons that show only on hover.
- Field and Send on one row, as in B: in the 440 pt column a long Send label leaves the field about 250 pt.
- Plain need text, as in B: the operator chose the honey box of the case map mockup.
- The compact rows with ✓ ⚠ → counts of spec C3: not in the mockups.

## Comments
- "What do you mean by Lean and Rule out?": the two buttons on each option. Lean (◐) says "I lean to this option, tell me more" and keeps talking. Rule out (×) says "not this one" and greys out the option. They exist in today's app; mockup B does not draw them. Answered in the closing update.
- "Everything identical, font, font weight, layout": done as the first constraint and the first task (a full style audit, mockup CSS against the Swift values).

## Open questions
none

## Sources
- Case c_85293341-be6c-4e69-8de4-5b4ac7a4deb2; earlier cases c_2611be01-5d90-411d-bbbe-ef4cf94f0641 (direction B), c_848b3ed3-48ac-4fc5-8791-1d03e9f5c407 (spec)
- design/mockups/2026-11-09-request-page/index.html (variant inplace)
- design/mockups/2026-11-09-request-page-cases/index.html
- docs/decisions/2026-11-09-request-page-spec.md
