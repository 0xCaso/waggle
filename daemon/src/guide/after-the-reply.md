# After the reply

## Applying a reply

Treat the reply as a decision, never as something to second-guess. If it carries a choice, that
is the option id from your options list. If it carries a message, read it as the human's own
words, free text they may have written instead of, or alongside, a choice.

A reply with a choice and a message means approve with changes. The reply says so. Apply the
changes in the message, then go on. Do not ask again for the same approval.

A reply with feedback and no choices is Keep talking (see below): the human wants changes before
deciding. Revise the artifact or the text, then send a new round with waggle_update.

## Waiting for the reply

If Waggle can wake your session (Claude Code), a pending result says so. Waggle sends you a message
when the human answers. You may do other work or end your turn. When the message arrives, call
waggle_check once with the case_id.

If Waggle cannot wake your session (the Claude app, Cowork, Codex, any other client), keep calling
waggle_check with the case_id until the reply arrives, and do not end your turn while the ask is open.

## Comments

A review reply may carry numbered region comments, each anchored to a rectangle on the capture the
human reviewed. Read them in order; they describe what to change and where.

The human can also comment on words in your request: the title, what you need, the why, a question,
the recommendation, a pro or a con, a source. The reply then has "Comments on the request:" and one
line for each, `[n] On the title, "quoted words": the note`. Treat each note as feedback on those words.

## Attached files

A reply can carry files the human attached: screenshots, a PDF, notes. The reply then has a line
"Attached: 2 files" and one line for each file with its name and its path. Read the attached files
at their paths. The paths are absolute and the files are read-only. Copy a file first if you need
to change it. A reply can have files and no pick: that is Keep talking, so read the files and answer.

## Edits

On a markdown explanation the human can edit your document in place. The reply then says "The
person edited your document", gives the count of changed passages, a unified diff against the
version they started from, and their full new text as the next revision. When the person edits your
document, use their version as the base: build any new revision on their text, never on your old
one. Keep their wording unless a comment or the diff shows you must change it.

## waggle_update: after you act on it

If you changed the artifact because of the reply, call waggle_update with the new revision and a
one-line message describing what changed. This returns the case to the human for another look.

If the update changes something the artifact shows (copy, layout, a picture), send a new artifact
with it. An update with only a message keeps the old artifact on screen, and Waggle tells the human
the artifact was not updated.

WRONG
    waggle_update({ case_id, message: "Rewrote the last sentence." })  (the screenshots still show the old one)
WRONG
    Silently start a new waggle_ask for the same change.
right
    waggle_update({ case_id, message: "Moved the pay button above the fold.",
                    artifact: { type: "screenshot", path: "./shots/checkout-v2.png" } })

If your update proposes a new decision, send `items` with it, and a recommendation for each. The human
then answers from your new items; the first ones stay under "First options". Same rules as
waggle_ask: a short title and the full text in label for each option, and `recommendation` must
equal one option id. A single `options` list with a `recommendation` still works as a shortcut for one item.

right
    waggle_update({ case_id, message: "Split the change in two steps.",
                    items: [{ id: "split", options: [
                      { id: "a", title: "Two steps", label: "Ship the schema first, then the UI" },
                      { id: "b", title: "One step", label: "Ship both together" }],
                      recommendation: "a", recommendation_why: "Smaller review, easy to roll back." }] })

Without items, your current items stay as they are, and the human answers from them as before.

## A closing note: done

When the work is finished and you need no answer, send the closing note with `done: true`. Waggle
shows it as "Done" with a Got it button. Got it closes the case and sends nothing back to you. Do
not wait and do not call waggle_check afterwards. A done update cannot carry options.

Send a normal update (with options) only when you need a new decision. A normal update returns the
case to the human's Needs you list and they answer it again. An update that sends options starts with
the round's question: a short question first (under 80 characters), details after a blank line, and last a short
instruction to the human if one helps.

WRONG
    waggle_update({ case_id, message: "Done and live. Every cell is honey now." })  (the case returns to Needs you and the human answers the old options again)
right
    waggle_update({ case_id, message: "Done and live. Every cell is honey now.", done: true })

## A progress note: working

A job can take a long time. Tell the human that you are still working. Send a progress note with
`working: true` and a short message. Waggle shows a pulsing "Working on it" line. The case stays
with you, the human gets no alert, and the old options fold away. A progress note carries only a
message: no done, items, options, artifact or stage. Do not wait and do not call waggle_check
afterwards.

Your next update without `working` returns the case to the human. It can carry the new artifact
or new items.

WRONG
    waggle_update({ case_id, message: "I am drawing a second version now." })  (it looks like a question and the human gets an alert)
right
    waggle_update({ case_id, message: "I am drawing a second version now.", working: true })

## Keep talking

Sometimes the reply is not a decision. The human wants to keep talking, and the case stays open. Do
not start the work yet. Answer with `waggle_update` on this case, then call `waggle_check` again for
the decision. The reply comes in one of these forms:

- **Lean**: the reply lists "Leaning" options. Treat them as a hint, not a choice.
- **Rule out**: the reply lists "Ruled out" options. Treat them as a no. You may drop them or send new items.
- **Ask**: the human wrote a question. Answer it.
- **More detail**: the human asked for an explanation, and may name a format. Match the format.
- **How it works**: the reply is "Explain how the code behind this decision works." or `Explain how this works: "<quote>"`. See below.
- **Comments only**: the reply has comments on the artifact and no pick. Revise, then send the new artifact.

Answer in the most useful form, kept short: markdown for reasoning, an html_bundle for a prototype or
a chart. If the answer changes what the human should pick, send items with it.

Formats for more detail:

- eli5: explain it like the human is five - short sentences, everyday words, one concrete analogy,
  no jargon, then one line on what the choice means for them. Send as markdown.
- diagram: one Mermaid or SVG diagram of the flow or the parts, with short labels. Send as a
  diagram artifact; if a diagram artifact is not available, an html_bundle with an inline SVG.
- page: one short interactive page, one self-contained html_bundle, offline, no external links or
  fonts from the network.

### How it works

The human asks how something works. Explain only the part they name: the quote, or the code this
decision touches. Do not explain the whole system. Follow the style in the operator preferences
("When the human asks how something works..."), which is the human's "How you like to learn" setting:

- Short text: up to 3 short lines. Text only. No artifact needed.
- Diagram first: attach a diagram artifact (`.mmd` or `.svg`) of the parts, then up to 3 short lines.
- Step by step: attach a markdown artifact with numbered steps.
- Something to try: attach a small `html_bundle` the human can click through.

Cite the files you read as `sources`. Send the answer with `waggle_update` on the same case. Keep the
options as they are. End by asking for the decision again. Then call `waggle_check`.

right
    waggle_update({ case_id, message: "The ask goes to the daemon, which stores it. [[s:srv]]\nThe app reads it over the socket.",
                    sources: [{ id: "srv", kind: "file", label: "server.ts:597",
                                ref: { path: "daemon/src/server.ts", line: "597" } }] })

WRONG
    Treat a Leaning list as the decision and start the work.
right
    Answer the message with waggle_update, then call waggle_check for the decision.

## follows: a new ask, not a chat thread

There is no chat thread inside one ask. If you need more after an answer, open a new ask with
follows set to the earlier case_id:

    waggle_ask({ ..., follows: "c_01J..." })

Never ask the human to reply in the terminal instead.
