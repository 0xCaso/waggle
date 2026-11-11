# How do the options show less text and more highlight?

Decided: 2026-11-10 · Case: c_f3f92918-9809-48eb-9079-f0779207986d

## Question and choice
How do the option cards and the need show less text, with paths, code and numbers highlighted? The operator chose "Gist and facts" with changes: fact chips on each option, pros and cons as short gists, full sentences behind "Show the full points", closed cards with the chips and the +N −N count.

## Why
- The operator: "I really like the cleanness of Gist and facts", but "we must be careful not to put really very many labels"; B "used very many colors and very many labels".
- The operator: "after your changes I really get much more text than usual: long descriptions, the pros and cons are very long and also the why I recommend it"; "what matters is that we show the important things".
- Mine: the text is not longer; the agents send the same text. The open card now shows all pros, cons and the reason, which the compact rows hid behind counts. No prompt or guide was changed in this PR.

## Constraints
- Few labels and few colors: at most one tint for pros and one for cons, chips in one neutral style; no badge row for "Why you".
- The open card shows the important things first: gist lines, not full sentences; the full text one click away.
- Closed cards never cut a word.
- Paths and code in mono chips; key numbers bold and tabular.
- Every function stays (FUNCTIONS-CHECK).

## Ruled out
- Tidy list as drawn: it still shows all 6 points in full. The operator wants a new round of A with less text.
- Compare grid as drawn: "at first sight too many pros and cons (and details) are lost".

## Comments
- "Did you change the prompts?": no. The open card shows text that was hidden before. Answered in the closing update.
- "If you want, propose mockups again: A with less text, B cleaner, C keeps more pros and cons": done as the next mockup round.

## Open questions
- Which of the three revised directions (round 2) to build.
- Whether waggle_ask gets optional fields (facts per option, a gist per point), or the app derives them from today's text.

## Sources
- Case c_f3f92918-9809-48eb-9079-f0779207986d
- design/mockups/2026-11-10-option-text/index.html
