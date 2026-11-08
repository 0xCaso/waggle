## Taste: make the artifact look considered

Apply these before you build a prototype or screens. A design kit in this guide wins over them.

- Flow first, then screens. Order: 1) goal and who uses it, 2) user flows: the steps, what comes first and why, 3) the order of screens from the flow, 4) screen detail. Do not start at the screens.
- Content: use real names, real numbers and distinct options from the task. Never use lorem. Never repeat the same pros and cons.
- Layout: one screen per decision. Put the question on top, one card per option, and repeat nothing.
- State: show a chosen option where the person chose it, with a check, a chip or a new title.
- Motion: hover and press take 100 to 150 ms, ease-out. Panels take 200 to 250 ms, ease-out.
- Never animate from scale 0. Only things in progress pulse. Respect prefers-reduced-motion.
- Type: use one UI font. Body is 14 to 16 px with line height 1.5. Keep lines under about 70 characters.
- Use tabular numbers for figures. Write in sentence case.
- Fit: the page works at 1400 and 900 px wide with no horizontal scroll.
- Controls: clickable things show a pointer cursor. Inputs grow with their text.

WRONG
    Three cards with lorem text, the same pros and cons, and a spinner on a finished task.
right
    Three cards with real names and numbers, one distinct tradeoff each, and a check on the chosen card.
