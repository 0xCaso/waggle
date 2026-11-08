---
name: waggle
description: Ask the human for a decision or a review through Waggle instead of the terminal. Use when you must pick between product, design or UX options, when work needs a review before it ships, when only the human has the answer, or when they say "ask me in Waggle", "send me a review" or "check with me".
---

# Asking the human through Waggle

Waggle is a Mac app. It shows the human your question or review in a queue and sends their answer back to you.

## When to ask

- A decision the human must make: a product, design or UX choice, or a correctness call.
- A review of your work before it ships.
- Information only the human has.
- The human says "ask me in Waggle", "send me a review" or "check with me".

Never turn one of these into a question in the terminal. Do not ask for a routine technical choice, for anything the repo, the docs or the tests answer, or to report progress.

## How to ask

Call `waggle_ask`. It belongs to this plugin's Waggle server.

1. Call `waggle_guide` before your first ask. It has the format, templates and examples.
2. Write the title as the question itself. Make the first line of `need` stand alone.
3. The human reads the ask in Waggle, not in the terminal. Give each option a short title and spell out the whole option in its label.
4. Give a recommendation and say why, in one to three sentences. For a reply item, write the suggested reply as the human, or leave it out when only the human knows the answer.
5. Send one request for one decision. Send unrelated decisions as separate requests, one waggle_ask each. Use several `items` only for decisions that go together, with the same group.
6. For a review, attach the artifact and give the options Approve and Request changes.
7. If the human wants to keep talking, answer with `waggle_update`, then call `waggle_check` again.

The old shortcuts `kind` review, `kind` plan, `questions` and top-level `options` still work. They are deprecated. Waggle will remove them after two releases.

## How to word asks

Follow the writing style in Waggle's server instructions. The human picks it in Waggle (ASD-STE100 by default, or Normal), so the server tells you which one applies.

## After you ask

- `waggle_ask` waits up to 50 seconds. A `pending` result is normal: call `waggle_check` at once with the same `case_id`. Never end your turn while an ask is open.
- Treat the reply as the human's decision. Apply it.
- If the artifact changes, call `waggle_update` with the new revision.
- If you need more after an answer, call `waggle_ask` again with `follows` set to the earlier `case_id`.
