# Where do team comments go in the Mac app?

Decided: 2026-10-18 · Case: c_eabfcc53-461e-4a70-825c-dc0c320f53f2

## Question and choice
Where does the Mac app show the comments from the shared page, and where do you write a comment that the page shows?

Chosen: "One Comments tab". "The Comments tab shows all comments: your notes to the agent and the team thread from the page. Each one has a label (Team, You, Agent). When the case is shared, the box at the bottom has a switch: "To the agent" or "On the page". The Decision tab shows only a count line with a link to the tab."

## Why
- The operator looked for page comments in the Comments tab and saw "No comments yet". The team thread was in the Decision tab, under FROM YOUR TEAM.
- One place to look, and a page comment can be written from the app.

## Constraints
- A note to the agent never goes to the page. A page comment goes to the page and to the agent as untrusted input, as now.
- The composer switch shows only while the case is shared and Sharing is on.
- Reply and resolve on team threads stay available.
- The unread mark and the comment notice keep working, and they open the Comments tab.
- Sharing off: the Comments tab is the same as today.

## Ruled out
- Separate Team tab (the recommendation): clear, but three tabs on a shared case. The operator chose one place.
- Keep the thread in the Decision tab with a hint: still two places to look.

## Comments
none

## Open questions
- The default of the switch when a case is shared ("To the agent" or "On the page"). Proposal: "To the agent", so nothing goes public by mistake.

## Sources
- Case c_eabfcc53-461e-4a70-825c-dc0c320f53f2.
- apps/macos/Sources/Knock/Review/AskColumnView.swift:136 (SharedCommentsSection in the Decision column).
- apps/macos/Sources/Knock/Queue/CasePaneView.swift:868.
