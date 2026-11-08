# Do we dispatch the friend-usage tasks to the fleet now?

Decided: 2026-10-27 · Case: c_5053a6a8-a3c1-43a0-9d0a-1bb4cf34b9d8 (follows c_dfc32820-9435-4c69-943e-0f63619530fb)

## Question and choice
Do we dispatch the 5 tasks of `2026-10-27-friend-usage-fixes.md` now, and in which batch? The operator chose
"Dispatch all five now: T1 to T3 as builds, T4 and T5 as design rounds in Waggle."

## Why
The operator wants all the work to move today. T1 to T3 touch different files and can run in parallel.

## Constraints
- T3 sends a prototype for review before the SwiftUI build.
- T4 and T5 send design rounds in Waggle. They build nothing before the operator picks.
- Each worker runs in its own worktree. No merge, no push.

## Ruled out
- T1, T2, T3 now and the design rounds later: the operator did not want to wait for T3's review.
- T1 only: too slow.
- Not now: the operator wants the work to start.

## Comments
none

## Open questions
- Up to 3 design reviews may arrive at the same time (T3, T4, T5).

## Sources
- Case c_5053a6a8-a3c1-43a0-9d0a-1bb4cf34b9d8
- `docs/decisions/2026-10-27-friend-usage-fixes.md`

## Tasks
The tasks are T1 to T5 in `docs/decisions/2026-10-27-friend-usage-fixes.md`, with the same acceptance criteria.
From: Question and choice, line 1: "Dispatch all five now".
