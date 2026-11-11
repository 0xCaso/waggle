# Is the simpler request page ready to commit?

Decided: 2026-11-10 · Case: c_0d5db705-1690-4289-b6c0-9c7d4cb2df08

## Question and choice
Do I open the pull request now, while you test Waggle Dev?
Choice: "Open a draft PR now: commit, push the branch and open a draft PR to main. The body says that you test it in Waggle Dev before the merge." Chosen with changes.

## Why
- "I would first test it in the local fork ... let's use Waggle Dev with my changes so I test it a bit and see if I like it. We could already open the pull request anyway and explain that we are testing it in the meantime."
- A draft PR keeps the work safe on GitHub and shows the proof, but it does not merge while the test runs.

## Constraints
- The PR stays a draft until the operator ends the test in Waggle Dev.
- No screenshots, binaries, dist/ or scratchpad files in the commit.
- GitHub writes go out as 0xCaso.
- No function of the request page goes away ("the functions must stay").

## Ruled out
- Commit only, no PR yet: the work would stay only on this Mac and nobody could see the proof.
- Wait: the branch would stay uncommitted for the whole test.

## Comments
- "the conversation needs some fixing" (screenshot of the Conversation tab): the tab needs a fix before the PR. I list the problems I see and ask which to fix in a follow-up ask.
- "look at the block of text I have in the yellow section" (screenshot of the need box): the need box shows the first paragraph and the list under it as one bold 17 pt block. Cause: `NeedText.split` puts the list lines into the question when no blank line comes before the list. The bug is also on main. I fix it: the question stops at the first list line.

## Open questions
- Which problems of the Conversation tab to fix (follow-up ask).

## Sources
- Case c_0d5db705-1690-4289-b6c0-9c7d4cb2df08
- apps/macos/Sources/Knock/AskDoc/AskDocPage.swift (`NeedText.split`)
- apps/macos/Sources/Knock/Queue/ConversationTab.swift
