# Release the "Show changes" switch for write-ups?

Decided: 2026-10-26 · Case: c_b26f7066-c2d2-491d-b9af-52e0756a9ca2

## Question and choice
WAG-408 adds a "Show changes" switch to a write-up with an older version. Merge it and release 0.2.61?
The operator chose: "Merge WAG-408 into main and release 0.2.61 now. Do not push main."

## Why
The operator asked for it on a write-up diff: "i want to be able to enable / disable the view of changes, so i can either see latest version or the diff basically".
The default is the same as before, so nothing changes until the switch is used. The old-record risk is fixed and tested.

## Constraints
- Default on: a new version opens with the changes and scrolls to the first change the first time.
- Off shows the plain latest version, with comments and selection working.
- The choice is kept per case, artifact, surface and version. A new version starts on.
- An old `dismissed` mark means "scrolled once", never "off". The switch uses the `hidden` field.
- Main is not pushed.

## Ruled out
- Let me look first: the operator did not ask for a look before release.
- Merge only: the operator wanted the switch now.

## Comments
none

## Open questions
- Nobody has looked at the header at a narrow width in the running app.

## Sources
- Case c_b26f7066-c2d2-491d-b9af-52e0756a9ca2
- Code: apps/macos/Sources/Knock/Review/WriteUpChanges.swift, apps/macos/Sources/Knock/Review/WriteUpInlineView.swift
