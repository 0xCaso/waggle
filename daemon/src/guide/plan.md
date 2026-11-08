# Plans: rounds with a stage label

Use this when you brainstorm or plan with the human: the superpowers brainstorming skill, or any
flow that asks questions, compares approaches, shows a design and ends in a spec. A plan is one case.
Each step is a Round with a stage label. The human sees one row in the queue and a stage track
(Questions, Approaches, Design, Spec).

Never ask these in the terminal. The first question is `waggle_ask`. Every later round is
`waggle_update` on the same case with a `stage`. Never open a new case for each question.

## The rounds

1. **questions**: one question per round, multiple choice when you can. `step` is the question
   number, `total` how many you expect, `total_is_estimate: true` while it is a guess.
2. **approaches**: 2 to 3 approaches as options, with your recommendation and why. Put the trade-offs
   in an artifact.
3. **design**: one design section per round (`step` 1 of `total` 3, for example). The options are
   "approve" or "change".
4. **spec**: the written spec as a markdown artifact. The options are "approve and start planning" or
   "request changes". After approval, go on to writing the implementation plan.

## Prototypes: flow first

Flow first, then screens. Order: 1) goal and who uses it, 2) user flows: the steps, what comes first and why, 3) the order of screens from the flow, 4) screen detail. Do not start at the screens.

When a plan holds prototypes, send the flow first. Attach a flow artifact (markdown or a small
diagram) before any screen bundle. Make the first decision about the flow, not about screen details.

## Artifacts: one per round, any type

Every round can carry its own artifact of any type (or several, each with a name). Attach the one
that best supports that round's question: screenshots for a visual choice, an html_bundle for a
prototype, a diagram for an architecture section or a flow, markdown for reasoning and the spec. Call
`waggle_guide` with topic `artifacts` for how to build each one.

A round without an artifact keeps showing the last one. Send a new artifact when the picture the
question needs changes. Comments on an artifact come back with that round's answer.

## Options: pros and cons on every round

Every option in a round carries `pros` and `cons`: 1 to 3 short lines each. The reasons must be real
and different for each option. A vague label such as "Option A" leaves the human with nothing to
compare.

## The first question

    waggle_ask({
      stage: { name: "questions", step: 1, total: 5, total_is_estimate: true },
      title: "Plan: onboarding for new users",
      need: "Who is the first user of onboarding?",
      why: "It decides the first screen and what we cut.",
      items: [{ id: "user", options: [
        { id: "new", title: "New users", label: "People who just installed Waggle",
          pros: ["Biggest group today"], cons: ["Teams wait longer"] },
        { id: "teams", title: "Teams", label: "Teams who share one queue",
          pros: ["Shared queues need it first"], cons: ["A smaller group today"] } ],
        recommendation: "new", recommendation_why: "Most of your users are new." }]
    })

## Every later round

    waggle_update({
      case_id: "<the plan case>",
      message: "Which approach fits best?",
      stage: { name: "approaches" },
      items: [{ id: "approach", options: [
        { id: "wizard", title: "Wizard", label: "A step by step wizard",
          pros: ["Guides the first ask"], cons: ["More screens to build"] },
        { id: "list", title: "Checklist", label: "One checklist page",
          pros: ["One screen to build"], cons: ["Easy to skip steps"] } ],
        recommendation: "wizard", recommendation_why: "It is the shortest path to the first ask." }],
      artifact: { type: "markdown", path: "./plan/approaches.md" }
    })

`message` is the question the human reads for this round. Put a short question first: its first
sentence is the bold headline. Put details after a blank line; they render as markdown. Then call
`waggle_check` with the case_id.

## The answers

Each reply comes back like any reply. Keep the answers you got in your own notes: there is no tool to
read earlier rounds back. If the human writes their own words, treat that as the answer and adapt the
next round. If the human wants to keep talking, answer with `waggle_update` and call `waggle_check`
again.

WRONG
    Ask question 2 in the terminal, or open a second waggle_ask for it.
right
    One waggle_ask, then waggle_update with a stage label for every later round.

## Deprecated shortcut

`kind` plan with a `stage` on the first ask still works. Waggle will remove it after two releases.
A `stage` on any ask or round does the same job.
