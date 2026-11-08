# How do we cut low-stakes asks?

Decided: 2026-10-27 · Case: c_cee32437-7e5e-4a70-81bb-2f94c86c68dc

## Question and choice
The question: which way do we cut low-stakes asks, a "Let the agent decide" rule per kind, or one case for small asks?
The operator chose: "A rule per kind. The agent adds a category and a recommendation. If you turned the rule on, Waggle answers at once and logs it in a folded list."

## Why
- The friend dismissed many asks, and the daily rate rose after 19 Oct.
- On decision asks the friend took the recommendation more often than not.
- A rule removes the ask and the wait. A batch keeps both.
- The operator gave no extra reasons in the reply. The recommendation was "rule", and the operator took it.

## Constraints
- Off by default. A master switch, then one switch per category. With the master off, agents never see the category line in the guide.
- A review is never auto-decided. An ask with no recommendation is never auto-decided.
- The agent must not use a category for a choice that deletes data, spends money or ships.
- Every auto-decision shows in a folded "Decided for you" list, with "Change my mind".
- Local only. No new network call.
- The usage log holds coded values only: the category slug and the rule id. No ask text.
- UI copy: plain, friendly, no em-dashes.

## Ruled out
- One case for small asks (B): you still see every choice, but the agent still waits and agents may not hold asks back.
- Rule first, batch later: not chosen as a plan. Look at batching again only if rules leave many small asks.

## Comments
none. The operator marked nothing on the prototype.

## Open questions
- The fixed list of categories. The prototype shows naming, wording, formatting and test choices. The build story proposes this list.
- Should "Change my mind" tell the agent at once if it already moved on? The story proposes yes, as a normal reply.
- A design round on the settings page and the folded list was not run. The operator went straight to the record. Review the build in the app.

## Sources
- Case c_cee32437-7e5e-4a70-81bb-2f94c86c68dc
- `docs/decisions/2026-10-27-friend-usage-fixes.md` (task T4)
- A friend's usage export (not public): the `ask_created`, `ask_dismissed` and `ask_h` events.
- `daemon/src/guide/` (what agents learn about asks)
