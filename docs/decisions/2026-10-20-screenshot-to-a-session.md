# How should "send a screenshot to a session" start?

Decided: 2026-10-20 · Case: c_e84301a9-9014-4dd3-a2ba-0778d30bde25

## Question and choice
How should the Mac app help the operator send a screenshot they took to a live agent session?
The operator chose "Badge after every screenshot": "After each screenshot, a small badge shows next to the macOS thumbnail for about 6 seconds. A click opens the panel. The shortcut and the menu bar item open the same panel at any time. Off by default in Settings."

## Why
1. The operator leaned toward "After every screenshot" and asked for "a small badge, icon or notification that one can click to trigger the sharing".
2. A badge keeps that speed without opening a full panel for screenshots that are not for an agent.
3. A notification needs permission, lands in Notification Center, and its banner sits far from the screenshot.

## Constraints
- Off by default. Settings › Screenshots turns it on. It is an add-on and never gates the main flow.
- The badge sits vertically above the macOS screenshot thumbnail, right edges aligned, and goes away after about 6 seconds.
- Waggle only reads screenshots the operator takes (files macOS marks as screen captures). Waggle never captures the screen.
- The panel sends the screenshot file path and the note through the existing session.send_prompt. No new network call. No image upload.
- Only live sessions Waggle can type into are sendable. Other sessions show "Copy path".
- The shortcut (Control Option S) and the menu bar item "Send a screenshot" open the same panel with the 3 latest screenshots, in any mode.
- UI copy plain, no em-dashes.

## Ruled out
- Full panel after every screenshot: it opens for screenshots that are not for an agent.
- Only with a shortcut: the operator wants it there without remembering a key.
- A notification: needs permission, lands in Notification Center, far from the screenshot.

## Comments
- On the A2 badge: "vertical above the screenshot thumnail?" I moved the badge from the left of the thumbnail to just above it, right edges aligned, in knock.pen.

## Open questions
- Which screenshot folder to read when the operator changed the macOS screenshot location: read it from the system setting, or search for screen captures anywhere. The build picks one and records it.
- The exact badge lifetime matches the macOS thumbnail (about 5 to 6 s); it is not readable from macOS.

## Sources
- Case c_e84301a9-9014-4dd3-a2ba-0778d30bde25.
- Design: design/knock.pen, board "Screenshot to a session · two ways to start" (rows A, A2, B).
- daemon/src/server.ts:1243 (session.send_prompt), daemon/src/protocol/rpc.ts:518 (text only, 20,000 characters).
