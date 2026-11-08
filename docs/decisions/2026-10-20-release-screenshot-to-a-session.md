# Release "send a screenshot to a session" now, or after a live test?

Decided: 2026-10-20 · Case: c_898a1e68-3188-4f49-8818-b99d05eb97c6

## Question and choice
Release WAG-402 as 0.2.55 now, test it first on the operator's Mac, or only push main?
The operator chose "Release 0.2.55 now": push main and release 0.2.55. The operator tests on the released build. A fix goes into 0.2.56.

## Why
The operator gave no note. The feature is off by default, so a user sees nothing until they turn it on in Settings › Screenshots.

## Constraints
- Release 0.2.55 from main at the WAG-402 merge (8408a911) plus this record and the release notes.
- The release notes say the feature is off by default and where to turn it on.
- A fix found in the live test goes into 0.2.56, not into a changed 0.2.55.

## Ruled out
- Test first, then release: it was the recommendation (badge position confidence 45). Not wanted now.
- Push only, no release.

## Comments
none

## Open questions
- Live test on the released build: a real screenshot found by Spotlight, Control Option S, the badge position above the thumbnail, the 6 s fade, right click "Turn off".

## Sources
- Case c_898a1e68-3188-4f49-8818-b99d05eb97c6.
- docs/decisions/2026-10-20-screenshot-to-a-session.md.
