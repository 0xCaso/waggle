# Which revised option card do I build?

Decided: 2026-11-10 · Case: c_3dc21631-0f13-497b-9b14-8ccb399d9160 (follows c_f3f92918)

## Question and choice
Which of the three revised option cards (mockup `design/mockups/2026-11-10-option-text/`, round 2) do I build? The operator chose "Gist and facts, cleaner": "One neutral chip style, at most 3 facts per option. Short gists in two plain columns. "Why you" is one plain line. Color only on the + and – signs and the picked card." With a change: do not lose details.

## Why
- The operator: "I like B a lot now, but what matters is not to lose details: show everything in a schematic way as in the mockups, but without losing important details."
- Mine: B is the calmest card and shows the facts first; the full points stay one click away.

## Constraints
- Card as variant `gist` of the round-2 mockup: at most 3 fact chips in one neutral style; gists in two plain columns with quiet PROS / CONS labels; color only on + / – and the picked card's honey.
- No detail is lost: every full pro, con, effect, description and reason is one click away ("Show the full points") and in VoiceOver; nothing the agent sent is dropped.
- When a point has no gist, the app shows the full point (wrapped with a hanging indent), not a cut one; a cut with "…" only on closed cards, at a whole word.
- "Why you" is one plain line; the full text shows on click.
- Paths and code in mono chips, key numbers bold and tabular.
- `waggle_ask` and `waggle_update` accept the new fields as optional; old asks keep working.

## Ruled out
- Tidy list: long points lose their ends on the first screen.
- Compare grid: the biggest change; needs the same facts for every option.

## Comments
- "Do not lose details": done as the second and third constraints.

## Open questions
none

## Sources
- Case c_3dc21631-0f13-497b-9b14-8ccb399d9160; earlier c_f3f92918-9809-48eb-9079-f0779207986d
- design/mockups/2026-11-10-option-text/index.html (variant gist)
- docs/decisions/2026-11-10-option-text-and-highlight.md
