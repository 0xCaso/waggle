# Which quick reply chips, and what happens to a failed reply after Continue?

Decided: 2026-10-27 · Case: c_37e44ba5-77dd-46f2-8e10-699799aeff01 (follows c_5053a6a8-a3c1-43a0-9d0a-1bb4cf34b9d8)

## Question and choice
Three calls the WAG-410 and WAG-411 workers made alone. The operator chose:
1. Failed reply after "Continue in a new session": "Mark it handed over". Add a reply state, Handed over, so the
   case no longer shows a failure after the operator continues.
2. Quick reply chips before the Ask for pills: "Let's discuss", "Look at my comments" and "Show me more".
   "Go ahead" is removed.
3. Usage: "Log them". Each quick reply chip writes a usage word.

## Why
- Operator, on Go ahead: "maybe that button doesn't make sense? replace with something else like, discuss or
  look at my comments". Picking an option already means go ahead.
- Let's discuss matches the many "discuss" replies in the friend's export.
- Look at my comments makes the new region comments one click.
- The chips come from the usage data. A usage word shows if they help.
- A red failure that the operator already solved looks like an open problem.

## Constraints
- "Let's discuss" sends a keep-talking reply. The agent answers in a new round and does not act yet.
- "Look at my comments" shows only when the case has region comments. It sends them and asks the agent to act
  on each one.
- Every chip stays reachable in the one scrolling row right above the input (2026-10-27-friend-usage-fixes.md).
- Usage words are codes only, no text.
- HAIL-192 still holds: a session that comes back from ended gets its failed replies requeued. A Handed over
  reply is not requeued.

## Ruled out
- Keep the reply failed after Continue: it looks like an open failure.
- Keep "Go ahead" as a plain message: it does not fit next to the options.
- Go ahead takes the recommendation: replaced by the new chips.
- Do not log the chips: we could not see if they help.

## Comments
- "maybe that butto doesn't make sense? replace with something else like, discuss or look at my commetns".
  Done: Go ahead is removed, Let's discuss and Look at my comments are added.

## Open questions
none

## Sources
- Case c_37e44ba5-77dd-46f2-8e10-699799aeff01

## Tasks

### WAG-410 pass 2. Handed over reply state
From: Question and choice, item 1.
- A new reply state `handed_over` (daemon migration, protocol doc, Swift state).
- Clicking "Continue in a new session" on a case with a failed reply marks that reply `handed_over`.
- The case shows it as handed over, not as failed. A `handed_over` reply is never requeued by HAIL-192.
- Daemon and app tests.

### WAG-411 pass 2. New quick reply chips and their usage words
From: Question and choice, items 2 and 3.
- Remove "Go ahead". Add "Let's discuss" and "Look at my comments". Keep "Show me more".
- "Look at my comments" shows only when the case has region comments, and sends them.
- Each quick reply chip writes a usage word (usage migration if needed).
- All chips stay in the one scrolling row above the input.
