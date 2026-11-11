# Request page: tasks before the draft PR

From the decision record `docs/decisions/2026-11-10-request-page-draft-pr.md`.

## 1. The need box shows a list as details, not as part of the question
Criteria:
- `NeedText.split` stops the question at the first list line of the first paragraph; the list and what follows are details.
- A need that opens with a list still has no question (no change).
- A unit test covers "one sentence\n- item\n- item".
- In Waggle Dev, case c_0d5db705 round 2 shows only "Waggle Dev runs now…" in bold; the list is regular ink2.
From: Comments, line 2: "the need box shows the first paragraph and the list under it as one bold 17 pt block."

## 2. Fix the Conversation tab
Record: `docs/decisions/2026-11-10-conversation-tab-fixes.md`.
- 2a. Messages show in full. Criteria: no fold, no "Show more" or "Show less" in the tab. From: Constraints, line 1.
- 2b. No actions row. Criteria: no Copy and no "See vN" under a message; the gap between two messages is the stack spacing only. From: Constraints, line 2.
- 2c. Question line in bold. Criteria: the first paragraph of each agent message (before a list or a blank line, as `NeedText.split`) is semibold ink; the rest is regular. From: Question and choice: "Question line in bold".
- 2d. No conversation icon in the top bar. Criteria: the bubble icon with the round count is gone; ⌘] still toggles Decision and Conversation. From: Comments, line 3.
- 2e. No "Open the history". Criteria: the link is gone from the tab; "N earlier requests" stays. From: Comments, line 4.
- Checked in Waggle Dev with a screenshot of the Conversation tab.

## 3. Open the draft PR
Criteria:
- One commit on `request-page-simplify`, without dist/, scratchpad files, screenshots or binaries.
- Pushed as 0xCaso; draft PR to main.
- The body lists the changes, the function check (89 rows, 0 missing), the proof screenshots (attached) and the line "Testing in Waggle Dev before merge".
- The PR is linked in T3.
From: Question and choice: "commit, push the branch and open a draft PR to main. The body says that you test it in Waggle Dev before the merge."

## 4. Push through a fork
Record: `docs/decisions/2026-11-10-draft-pr-from-fork.md`.
Criteria:
- 0xCaso/waggle exists as a fork of waggle-so/waggle.
- `request-page-simplify` is pushed to the fork; the draft PR goes from 0xCaso:request-page-simplify to waggle-so/waggle main.
From: Question and choice: "Fork waggle-so/waggle to 0xCaso/waggle, push the branch there and open the draft PR from the fork."

## 5. Remove private data from the PR
Record: `docs/decisions/2026-11-10-pr-private-data-and-proof.md`.
Criteria:
- The two mockup `index.html` files use sample requests only; a grep for the client, person and project names of the old mockups (list kept outside the repo) returns nothing in the PR files.
- No `/Users/` path in the PR files.
- The commit author is `0xCaso <22419450+0xCaso@users.noreply.github.com>`.
- The fork branch is force-pushed (with lease); PR #1 shows one clean commit.
From: Question and choice: "Replace the real requests in the mockups with sample requests, remove the path and the line that names a client project, set the author to the 0xCaso noreply address, and force-push the same branch."

## 6. Screenshots and video with sample data
Record: `docs/decisions/2026-11-10-pr-private-data-and-proof.md`.
Criteria:
- Before (main) and after screenshots from `RequestPageRenderTests` for: request with artifact, options, long answer, Conversation tab, need box with a list, full size.
- One short video of Waggle Dev in a test copy with sample requests only.
- The files are in the scratchpad, not in git; a comment text lists them in order for the operator to drag into PR #1.
- Blocked until the disk has about 2–3 GB free (estimate).
From: Question and choice: "both with sample data only. I give you the files and the comment text; you drag the files into a PR comment in the browser."

## 7. English only, and a removal request for the old commit
Record: `docs/decisions/2026-11-10-keep-pr-1.md`.
Criteria:
- No Italian text in the PR files; the operator's quotes are translated.
- The commit is amended and force-pushed to the fork; PR #1 shows one commit.
- A ready-to-send GitHub removal request for commit a66c2e1 and PR #1's reference to it, outside the repo.
From: Question and choice: "I translate all Italian text in the PR to English and amend. I write the text for a GitHub private-data removal request for commit a66c2e1. You send it."

## 8. Four before/after images for PR #1
Record: `docs/decisions/2026-11-10-pr-before-after-images.md`.
Criteria:
- A worktree of main (outside the repo folder) renders the same sample requests as `RequestPageRenderTests` at the same sizes (port the test file; adapt only what main's API needs).
- Four PNGs, each main left and this branch right with a "Before" / "After" label: (1) options shown once (text-only or artifact request), (2) Conversation tab vs the old conversation column, (3) context line vs banners (plan follow-up), (4) answer box with long text.
- Sample data only, checked by opening each PNG.
- The files and a short comment text (4 captions) are in the scratchpad; the 10 after-only files are dropped.
From: Question and choice: "Each image shows main on the left and this branch on the right, with the same sample request: options shown once, Conversation tab, one context line, answer box with long text."

## 9. Delivery status lines
Criteria:
- "Saved · delivers when the agent's session resumes" uses the red failed style (icon, soft red fill).
- A failed reply whose session is live again shows "Saved · the agent gets it at its next check", not red, with Retry.
- The page's own send that fails now stays "Not delivered" in red.
From: the operator, 10 Nov: "I would show the message above better, maybe with a red background like screenshot 2"; "I don't know if the behaviour is correct".

## 10. Match the decision column to the mockups
Record: `docs/decisions/2026-11-10-match-request-page-to-mockups.md`.
- 10a. Style audit. Criteria: `design/mockups/2026-11-09-request-page/STYLE-AUDIT.md` lists each element of the column (tabs, context line, title, need box, table, options label, option card closed and open, radio and box, Recommended tag, key, Lean and Rule out, answer box, tools row, Send button, status) with the mockup CSS value and the Swift value for font, weight, size, line height, color, border, radius, padding and gap; each row says "same" or "change". From: Constraints, line 1.
- 10b. Option cards. Criteria: radio (box for many), title 13.5 semibold, tag, key; picked card open with description, 2-column pros and cons, dashed line, why; the others with first pro, first con, "+N more"; ◐ and × next to the key, always visible. From: Constraints, lines 2–3.
- 10c. Need box and tables. Criteria: honey box 13 pt, bold lead 13.5 semibold, "Why you" 12 pt ink3 over a line; tables with grey header, borders, right-aligned numbers. From: Constraints, line 5.
- 10d. Answer box. Criteria: field on its own row; under it Let's discuss · Show me more · Ask for… (12 pt ink3) on the left and "Send: <option> ↵" (12.5 semibold, ink fill) on the right. From: Constraints, line 4.
- 10e. All other "change" rows of the audit applied (tabs, title 19 pt, context line, labels).
- 10f. Proof. Criteria: side-by-side renders, mockup and app at the same size, for the case map cases (screenshots, plan follow-up, multi-select, full size) and B; no "change" row left; all tests pass; FUNCTIONS-CHECK still 0 missing. From: Constraints, lines 6–7.

## 11. Option card "Gist and facts"
Record: `docs/decisions/2026-11-10-option-card-gist-and-facts.md`.
- 11a. Protocol. Criteria: `waggle_ask` and `waggle_update` options (top level and items) accept optional `facts` (0–3 strings, ≤ 24 chars each) and pros/cons entries as a string or `{ gist, detail }` (gist ≤ 40 chars); the daemon stores and returns them; old asks unchanged; zod schema, store, protocol docs and daemon tests updated; the `asks` guide shows one example. From: Constraints, line 6.
- 11b. App card. Criteria: the card matches variant `gist` of `design/mockups/2026-11-10-option-text/` (round 2): ≤ 3 neutral fact chips under the title; gists in two plain columns with quiet PROS / CONS labels and hanging + / –; closed cards show the chips and "+N −N"; "Show the full points" opens every full point, effect, description and reason; a point with no gist shows in full with a hanging indent. From: Constraints, lines 1–3.
- 11c. Need. Criteria: "Why you" one plain line, full text on click; paths and code in mono chips; numbers bold and tabular. From: Constraints, lines 4–5.
- 11d. Proof. Criteria: side-by-side render, mockup `gist` and app at 440 pt, for a new ask with facts and gists and an old ask without; all daemon and app tests pass; Waggle Dev rebuilt; FUNCTIONS-CHECK still 0 missing.

## 12. Sidebar, top bar and pane header as in the mockups
Record: `docs/decisions/2026-11-10-mockup-style-in-the-whole-app.md`.
- 12a. Audit and build. Criteria: STYLE-AUDIT.md has a section for the sidebar, top bar, pane header and artifact pane, with each value from the mockup CSS against the Swift value; every "change" row is applied; the app functions the mockup lacks (WORKING fold, Settled, file icons, search) stay, styled from the nearest mockup element. From: Constraints, line 1.
- 12b. Proof. Criteria: whole-window renders next to the mockup B and case-map shots at the same size; all tests pass; FUNCTIONS-CHECK still 0 missing. From: Constraints, lines 1 and 6.

## 13. Pane borders move by drag
Record: `docs/decisions/2026-11-10-mockup-style-in-the-whole-app.md`.
- 13a. Criteria: the border between the sidebar and the artifact and the border between the artifact and the decision column move by drag, with the resize pointer; the widths stay after a restart; a double click sets the default width again; the decision column stays between 360 and 640 pt; the sidebar and the artifact keep their own minimum widths; tests for the clamp and the saved widths. From: Constraints, lines 4–5.

## 14. Mockups for the screens no mockup draws (next step, not in PR #1)
Record: `docs/decisions/2026-11-10-mockup-style-in-the-whole-app.md`.
Status: moved out of PR #1 on 2026-11-10 (the operator: the redesign of the whole app is too large for it). The first canvas is in `design/mockups/2026-11-10-other-screens/` (not sent for a pick yet).
- 14a. Criteria: one canvas in `design/mockups/` with Home, Settings, Onboarding, New idea, Plan, Usage and the menu bar in the style of mockup B; each keeps its controls and flows (a list per screen, checked against the code); sample data only; sent in Waggle for a pick. From: Constraints, lines 2–3.
- 14b. Build the picked direction. Criteria: each screen matches its picked mockup side by side; no function lost; all tests pass. From: Constraints, lines 2–3 and 6.
