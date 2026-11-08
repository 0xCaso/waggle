# Decision record

The human decided. Write down what they chose and why, so the next agent does not ask it again.
Waggle does not write into the repo. You write the file.

## When

Do this when a reply ends with the line "Now write the decision record". If the reply has no such line, write no record.
Do not write a record when the human chose Keep talking.

## Path

Write one markdown file: `docs/decisions/<yyyy-mm-dd>-<slug>.md`.
Use the date of the decision and a short slug of the question.
If the repo has its own decisions folder (for example `docs/adr/`), use that folder.
Commit the file with your next change. Do not make a commit only for the record.

## Template

```markdown
# <the question>

Decided: <yyyy-mm-dd> · Case: <case id>

## Question and choice
The question, then what the human chose. Quote the option.

## Why
The reasons, in the human's words where you can. Add your own reasons second.

## Constraints
What must stay true after this choice. One line each.

## Ruled out
Each other option and why it lost. One line each.

## Comments
Each thing the human marked. For each: what they wrote, and what you did with it.

## Open questions
What is still not decided. Write "none" when nothing is open.

## Sources
The case id, and the sources the ask cited (files, pages, links).
```

Keep every section. Write "none" in a section that has nothing.

## Send it

After you write the file, send it on the same case:

`waggle_update` with `done: true`, a short message, and a markdown artifact named "Decision record".

The case is already decided. Waggle accepts this update and shows the record as a last round.
Do not call waggle_check after it. The human needs no answer.

## Examples

WRONG: a record that only says "We chose option A." It has no why and no ruled-out options.

right: a record with every section. Ruled out names each other option and why it lost.

WRONG: a task that says "Build the flow."

right: a task with acceptance criteria and the record line: "Build the flow. Criteria: 25 screens, one path from sign-in to intake. From: Why, line 2."

## Tasks

Do this only when the reply says to plan tasks from the record.
Write each task so another agent can pick it up:

- A title.
- Acceptance criteria: a list the agent can check.
- The record line it comes from. Quote the line.

A brief for another agent starts with the record. Paste or link the record first, then the task.
