# Which design for the "This case is shared" sheet?

Decided: 2026-10-18 · Case: c_d500038a-8bb0-4ce8-9444-1fb1954b40e4

## Question and choice
Which design for the share sheet in the Mac app, in the shared state?

Chosen: "A Link card and rows". "A link card with a big Copy link on top. Below it are rows: Who can read (Change), Comments (a toggle), and the comment count (View). Stop sharing is in red at the bottom."

## Why
- The operator: "propose nicer UI for this as well".
- A shows the link, who can read it and the comments at once, and keeps Stop sharing away from Done.

## Constraints
- Copy link is the main action. Open page stays (the arrow in the link card).
- Change opens the audience edit in place, as today (mode and emails, Save).
- The Comments toggle closes and reopens comments (the existing Close comments path).
- The comment count row's View opens the case on the Comments tab (see the one Comments tab record).
- Stop sharing keeps its confirmation.
- The not-shared and sign-in steps of the sheet are not in this decision.

## Ruled out
- B Audience first: too much for a link share.
- C Compact: settings hidden in a menu.

## Comments
none

## Open questions
none

## Sources
- Case c_d500038a-8bb0-4ce8-9444-1fb1954b40e4.
- design/knock.pen frame "Share sheet (WAG-396)" (BTeVz), variant A SAh76.
- apps/macos/Sources/Knock/Sharing/ShareCaseView.swift (ShareSheetView).
