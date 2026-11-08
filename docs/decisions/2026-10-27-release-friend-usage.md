# Release the friend-usage work as 0.2.63?

Decided: 2026-10-27 · Operator message in the session: "then merge, and release ofc"

## Question and choice
WAG-409 to WAG-413 came from a friend's usage export. After the builds of WAG-412 and WAG-413, merge them into main and
release. The operator chose: merge, then release. 0.2.62 was already out, so this release is 0.2.63.

## Why
The friend's export showed that replies failed because the agent session ended, error labels were wrong, chips
were hidden, many asks were low stakes, and visual review lacked a compare. All five fixes are built, folded and tested.

## Constraints
- Ask less (WAG-412) and Compare (WAG-413) are off by default. With them off, the app works as in 0.2.62.
- Migrations: 53 tool_calls.error_code, 54 replies handed_over, 55 quick_reply_picked, 56 Ask less columns and
  ask_auto_decided, 57 compare_toggled and the on/off variants. 57 rebuilds usage with every column of 56.
- Main is not pushed.

## Ruled out
- Merge only: the operator asked for the release.

## Comments
none

## Open questions
- Ask less was not run end to end in a real Claude Code session; tests and window captures only.
- Compare slider drag and pinch on both sides are covered by unit tests only.

## Sources
- Records: 2026-10-27-friend-usage-fixes.md, 2026-10-27-friend-usage-dispatch.md,
  2026-10-27-quick-reply-chips-and-handed-over.md, 2026-10-27-friend-usage-merge-then-build.md,
  2026-10-27-fewer-low-stakes-asks.md
- Merge commits on main: 7bc1d85f, 59cf7b81, 1dfd7f24, a408c5d7, 37cc22a1
