# What's new

Read this when a tool result tells you Waggle updated, or partway through a long session, to check
what changed. This topic is served live from the running daemon, so it always reflects the current
release, never what your session read when it started.

## 0.1.9

Tool input schemas now accept fields beyond the ones your session saw at start. Claude Code and
Codex do not always re-read a tool's schema mid-session, so a later Waggle release can add a new,
optional field to waggle_ask, waggle_check, waggle_update or waggle_guide, and you can still send it
even though your cached copy of the tool does not show it. New optional html_bundle fields, usable even if your tool list does not show them:
`preview` (a file inside the bundle, preview.html or an image, built as a small summary card for
the case pane) and `viewport` ({ width, height }: the size to render your page at, for example
390x844 for a phone). Call waggle_guide({ topic: "artifacts" }) for the preview template. Other
fields you already know: kind, title, need, why, recommendation, recommendation_why, options,
artifact, follows, replaces.

WRONG
    Assume the tools you saw at session start are the complete set for the rest of this session.
right
    Call waggle_guide({ topic: "whats-new" }) again if a tool result says Waggle updated, or partway
    through a long session, to check for anything new to use.

## 0.1.37

The artifacts guide has a new "Decision pages" section: five copyable patterns (options side by
side, before / after, trade-off grid, bar chart, flow) for html_bundle pages that fit a 640 px
pane. If you build html_bundle pages, call waggle_guide({ topic: "artifacts" }) and read it first.
Use one or two patterns per page, the ones that carry the decision.

WRONG
    Build an html_bundle page from scratch and stack every pattern on it.
right
    Copy the one or two patterns that carry the decision from "Decision pages", and keep the page short.

## 0.1.38

The artifacts guide has a new "Rich interactive prototypes (optional)" section. Plain HTML stays
the default. For a prototype with real state, a bundled React build (the artifacts-builder skill)
is fine, and the section lists the fixes its scripts need on macOS.

## 0.1.41

waggle_update takes three new optional fields: `options`, `recommendation` and `recommendation_why`.
If your update proposes a new choice, send options with it, and a recommendation. The human then
answers from your new options, and your first options fold under "First options". Same rules as
waggle_ask: `recommendation` must equal one option id. Without these fields an update works as before.
Call waggle_guide({ topic: "after-the-reply" }) for an example.

## Pick several

waggle_ask takes two new optional fields: `select` ("one" or "many", default "one") and `max`
(an integer, only with "many"). With "many" the human ticks several options and sends them
together, and `recommendation` may be a list of option ids. waggle_update with options takes the
same fields. The reply reads `Choices: a, c`, then one line per choice. Single-choice asks work as
before. Call waggle_guide({ topic: "writing-an-ask" }) for when to use it.

## Zoom a prototype

People can now pinch to zoom an html_bundle in Waggle (25% to 400%, with a Fit button). If you
designed it in Pen, export the frames as HTML and send an html_bundle instead of a PNG, so the
person can zoom, select text and comment on parts. Call waggle_guide({ topic: "artifacts" }) for
the export call.

## Plan asks

waggle_ask took kind plan and a `stage` ({ name: questions | approaches | design | spec, step?,
total?, total_is_estimate? }). A plan ask is ONE case that walks a brainstorming flow: the human sees
one queue row with a stage track. Send every later round with waggle_update on the same case: a new
`stage`, new `options` and a `recommendation`, and usually a new markdown artifact. Never ask a
brainstorming question in the terminal. Call waggle_guide({ topic: "plan" }) for the templates.

## Content, not paths; topics outside git

waggle_ask and waggle_update take artifact content instead of a path: `{ type: "markdown", content }`,
`{ type: "html_bundle", html }` (one self-contained page), `{ type: "screenshot", data_base64 }`, and
`data_base64` inside screenshots items. Paths work as before. Use content when you have no project
folder, for example in the Claude desktop app or Cowork. waggle_ask also takes an optional `topic`, a
short name for the job. It only works when you are not in a git project: the queue shows it, and asks
with the same topic group together.

## Questions with points

`waggle_ask` has a new field `questions`: up to 12 questions with points to decide. A point option may
carry `pros` and `cons`. Answers come back as plain lines. Call waggle_guide({ topic: "writing-an-ask" })
for the shape.

## Knock is now Waggle

The product is now called Waggle. The tools have new names, with the same fields and the same
behaviour: waggle_ask, waggle_check, waggle_update, waggle_guide and waggle_settings. The old
knock_ask, knock_check, knock_update, knock_guide and knock_settings names still work for a short
time as aliases. Use the new names from now on; the aliases will go away in a later release. The
person sees each thing you send as a request in Waggle. You still ask. Nothing else about how you
write an ask changes.

WRONG
    Keep calling knock_ask because it still works.
right
    Call waggle_ask. Call waggle_guide({ topic: "writing-an-ask" }) if you are unsure how to write one.

## Approve with changes

A reply with a choice and a message now reads "chose this option WITH CHANGES". Apply the changes, then go on. Do not ask again for the same approval.

## Prototypes use your design system

Prototypes now use the project's own colours, type, radii and spacing, and the ask names the source. Call waggle_guide({ topic: "artifacts" }) for the short rule. The waggle-prototype skill has the search steps.

## The waggle-diagram skill

Draw flows, architecture, timelines and other diagrams with the waggle-diagram skill. It checks the layout and takes colours and fonts from the project's design system. Call waggle_guide({ topic: "artifacts" }) for when to send a `diagram` or an `html_bundle`.

## Options with pros and cons, and named artifacts

An option may now carry `pros` and `cons` (up to 5 short lines each). Plan rounds must send them.
An artifact may now carry a `name`. Artifacts with different names show as tabs on the decision
page. An option can point to a tab with `artifact_ref`, and to a place inside an HTML page with
`anchor`. The decision page shows the live artifact, so `preview` is now optional. Call
waggle_guide({ topic: "artifacts" }) for the rules and a copyable example.

## Flow first

Prototype and plan guides now say: write the goal, then the user flows (what comes first and why), then the screen order, then screen detail. Call waggle_guide({ topic: "plan" }) for the rule.

## Three blocks: items, artifacts and rounds

Teach and send three blocks. An **Ask** has `items` (one item for each decision, up to 12) and
optional artifacts. A **Reply** is a decision, or the human wants to keep talking (lean, rule out, a
question, or more detail). A **Round** is your next turn with `waggle_update`: a message, a revised
artifact, new items, a stage label, or done. `kind` is now optional. Send `artifacts` (a list, each
with a `name`) when one format is not enough. A review is an artifact plus the Approve and Request
changes item. A plan is rounds with a stage label.

The old shortcuts still work: `kind` review, `kind` plan, `questions`, and top-level `options` with
`recommendation`. They are deprecated. Waggle will remove them after two releases. Use items. Call
waggle_guide({ topic: "writing-an-ask" }) for the format.

WRONG
    Send questions with points because it worked before.
right
    Send items. Give items that go together the same group.

## The artifact follows the decision

With several decisions, put `artifact_ref` (and `anchor`) on the options of each decision. When the
human moves to another decision, Waggle then shows the right tab or place. For a `screenshots` set,
`anchor` is the image number (from 1) or its caption.

## Sources on a request

Cite where a claim comes from. Send `sources` with waggle_ask or waggle_update, and put `[[s:id]]` after the sentence. Waggle checks your session and marks each source seen or stated. Call waggle_guide({ topic: "writing-an-ask" }) for the 16 kinds and an example. Cite each source in the text. Waggle warns when a source has no citation, and shows it at the end of the why text.

## Comments on the request

The human can select words in your request and add a note on them. The reply lists them under "Comments on the request:", each with the part (the title, what I need, the why, a question, the recommendation, a pro, a con, a source) and the quoted words.

## One request for each unrelated decision

Send unrelated decisions as separate requests, one waggle_ask each. Use several items only for decisions that go together, with the same group. Waggle warns when the items of one request share no group.

## Each decision of a group is its own step

Each item of a request is its own step, also when items share a group. The group gives a shared heading and shared "how it works now" lines on each step. The artifact follows each decision. The reply is the same: one answer for each item.
