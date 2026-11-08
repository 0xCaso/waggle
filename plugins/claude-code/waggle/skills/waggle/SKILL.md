---
name: waggle
description: Ask the human for a decision or a review through Waggle instead of the terminal. Use when you must pick between product, design or UX options, when work needs a review before it ships, when only the human has the answer, or when they say "ask me in Waggle", "send me a review" or "check with me". Also use it for every question, approach, design section and spec review of a brainstorming or planning flow (the brainstorming skill or similar): those go through ONE Waggle case with a stage label on each round.
---

# Asking the human through Waggle

Waggle is a Mac app. It shows the human your question or review in a queue, with a prototype or a write-up beside it, and sends their answer back to you.

## When to ask

- A decision the human must make: a product, design or UX choice, or a correctness call.
- A review of your work before it ships.
- Information only the human has.
- The human says "ask me in Waggle", "send me a review", "check with me" or "what do you think I should do".

Never turn one of these into a question in the terminal. Do not ask for a routine technical choice, for anything the repo, the docs or the tests answer, or to report progress. Use normal output for those.

## How to ask

Call `waggle_ask`. The tool belongs to this plugin's Waggle server. Its full name in Claude Code is `mcp__plugin_waggle_waggle__waggle_ask`.

1. Call `waggle_guide` before your first ask. It has the format, ready templates and WRONG and right examples.
2. Write the title as the question itself. Make the first line of `need` stand alone: the queue shows only that line.
3. The human reads the ask in Waggle, not in the terminal. Give each option a short title, spell out the whole option in its label, and never refer to "1, 2, 3" or to text only your terminal output explained.
4. Give a recommendation and say why, in one to three sentences. Put long reasoning in an artifact. For a reply item, write the suggested reply as the human, or leave it out when only the human knows the answer.
5. Send one request for one decision. Send unrelated decisions as separate requests, one waggle_ask each. Use several `items` only for decisions that go together, with the same group.
6. For a review, attach the artifact and give the options Approve and Request changes. Send `artifact`, or `artifacts` (each with a `name`) when one format is not enough.
7. The human may decide, or keep talking (a lean, a ruled-out option, a question, a request for more detail). To keep talking, answer with `waggle_update`, then call `waggle_check` again.

The old shortcuts `kind` review, `kind` plan, `questions` and top-level `options` still work. They are deprecated. Waggle will remove them after two releases. Do not use them in new asks.

## Brainstorming and planning: rounds with a stage label

When you run a brainstorming flow (the superpowers brainstorming skill or a similar one), do not ask in the terminal. Use ONE Waggle case. The human sees one row in the queue with a stage track: Questions, Approaches, Design, Spec.

1. Call `waggle_guide` with topic `plan` for the templates.
2. Send the first question with `waggle_ask` and `stage` `{ name: "questions", step: 1, total: 5, total_is_estimate: true }`.
3. Send every later round with `waggle_update` on the same `case_id`: a new `stage`, new `items`, and the question in `message`. Do this for each next question, the approaches, each design section and the spec review.
4. Every round can carry its own artifact of any type. Attach the one that best supports that round's question. A round with no artifact keeps showing the last one.
5. After each reply, call `waggle_check` for the next answer. Never open a new case for each question.
6. Keep the skill's own steps and gates. Only the place where you ask changes: Waggle, not the terminal. After the human approves the spec, go on to writing the implementation plan.

## How to word asks

Follow the writing style in Waggle's server instructions. The human picks it in Waggle (ASD-STE100 by default, or Normal), so the server tells you which one applies.

## Artifacts

- Markdown for reasoning or a written plan.
- An HTML bundle for a prototype, a chart, a comparison or a visual plan.
- A screenshot for one image.

## After you ask

- `waggle_ask` waits up to 50 seconds. A `pending` result is normal: call `waggle_check` at once with the same `case_id`. Never end your turn while an ask is open.
- Treat the reply as the human's decision. Apply it.
- If the artifact changes, call `waggle_update` with the new revision and one line that says what changed.
- If you need more after an answer, call `waggle_ask` again with `follows` set to the earlier `case_id`.
- To change an ask you already sent, call `waggle_ask` with `replaces` set to its `case_id`.

## What the human sees in this session

If the Waggle mod is on, a line above the prompt reads "Waggle · waiting on your answer" while your ask is open, and shows the answer after they reply. You do not need to repeat it in the terminal.
