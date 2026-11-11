# Which UI audit fixes should I build first?

Decided: 2026-11-11 · Case: c_e43cfdf2-cf27-45fe-b981-b8f18701ce7d

## Question and choice
A full UI audit of the app (first run, main window, request page, Settings) gave about 135 findings in seven
batches. Which batches should be built?

The human chose all seven: "Fix what looks broken", "Buttons and feel", "First run", "Offline said once",
"Settings clean-up", "Request page polish", "Remove unreachable UI".

## Why
- The human asked for "a full UI audit of the app" to streamline flows and clean up interfaces "from onboarding
  to main screen, settings".
- The human set the direction: "for clean up and ui elevation i mean something like caso did in pull/1 that we
  just merged". Each thing is shown once, with fewer blocks and a calmer hierarchy.
- The human saw the seven before and after pairs at real size before the choice ("show me high quality design
  in open pencil first though").
- Agent's reason: the batches do not depend on each other, so each can be one pull request.

## Constraints
- One pull request for each batch, on waggle-so/waggle. No push and no merge until the human asks.
- Each setting keeps its meaning and its stored value. Only its place changes.
- UI copy uses plain words and no em-dashes (AGENTS.md).
- Tests that wait poll with a deadline (AGENTS.md).
- No feature becomes required: setup steps stay optional, and Skip for now always works.
- Motion: ease-out, under 300 ms, press scale 0.97, and each moving animation respects Reduce Motion.
- The proposed screens are the agent's design calls. The human can change a screen in review of its pull request.

## Ruled out
- none. The human chose every batch.

## Comments
- On pair 2, "The first window explains Waggle instead of showing it", the human wrote: "what about the empty
  stage though if i already completed the steps?" The proposal did not draw this state. It is now an open
  question, and task 3 draws it and asks before the First run batch is built.

## Open questions
- What does the main window show when the inbox is empty and Getting started is complete? Not drawn yet.
- Keyboard focus after the first answer (j, k, Return): the audit did not confirm it in the running app.
- The human's screenshot (2026-11-11): the blue strip "Options from the update" has no space before the
  "YOUR CHOICE" label. It is part of task 1.

## Sources
- Case c_e43cfdf2-cf27-45fe-b981-b8f18701ce7d (the choice and the comment).
- The audit, read from main at c3e60bd: about 135 findings in five reports (first run, main window, request
  page, Settings, app-wide tokens and motion).
- OpenPencil page "Hi-fi before and after": 14 boards, seven pairs.
- Queue/QueueListView.swift:62-67,141-154 · Queue/CasePaneView.swift:1231-1258 · Views/MainWindowView.swift:112-116
- Queue/SentToastView.swift:30-134 · Composer/ComposerCardView.swift:321-338 · Review/ReviewWorkspaceView.swift:493
- Onboarding/OnboardingConnectView.swift:9-26 · Onboarding/OnboardingComponents.swift:175-290 · Onboarding/OnboardingModel.swift:237
- Settings/AgentsSettingsView.swift:124-286 · Settings/SettingsPage.swift:8-20 · Review/ArtifactViewerView.swift:74-90,547-632

## Tasks
1. Fix what looks broken. Criteria: "View log" opens the log; a saved request shows its real chips, not a
   hard-coded "Review" and "Blocking"; a failed connect shows its error; the full-window review shows the same
   answered view as the case pane after Decide; the Sent toast sits in the list column above the footer and
   covers no control, exit 150 ms ease-out; 8 to 12 pt of space between the blue options strip and "YOUR
   CHOICE"; focus after the first answer is checked in the app and fixed if it fails. From: Question and
   choice, "Fix what looks broken".
2. Buttons and feel. Criteria: one shared press style (scale 0.97, about 120 ms) replaces the four copies;
   queue rows and the Decision, Conversation and Comments tabs are buttons with hover, pointer cursor and
   keyboard focus; each animation that moves checks Reduce Motion; the reply field does not animate on each
   keystroke; comment delete has an undo; "Waiting for your message" pulses. From: Question and choice,
   "Buttons and feel".
3. First run. Criteria: first, draw the empty state for a completed Getting started and ask the human; then
   each agent row in setup has one action; Check again and Skip for now exist; the step is named once; the
   first window shows one sample request that the human can answer; Getting started has three lines and hides
   when complete. From: Comments, line 1, and Question and choice, "First run".
4. Offline said once. Criteria: one "Waggle is paused" card with one working button; no "daemon", "cached" or
   tool name in the UI; the footer says "Paused"; a saved request shows its normal page with Decide off and
   the reason. From: Question and choice, "Offline said once".
5. Settings clean-up. Criteria: the Agents page is one list of agents and one "Asking in Waggle" card, and
   fits 600 pt; nine pages (Ask less inside Requests, Previews inside Artifacts); each stored value is
   unchanged, with a test; Phone setup loses its two gate clicks. From: Question and choice, "Settings
   clean-up", and Constraints, line 2.
6. Request page polish. Criteria: the artifact header shows the artifact's name once and the version once,
   with no banner; an older version keeps the tab strip; the send row keeps Send and "Ask for…" only where
   the quick replies are duplicates. From: Question and choice, "Request page polish".
7. Remove unreachable UI. Criteria: the idea box, the start-session menu and the review-before-send column are
   removed with their tests; no branch name shows as a label; no em-dash in UI copy; the app builds and the
   suites pass. From: Question and choice, "Remove unreachable UI".
