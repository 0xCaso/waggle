# What does the window show when you are caught up?

Decided: 2026-11-11 · Case: c_eb520608-48b2-451e-bdd3-93fdfdb7b17d · Follows: c_e43cfdf2-cf27-45fe-b981-b8f18701ce7d

## Question and choice
What does the main window show when the inbox is empty and Getting started is complete?

The human chose "Quiet: all caught up": "The pane says "All caught up", with the number of requests answered
today and the number of agents at work. One quiet line tells how to start a request. Getting started and the
example cards are gone from the list column."

## Why
- The human asked for this state: "what about the empty stage though if i already completed the steps?"
- Agent's reason: an empty inbox is a done state, and the quiet window says only that.

## Constraints
- The list column keeps its Working and Answered today sections. It shows no Getting started card and no example cards.
- The three-step explainer shows only before the first answer.
- UI copy uses plain words and no em-dashes (AGENTS.md).

## Ruled out
- "Caught up, with a way to start": three prompts with Copy in the pane. The empty window is busier, and the
  same prompts will be in Help after the Settings clean-up.

## Comments
none

## Open questions
- none

## Sources
- Case c_eb520608-48b2-451e-bdd3-93fdfdb7b17d (the choice).
- OpenPencil page "Empty state, caught up": two boards.
- Home/HomeView.swift:54 (today's headline) · AppModel.swift:221 `caughtUpStats`, read by no view · Queue/QueueEmptyState.swift:13-20

## Tasks
1. Build the caught-up pane in the First run batch (task 3 of 2026-11-11-ui-audit-batches.md). Criteria: with an
   empty inbox and at least one answer in the past, the pane shows "All caught up", "Nothing needs you right
   now.", the count answered today and the count of agents at work, and one line on how to start a request;
   the count chips hide at zero; the explainer shows only before the first answer; a test covers the rule
   that picks explainer or caught up. From: Question and choice.
2. Hide Getting started and the example cards when all steps are complete. Criteria: the list column shows
   neither; a test covers the rule. From: Constraints, line 1.
