# Which visual review feature do we build first?

Decided: 2026-10-27 · Case: c_686aeed6-226f-413f-84f8-7b00fdda1b73

## Question and choice
The question was which visual review feature to build first: "compare two screenshots", or "comments on regions
of an html_bundle". The operator chose: "Compare two screenshots" ("Show two revisions of a screenshot side by
side with one zoom, a slider and marks for what changed"). The operator added: "it should be a button 'Compare'
that activates that probably". After the design round the operator wrote: "it should be just a switch".
So Compare is one switch. It is off by default.

## Why
- Data (friend usage export, 6 to 27 Oct, app 0.2.62, 490 asks): screenshot zoom changed 104 times, 74 of them
  on 23 to 25 Oct. Zoom is the most used visual control. Compare reuses it.
- Asks with a `screenshots` artifact: 59 (12%). Asks with an `html_bundle`: 11 (2%). Most visual review is on
  screenshots.
- Region comments: 62, all of the region kind. Per day: 6, 6, 16, and 34 on 27 Oct. The habit grows, and it
  already works on screenshots and on a live bundle (HAIL-65, HAIL-75, HAIL-127).
- The set view (HAIL-73) shows screens side by side. It opened 2 times, both on 8 Oct. A new mode that hides
  behind a tab is easy to miss. A switch in the header is easy to find.

## Constraints
- Compare is a switch in the screenshot header. Off by default. One screenshot stays the main view.
- Zoom and pan stay in step on both sides.
- Local only. No new network call. No change to the bundle isolation rules in `docs/protocol-mvp.md`.
- No ask text and no comment text go into the usage log. Only coded values.
- UI copy: plain, friendly, no em-dashes.

## Ruled out
- Deeper region comments first (the agent gets the name of the part under the box and a picture): later. Only 11
  asks used a bundle, and reading the page under a box touches the isolation rules.
- A "Compare" button with text: replaced by a switch (operator, design round).

## Comments
- "it should be a button 'Compare' that activates that probably": applied in the design round. The prototype
  shows one screenshot, and Compare opens the earlier revision beside it.
- "it should be just a switch": applied. The prototype header holds a labelled switch. Side by side or Slider and
  "Show what changed" appear only while the switch is on.

## Open questions
- What does Compare show when a screenshot has one revision only (switch off and disabled, with a hint).
- Which two to compare in a set of several screens (the previous revision of the shown screen is the default).
- "Show what changed" needs a pixel diff. Build it after the first release if it costs too much.
- Add `artifact_kind` to the `comment_added` usage event, so the 62 can split by screenshot and bundle.
- Deeper region comments on a bundle: decide again after compare ships.

## Sources
- Case c_686aeed6-226f-413f-84f8-7b00fdda1b73 and the earlier case c_dfc32820-9435-4c69-943e-0f63619530fb
- `~/Downloads/waggle-usage-2026-10-27.json` (event counts only)
- `docs/decisions/2026-10-27-friend-usage-fixes.md` (T5, in the other worktree)
- `apps/macos/Sources/Knock/Review/Comments/ScreenshotSetViews.swift`, `ScreenshotViewport.swift`, `LiveCommentLayerView.swift`
