# What do we do next with the friend-usage work?

Decided: 2026-10-27 · Case: c_2e4f1090-842a-4118-9173-7a8c1b983b86 (follows c_37e44ba5-77dd-46f2-8e10-699799aeff01)

## Question and choice
All 5 friend-usage tasks were done and folded. The operator chose "Merge, then build": merge WAG-409, WAG-410
and WAG-411 into main in that order, with the migrations renumbered 53, 54, 55, and run the full suites. Then
dispatch the builds of WAG-412 (Let the agent decide rule) and WAG-413 (Compare switch) from the new main.

## Why
The builds touch the same composer and usage code. Starting them from the merged main avoids a second round of
migration conflicts.

## Constraints
- Migrations: 53 = tool_calls.error_code (WAG-409), 54 = replies handed_over (WAG-410), 55 = usage
  quick_reply_picked (WAG-411).
- No push.

## Ruled out
- Merge only: the builds would wait for no reason.
- Build only: the builds would start from a main without the three merges and conflict again.
- Wait: the branches were already folded and tested.

## Comments
none

## Open questions
none

## Sources
- Case c_2e4f1090-842a-4118-9173-7a8c1b983b86
- Merge commits on main: 7bc1d85f, 59cf7b81, 1dfd7f24

## Tasks
- Build WAG-412 from `docs/stories/WAG-412.md` on story/WAG-412 (rebased on the new main). From: Question and choice.
- Build WAG-413 from `docs/stories/WAG-413.md` on story/WAG-413 (rebased on the new main). From: Question and choice.
