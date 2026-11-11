# Spec: a simpler request page

Date: 2026-11-09 · Follows the record `docs/decisions/2026-11-09-request-page-rules.md`

Goal: the request page shows less at once, and all of today's functions stay. Each section below is one item to approve or change. Appendix A puts every function of today's page in its new place.

## 1. One layout: the decision column on the right

- The decision is always in a right column, 440 pt wide, in the pane and in full size.
- With an artifact: the artifact fills the left, the column is on the right.
- With no artifact: the column is the page, centred, 640 pt at most for reading.
- Narrow pane (artifact area under 480 pt): the artifact folds to today's pinned bar (Open, choose artifact) at the top of the column. This is the only other form.
- The options show once, in the column. The options dock and the option cards in the page go away as two copies; one list stays.
- The column scrolls as one piece. The answer box and the send row are pinned at its bottom, so Send is always on screen.

## 2. Header: two lines at most

- **Line 1, top bar:** project crumb / title · arrived · waiting. On the right: Share, Conversation icon (⌘]), fold both sides (⌘\), ⋯ (Dismiss). The project crumb, the folder tooltip and the times stay as today.
- **Line 2, context line**, only when there is context. It holds, on one line, from left to right:
  - "↳ Follow-up to X" (click opens the first ask), or "Replaces X";
  - for a plan, the stage track as words: Questions · Approaches · **Design** · Spec (current stage bold, done stages with ✓, tooltip and "See revision" menu as today);
  - the status, when the agent session is closed or the reply is sent (see section 8).
- The "APPROACHES" label, the second crumb ("Waggle / … · Claude Code · Decision 3 of 3 · 2 earlier requests") and the group label go away. "Earlier requests ▾" moves into the Conversation tab.
- **Several questions (stepped asks):** the step bar sits at the top of the Decision tab, numbers only (1 · 2 · 3 · Send), with tooltips that give the full title. The question title under it is the step's title, so the title shows once.
- The previous answer folds to one line: "You chose B · Show". Show opens it in place; the full text is also in the Conversation tab.

Result on a plan follow-up: 3 header lines (follow-up, stage track, step bar) become 1 context line plus the step numbers.

## 3. Decision tab

From top to bottom:
1. Step numbers (stepped asks only).
2. Question (the focal point).
3. Need box. The "WHAT I NEED FROM YOU" label goes away. "Why you" moves into the box as its last line, in grey. The agent's text is not cut, and the table fix stays.
4. Update line, when an update brings options: "↻ Options from the update · First options" (the old options stay folded, and open in their own fold, not in the same capped scroll).
5. Options, one list. Each row keeps:
   - the label, the ✦ Recommended pill, the "Your answer" tag;
   - the pro, con and effect counts (icon + number, always visible);
   - the hover popover with the full pros and cons, as today, also on keyboard focus;
   - Lean ◐ and Rule out ×, always visible. Only when the row is too narrow and one line high for them, they show on row hover and focus. A row that is leaned to or ruled out always shows its mark.
   - Pick by click or keys 1–9, ⌘D for the recommendation, as today.
   - Pick several: the "Pick up to N · x of N", Tick the recommended and Clear header stays above the rows.
6. "Ask for…" button (one button, at the left of the send row). It opens today's panel: quick replies (Let's discuss, Look at my comments, Show me more), the ask pills (how it works, trade-offs, prototype…), Something else, keys 1–N, ? key, Esc back, ⌘↵ Ask.
7. Sources button and pills, as today, under the need box.
8. Answer box and send row (section 4).

## 4. Answer box: never hide a word

The box is the weak point today (the height is estimated, quiet buttons are cut, more than 6 lines scroll with no sign). After:
- The height comes from the real text view layout (`NSTextView` layout manager of the field itself, after each change and on width change), not from a second estimate.
- The text wraps at the field width. The field grows with the text up to 40 % of the column height, at least 6 lines. Past that it scrolls, and the scroller is always visible while there is hidden text.
- At rest the field shares the row with the buttons, as today. When the text needs more width than that row gives, the field moves to its own full row above the buttons, so the buttons never take width from the text. Check this in the running app before the task is done.
- Buttons in one row under the field: + (attach), Ask for…, quiet buttons (Ask for more detail, Open review, Change / Request changes, More), then Send. When the row is too narrow, quiet buttons move into "More", one by one; they are never cut with "…".
- All Send labels stay as today: Decide, "Decide: X", Decide with changes / Approve with changes (+N comments), Decide: N picked, Ask, Keep talking, Lean to 1, keep talking, Rule out 3…, Send feedback, Send comments, + edit; ↵ / ⌘↵, ⇧↵ new line.
- Text the app puts in ("Use this reply") keeps the caret at the end.
- The placeholder wraps; it is never cut with "…".
- "Something else" in the Ask for… panel uses the same field.
- Attachments: chips under the field, ×, right-click open and Finder, drop on the pane, paste. Drafts per case stay.

## 5. Conversation tab

Pattern reference: AI Elements (Message, Reasoning, Tool, Inline citation), built in SwiftUI.
- Tabs at the top of the column: Decision · Conversation · Comments (count). A dot on Conversation when there is a new agent message.
- Above the tabs, one line with the latest agent message, no left border. Click opens the Conversation tab.
- Each entry is a message: who (agent or you), time, text. Your answers are on the right, agent messages on the left, no bubble border.
- Actions under each message on hover: Copy, and "See vN" for a revision.
- Long agent text folds after 6 lines, with "Show more".
- The agent's working notes and tool steps show as one folded line ("Worked: 3 steps") that opens.
- Earlier requests: a list at the top of the tab ("2 earlier requests ▾", Open the history ›).
- ⌘] and the top bar icon open this tab. The 380 pt overlay column goes away.

## 6. Comments tab

Today's Comments column tab, in the pane too: comment cards (Show, Edit, Delete, inline Save), "N comments on vN · view vN", late team comments, unread dot. The comments section under the artifact box goes into this tab.

## 7. Full size

- The same column with the same three tabs: 440 pt, and it gets narrower (down to 340 pt) when the artifact area would drop under 60 % of the window. The artifact width is checked on a 13" window (1440 × 900) and on full screen.
- One / Set and Compare (Side by side / Slider) become segmented switches in the toolbar.
- Everything else stays: I, C, E, Esc, ↵, Fit ⌘0, 100% ⌘1, zoom, Reload ⌘R, Compare with vN, version chips, Offline and Sandboxed badges, ⌘[ ⌘] ⌘\.

## 8. Status: one line, not banners

Status goes in the context line (section 2). A button shows only when there is something to do.

| State | Today | After |
|---|---|---|
| Sending, sent, waiting | footer + toast | "Sent · waiting for the agent" · Change answer · Go back (toast stays for 5 s) |
| Delivered | green banner | "Delivered ✓" · Copy the reply · View review |
| Delivery failed, refused | banner | "Not delivered" · Retry: red icon and text with the reason, high contrast, stays until Retry works or you dismiss it |
| Offline | dimmed, no composer | "Offline" in the line; page dimmed as today, no answer box |
| Session closed | full-width notice | "Session closed" · Continue in a new session |
| Pickup fallback | buttons | Copy prompt · Nudge · Show the terminal, in the ⋯ of the status line |
| Done | green strip + Got it | "Done" · Got it; no answer box |
| Agent status / follow-up | strip | "Agent working" · Open the follow-up |

## 9. Cases without a mockup

| Case | After |
|---|---|
| Text only, pick one | Column is the page: question, need box, options, answer box |
| Reply only | No options; the answer box sits under the need box; "Use this reply" in the send row when the field is empty |
| Pick several | Section 3, item 5; Send shows "Decide: N picked"; Return sends |
| Review | Options Approve / Request changes as two rows; the hint "Pick Approve or Request changes…" stays when nothing is picked; "Open review" in the send row |
| Offline, sent, done | Section 8 |
| Update with options | Section 3, item 4 |

## 10. Sidebar

- The sidebar can still be folded: the fold button, ⌘[, and the "N Needs you" rail stay.
- **New:** Working gets a fold header like Answered: "› WORKING · N". Closed by default; the choice is saved.
- All other sidebar functions stay as they are (Appendix A).

## Appendix A: every function, today and after

"Same" means no change in place or look.

| Function (FUNCTIONS.md) | After |
|---|---|
| Hide / show the queue, ⌘[, rail | Same |
| ↑ ↓ j k ↵ ⌘⌫ in the list | Same |
| Open from Working / In planning | Same; Working folds (sec. 10) |
| Answered fold, Decided for you, Change my mind | Same |
| Got it, Dismiss, Retry, unread dot, tooltips, undo toast | Same |
| Sessions popover, Settings ⌘, | Same |
| Go home, Esc | Same |
| Project crumb, folder tooltip, times | Top bar (sec. 2) |
| Share, view comments | Top bar |
| Dismiss with confirm | ⋯ in top bar |
| Conversation column, ⌘] | Conversation tab (sec. 5) |
| Fold both sides ⌘\ | Same |
| Earlier requests ▾, Open the history | Conversation tab |
| Follow-up header, Replaces | Context line (sec. 2) |
| Artifact tabs, version line | Same |
| Show changes, ⌃ ⌄ | Same |
| Open full size, new window, browser | Same |
| Interact / Comment, C, Esc | Same |
| Screen set ← →, thumbnails | Same |
| Comments under the box | Comments tab (sec. 6) |
| Pinned bar on a narrow page | Same, top of the column (sec. 1) |
| Artifact follows the picked option | Same |
| Comment / Explain on selection, image menu | Same |
| Full-size keys, zoom, Reload, versions, badges | Same (sec. 7) |
| One / Set, Compare | Segmented switches (sec. 7) |
| Comment cards, "N comments on vN" | Comments tab |
| Pick by click, keys 1–9, ⌘D | Same (sec. 3) |
| Lean ◐ / Rule out × | Always visible; on hover only on a narrow one-line row |
| Pro / con / effect counts, row popover | Same, always visible |
| ✦ Recommended, Your answer | Same |
| Pick several header | Same |
| Options from the update, First options | One line; own fold |
| Review hint | Same |
| Earlier round / decision fold | "You chose X · Show" (sec. 2) |
| Sources | Same |
| All Send labels, ↵ ⌘↵ ⇧↵ | Same (sec. 4) |
| Attach, chips, open, Finder, drop, paste | Same |
| Quiet buttons, More | Same; overflow into More, never cut |
| Remove an in-place edit | Same, under the field |
| Use this reply | Send row |
| Drafts per case | Same |
| Change answer, Open / View review | Status line (sec. 8) |
| Quick replies, ask pills, panel, ? key | "Ask for…" button (sec. 3) |
| Conversation copy, See vN | Conversation tab message actions |
| Done strip, agent strip, delivered, failed, offline, session closed, pickup fallback, sent toast, late comments | Status line (sec. 8); late comments in Comments tab |
| Step pills, Back, Next, Review and send, "Send your N decisions?" | Step numbers (sec. 2); buttons same |
| Plan track dots, See revision | Context line (sec. 2) |

## Appendix B: provenance

- Case c_b8e9f302-bf2b-4b7c-8fd3-2bed78463cd3 (direction, rules, design check).
- Decision records: `docs/decisions/2026-11-09-request-page-direction.md`, `docs/decisions/2026-11-09-request-page-rules.md`, `docs/decisions/2026-11-09-request-page-ui-cleanup.md`.
- Inventory: `design/mockups/2026-11-09-request-page/FUNCTIONS.md`; text cut: `TEXT-PIECES.md`; cases: `CASES.md`.
- Before/after canvas: `design/mockups/2026-11-09-request-page-cases/index.html`. Variants: `plan` (plan follow-up, Approaches round), `shots` (screenshot set), `multi` (several questions), `conv` (conversation tab), `full` (full size).
- Answer box weak points: FUNCTIONS.md, last section (PromptBarLogic.swift:45-64, 100-131; PromptBarView.swift:24-26, 531-532).
- Pattern reference: https://ui.shadcn.com/docs/ai-elements
