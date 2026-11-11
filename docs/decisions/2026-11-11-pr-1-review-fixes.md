# How should I give 0xCaso the PR #1 review?

Decided: 2026-11-11 · Case: c_b169eb1a-16b7-46a8-954c-b3d57c95eaf5

## Question and choice
PR #1 (request-page-simplify) is 0xCaso's draft, and they use it every day. How should the review get to them?

The human chose "Comments plus a fix PR": "Post the review, and open a small PR into their branch that fixes the
clear items: the two fixed sleeps, Copy and See vN restored, the unused working field. The design calls stay as
comments."

## Why
- The clear fixes are ready to merge, and 0xCaso can review the fix PR and take or drop it.
- The design calls (tables in agent text, row layout, Delivered copy) stay with 0xCaso and the maintainer.

## Constraints
- The fix PR targets 0xCaso's branch `request-page-simplify` on the fork 0xCaso/waggle. Nothing is pushed to their branch.
- The fix PR changes only the three clear items. Each design call is a review comment.
- Tests poll with a deadline (AGENTS.md). No fixed sleep stays in the changed tests.
- A protocol change updates `docs/protocol-mvp.md` in the same change (AGENTS.md).

## Ruled out
- "Review comments only": the agent recommended it, because it is their draft in daily use. The human preferred to give the clear fixes ready to merge.
- "Push fixes to their branch": it changes their working build without asking, and makes design calls without them.

## Comments
none

## Open questions
- "The unused working field": the review said the app decodes `Message.working` and the daemon never sends it.
  The fix PR found that the app does read it (ThreadModel.swift, "Worked: N steps" fold) and the daemon stores it
  (`messages.working`, migration 46). Removing it would break the fold for older notes. So the fix PR makes the
  daemon send `working: true` on each progress note (additive, documented), and does not remove it. This is the
  fix PR's choice. 0xCaso or the maintainer can reverse it.

## Sources
- Case c_b169eb1a-16b7-46a8-954c-b3d57c95eaf5 (the choice).
- PR #1 review findings: AGENTS.md:57, SECURITY.md:27, docs/protocol-mvp.md, docs/specs/2026-11-09-request-page-spec.md §2, §3.5, §4, §5, §8.
- apps/macos/Tests/KnockTests/SendFlowControllerTests.swift, PromptBarFieldSizingTests.swift (the two sleeps).
- apps/macos/Sources/Knock/Queue/ConversationTab.swift; main's ConversationColumnView.swift:79-112 (Copy and See vN).
- apps/macos/Sources/Knock/Protocol/Nouns.swift:549, Queue/ThreadModel.swift:136, daemon/src/store.ts (`working`).

## Tasks
1. Replace the two fixed sleeps with deadline polls. Criteria: no `Task.sleep` before an assert in SendFlowControllerTests or PromptBarFieldSizingTests; the tests pass 3 runs in a row. From: Question and choice, "the two fixed sleeps".
2. Restore Copy and "v1 · see in review" on conversation messages. Criteria: each message has Copy on hover; an update on the latest version shows the link when the case has an artifact; the link opens the review on the prior version; `ConversationCopy.priorVersionLink` has a test. From: Question and choice, "Copy and See vN restored".
3. Settle `Message.working`. Criteria: the daemon sends `working: true` on progress notes only; other messages keep their shape; protocol doc updated; a daemon test covers it. From: Open questions, line 1.
4. Post one GitHub review on PR #1 with every finding, the design calls as comments. Criteria: one review, each finding with file:line. From: Question and choice, "The design calls stay as comments".
