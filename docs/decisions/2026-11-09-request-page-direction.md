# Which direction for the request page?

Decided: 2026-11-09 · Case: c_2611be01-5d90-411d-bbbe-ef4cf94f0641

## Question and choice
Which of three mockup directions do we use for the request page (A Calm, B Options in place, C Focus)? The operator chose "B · Options in place": "The options are the page. You select, read the pros and cons, and send in one place." They chose it with changes.

## Why
- The operator: "B is very nice, but we must be careful": the mockup covered only a text-only request.
- The operator: many requests carry artifacts or screenshots to review, the conversation stays hidden until they open it, and there is a full-size view. Each of these must work with the new design.
- The goal, in the operator's words: Waggle "much simpler to use", everything needed in view, "not too many elements, not too much text", a UI that is always clear.
- Mine: B removes the duplicate option cards and puts the decision in the first screen.

## Constraints
- Before any Swift change, map every case of the request page and say how B handles each one.
- One layout system for all cases, not a special layout per case.
- The conversation must not stay hidden when it has something new.
- The full-size artifact view keeps the decision reachable.
- Less on screen: no element without a job, short text.
- The table fix in the need box (2026-11-09-request-page-ui-cleanup) stays.

## Ruled out
- A · Calm: keeps the separate composer band and the scroll to option details.
- C · Focus: a new way to move between requests; largest change and most risk.
- Building B now for text-only requests only: it would break or crowd the pages with artifacts, plans and conversation.

## Comments
- "Bisogna stare attenti a molte casistiche": next step is a case map before the design is final.
- Screenshot 1 (mockups ask): artifact pane, decision pane and composer side by side. To cover in the case map.
- Screenshot 2 (a plan from another project): long document artifact, plan stepper, multi-select options, conversation column. To cover.
- Screenshot 3 (full size): artifact full width, decision in a narrow side panel. To cover.

## Open questions
- How the page splits space between artifact, decision and conversation in each case.
- When the conversation opens by itself.

## Sources
- Case c_2611be01-5d90-411d-bbbe-ef4cf94f0641
- design/mockups/2026-11-09-request-page/index.html
- docs/decisions/2026-11-09-request-page-ui-cleanup.md
- Three operator screenshots of the Mac app, 2026-11-09
