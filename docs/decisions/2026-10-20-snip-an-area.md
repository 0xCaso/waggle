# Snip an area: build this design, and with which shortcut?

Decided: 2026-10-20 · Case: c_5b42ed43-8339-4dbb-bf79-cf566971ecd1

## Question and choice
A shortcut opens a crosshair. The operator drags a box, adds a note, and sends it to a live session or a new one. Which shortcut, and build the design as shown?
The operator chose Control Shift W, and "Build it".

## Why
The operator gave no note on the shortcut. Ctrl W was not taken because it deletes the last word in Terminal. The design reuses the WAG-402 send panel and the Start from a document launcher.

## Constraints
- Control Shift W opens the macOS crosshair (`screencapture -i`). Waggle gets only the box the operator draws. Esc cancels and nothing is sent.
- A menu bar item "Snip an area" with ⌃⇧W does the same.
- Settings › Screenshots gets a second section "Snip an area", Off by default. With Off, the shortcut is not registered and the menu item is hidden.
- The panel after the box: head "Send this area", meta "<w> × <h> · from <app>", the image, SEND TO with the live sessions, then a "New session" row with the launch target name and a folder chip, a note field, "Send to <name>" or "Start in <folder>", and "Cancel".
- New session starts the saved launch target (Start from a document) in the picked folder, with the note and the image path as the prompt.
- Operator comment: the "New session" row also goes into the WAG-402 screenshot panels (badge panel and shortcut panel).
- Design: design/knock.pen, board "Snip to a session · Control Shift W".

## Ruled out
- Ctrl W: it deletes a word in Terminal and in other apps while Waggle runs.
- Control Option W: it was the recommendation.

## Comments
- On the New session row: "add this option also in the screenshot picker".

## Open questions
- Where the snip files live, and when Waggle deletes them.

## Sources
- Case c_5b42ed43-8339-4dbb-bf79-cf566971ecd1.
- apps/macos/Sources/Knock/StartFromDocument/SessionLauncher.swift.
- docs/decisions/2026-10-20-screenshot-to-a-session.md.
