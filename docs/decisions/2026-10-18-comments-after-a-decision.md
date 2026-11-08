# What happens to comments that come after a case is decided?

Decided: 2026-10-18 · Case: c_02e6f4bc-061f-45e8-a3eb-a512602109ea

## Question and choice
When people comment on a shared case after the owner decides it, what can the owner do with those comments?

Chosen: "Reopen from the comments". "A bar on a decided case with new comments: Change answer (opens the ask again, the page goes back to open) and Send to the agent. Late comments no longer wake the agent by themselves."

## Why
- The operator, from the shared page: "what if this is decided so i cannot do anything about it also if people commented? ... allow reopening a case?"
- A decision can change after the team speaks. The owner keeps the decision and gets one clear step to act on late comments.

## Constraints
- A comment counts as late when it comes after the last decide answer on the case.
- On a decided shared case with one or more late team comments, the Mac app shows a bar: "N comments since you decided", with "Change answer" and "Send to the agent".
- "Change answer" uses the existing Change answer flow. While the owner changes the answer, the shared page shows the case as open again, without the Decided block. The new answer then shows as the new decision.
- "Send to the agent" sends the late comments to the case's agent session as one prompt, with the existing send-prompt path. When the session is closed, the owner can copy that prompt to paste into a new session.
- A late comment no longer wakes the agent by itself. Comments before the decision still wake it, as today.
- A comment is never an answer (team-comments guide). This decision does not change that.
- The page still accepts comments after a decision until the owner closes them.

## Ruled out
- Close comments on decide: late feedback is lost.
- Keep it as it is: late comments still wake a busy agent, and nothing tells the owner they came late.

## Comments
none

## Open questions
none

## Sources
- Case c_02e6f4bc-061f-45e8-a3eb-a512602109ea.
- daemon/src/server.ts (comment wake, WAG-394), daemon/src/connectors/relay.ts (sendOutcome).
- apps/macos/Sources/Knock/Review/AnsweredAskColumnView.swift (Change answer).
