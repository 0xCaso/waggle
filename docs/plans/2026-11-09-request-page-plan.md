# Plan: a simpler request page

Brief for any agent: read first `docs/decisions/2026-11-09-request-page-spec.md` (the record, constraints C1–C12), then `docs/specs/2026-11-09-request-page-spec.md` and `design/mockups/2026-11-09-request-page/FUNCTIONS.md` (file:line of each function today). Code: `apps/macos/Sources/Knock/`. Tests: `apps/macos/Tests/KnockTests/` (4 `WebViewCaptureControllerTests` fail on main too; ignore them). Each task ends with the build green, its tests passing, and a screenshot or recording from the running app.

Order: tasks 1–2 are independent and fix today's pain first; 3 is the base for 4–10; 11–12 close.

## 1. Answer box: measure the real text, never hide a word
From: C6 "The answer box height comes from the real text view. It never clips or hides a word." and C7.
- Height comes from the field's own `NSTextView` layout manager after each edit and width change; the second estimate in `Composer/PromptBarLogic.swift:45-64, 100-131` is gone.
- No unmeasured first frame: long text pasted in a new case shows all lines on the first frame.
- At rest the field shares the row with the buttons; when the text needs more width, the field moves to its own row above the buttons.
- Grows up to 40 % of the column height (at least 6 lines); past that it scrolls and the scroller stays visible.
- The placeholder wraps; no "…".
- Quiet buttons move into More one by one when there is no space; none show "…". Send keeps every label of `PromptBarLogic.swift:436-490`.
- "Use this reply" puts the caret at the end. IME composition still works.
- "Something else" in the Ask for panel uses the same field.
- Unit tests for the height rule (1 line, wrapped line, 10 lines, 40 lines, width change). Recording: type a long answer in the pane and in full size; every word stays visible.

## 2. Sidebar: Working folds
From: C11 "Working gets a fold \"WORKING · N\", closed by default, the choice saved."
- `Queue/SidebarSections.swift:194` gets a fold header like Answered: "› WORKING · N".
- Closed on first launch; the choice is saved in its own key, as `queueAnsweredGroupOpen`.
- ↑/↓ j/k skip folded rows; the sidebar fold (⌘[, rail) still works.
- Test for the default and the saved choice. Screenshot open and closed.

## 3. One layout: the decision column
From: C1 "One decision column on the right, 440 pt, in the pane and in full size…"
- One layout replaces stacked / side by side in `Plan/AskArtifactLayout.swift:16-27, 83-86`.
- With an artifact: artifact left, column 440 pt right. Artifact area under 480 pt: the artifact folds to today's pinned bar at the top of the column.
- No artifact: the column is the page, centred, 640 pt at most.
- The column scrolls as one piece; the answer box and send row are pinned at its bottom on any window height (no `.clipped()` cut, `Queue/CasePaneView.swift:244, 943, 1198`).
- The options dock and the option cards are one list (`Composer/ComposerCardView.swift:242-283`).
- Screenshots: text only, one artifact, narrow pane, short window (700 pt high).

## 4. Header and context line
From: C2 "The header is the top bar plus at most one context line… The previous answer folds to \"You chose X · Show\"."
- Top bar: crumb / title · arrived · waiting; Share, Conversation (⌘]), fold both (⌘\), ⋯ Dismiss.
- Context line: follow-up or replaces (click opens the first ask), plan stage track as words with ✓ and the See revision menu, status (task 10). A long title is cut with "…" and the full title is in the tooltip.
- Removed: stage label, second crumb, group label, "WHAT I NEED FROM YOU" label. "Why you" is the last grey line of the need box. The table fix stays.
- Stepped asks: step numbers 1 · 2 · 3 · Send with title tooltips; Back, Next, Review and send unchanged.
- Previous answer: "You chose X · Show", opens in place.
- Screenshot of the plan follow-up case next to its mockup frame (`plan`).

## 5. Option rows
From: C3 "Pro, con and effect counts are always visible…" and C4 "Lean and Rule out are always visible…"
- Counts (icon + number) always visible; popover on hover and keyboard focus as today (`Composer/CalmOption.swift:397-411`).
- Lean ◐ and Rule out × always visible; on hover and focus only when the row is narrow and one line high; a set mark always shows.
- Keys 1–9, ⌘D, Recommended pill, Your answer tag, pick-several header, review hint unchanged.
- "Options from the update · First options": first options open in their own fold, not in the current options' scroll.
- Tests for the narrow-row rule. Screenshots: wide row, narrow one-line row, pick several.

## 6. "Ask for…" button
From: C5 "The 9 chips and quick replies are behind one \"Ask for…\" button; its panel keeps all of today's keys."
- One button at the left of the send row opens today's panel (`Composer/AskForDetailView.swift`).
- The panel holds quick replies, ask pills, Something else; keys 1–N, ?, Esc, ⌘↵ work.
- No chip row under the options. Recording: open with ?, pick one, send.

## 7. Tabs and the Conversation tab
From: C8 "Tabs Decision · Conversation · Comments in the pane and in full size. The Conversation tab follows the AI Elements patterns…"
- Tabs at the top of the column; dot on Conversation for a new agent message; one line with the latest message above the tabs, no left border; click opens the tab.
- Messages: who, time, text; yours right, agent left, no bubble border; Copy and See vN on hover; long text folds after 6 lines; working notes and tool steps fold to one line.
- Earlier requests list and "Open the history ›" at the top of the tab (`AskDoc/EarlierAsks.swift`).
- ⌘] and the top bar icon open the tab; the 380 pt column (`Queue/ConversationSplit.swift`) is gone.
- Screenshot next to the `conv` mockup frame.

## 8. Comments tab
From: C8 "Tabs Decision · Conversation · Comments in the pane and in full size."
- The comments section under the artifact (`AskDoc/ArtifactCommentsSection.swift`) moves into the tab, with count.
- Cards: Show, Edit, Delete, inline Save; "N comments on vN · view vN"; late team comments; unread dot.
- Screenshot with 3 comments in the pane and in full size.

## 9. Full size
From: C9 "the column gets narrower (to 340 pt) when the artifact area would drop under 60 % of the window. One / Set and Compare are segmented switches. All keys stay."
- Same column and tabs as the pane; width 440, down to 340 when the artifact would be under 60 %.
- One / Set and Compare (Side by side / Slider) are segmented switches.
- Keys I C E Esc ↵ ⌘0 ⌘1 zoom ⌘R ⌘[ ⌘] ⌘\ and versions, badges unchanged.
- Screenshots on 1440 × 900 and full screen; the artifact width is written next to each.

## 10. Status line
From: C10 "Status is one line… A failed delivery must be easy to see and read…"
- Each state of the spec table (section 8) shows in the context line with its buttons; banners and strips go away (`Composer/Delivery/*`, `Queue/SessionClosed.swift`, `Queue/AgentStatusStrip.swift`, `Queue/CasePaneView.swift:818-844`).
- Failed: red icon and text with the reason, contrast at least 4.5:1 in light and dark, stays until Retry works or dismiss.
- Pickup fallback buttons in the status ⋯; sent toast stays 5 s.
- Screenshot of each state (light and dark for failed).

## 11. Cases without a mockup
From: C12 "Every function in Appendix A of the spec keeps a place."
- Screenshots of: text only, reply only, pick several, review, offline, sent, delivered, failed, done, update with options, stepped ask.
- Each matches spec section 9.

## 12. Function check
From: C12 "Every function in Appendix A of the spec keeps a place. No function is lost."
- Go row by row through Appendix A and FUNCTIONS.md in the running app; mark each row found with its new place.
- The list goes in `design/mockups/2026-11-09-request-page/FUNCTIONS-CHECK.md`; any missing row is fixed before the work is done.
