# Which Conversation tab problems do I fix?

Decided: 2026-11-10 · Case: c_5076fdc5-fe22-4f60-bdd8-64a95035e3c7 (follows c_0d5db705-1690-4289-b6c0-9c7d4cb2df08)

## Question and choice
Which problems of the Conversation tab do I fix before the draft PR?
Chosen: "Even gaps", "Question line in bold", "Remove Open the history", with changes in the message.

## Why
- "I would keep the messages expanded by default, and I would remove the 'show less'"
- "I don't see the point of the copy button, I would remove it, and also the 'see v3' there in the conversation"
- "the small conversation button is not needed any more now that it is a tab" (the bubble icon with the round count in the top bar)
- "'Open the history': we need to see if it is necessary; we could show all messages by default, just by scrolling to the top"

## Constraints
- Every message of the thread shows in full; no fold, no Show more or Show less.
- No row of actions under a message, so the gaps between messages are even.
- ⌘] still opens the Conversation tab and goes back to Decision.
- "4 earlier requests" stays; it opens the other requests of the session.
- The text of a message can still be selected and copied by hand.

## Ruled out
- Messages near the answer box: not picked.
- Agent message on a light card: not picked; it adds boxes.

## Comments
- Show more / Show less: removed; messages show in full.
- Copy and See vN: removed from the Conversation tab. Copy answer stays in the ⋯ menu; the version switch stays on the artifact.
- Conversation icon in the top bar: removed; the tab and ⌘] do the same.
- Open the history: removed. The tab already holds every message of this request, from the first; scrolling up reaches it.

## Open questions
none

## Sources
- Case c_5076fdc5-fe22-4f60-bdd8-64a95035e3c7
- apps/macos/Sources/Knock/Queue/ConversationTab.swift
- apps/macos/Sources/Knock/Queue/CasePaneView.swift (top bar)
