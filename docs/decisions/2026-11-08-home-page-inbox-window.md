# Which home page for waggle.so: inbox window or manifesto with a loop?

Decided: 2026-11-08 · Case: c_97b1fb8f-002f-4c7f-b555-a108a131bdd4

## Question and choice
The direction for the new waggle.so home page. Both variants lead to Download and show the inbox use case.

The operator chose "A: Inbox window": the new headline "Your agents ask. You decide in one place." with
Download, then a full Waggle window where a request lands in Needs you, you pick the recommendation and send,
and the agent continues.

## Why
- The operator asked earlier: "the home page should point to download, focus on the inbox use case"
  (case c_13196e72).
- A shows the inbox at once. The manifesto line stays on the page as a quote card that links to the essay.

## Constraints
- Download for Mac and Install with your agent stay above the fold.
- The GitHub link in the header and "Open source · Apache 2.0" in the footer stay (case c_13196e72).
- Privacy copy must stay true: Telegram and Slack, when connected, do send cases off the Mac.
- The page is self-contained HTML in site/index.html. No screenshots or other binaries.

## Ruled out
- B: Manifesto with a loop. The visitor reads the idea before the product, and the operator asked to lead
  with the inbox.

## Comments
none

## Open questions
- The og:image still shows the old manifesto visual. A new one needs a picture, which the operator makes.

## Sources
- Case c_97b1fb8f-002f-4c7f-b555-a108a131bdd4, case c_13196e72-29d8-40f7-b40f-3ad1feb0f76a.
- Prototype: .knock-review/home-redesign/ (not committed).
- site/index.html.

## Tasks

1. **Ship variant A as site/index.html.** Criteria: the page is variant A with the real title, favicon and
   og/twitter meta; the description is the new line; it renders at 1280 px and 390 px. From: Question and choice.
2. **New og:image.** Criteria: a 1200x630 image of the inbox window replaces site/og.png. From: Open questions,
   line 1.
