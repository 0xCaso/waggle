# Reviews

A review is an ask with an artifact and one decision: Approve or Request changes. The artifact is a
screenshot of the real UI, or an html_bundle prototype. The human looks at it, leaves comments on it,
then replies.

Send the ask with an artifact and one item with two options: `approve` (Approve) and
`request_changes` (Request changes). Give your recommendation and why.

What the human sees: your need and why, your recommendation, the artifact, and numbered pins with
notes anchored to what was on screen when they commented. A later artifact revision does not move
their old pins.

Comments travel with the reply. A reply with comments and no pick is Keep talking: the review stays
open. Revise, send the new artifact with waggle_update, and call waggle_check again. A review ends
only when the human picks Approve or Request changes.

WRONG
    items: [{ id: "ok", options: [...] }]
    (no artifact, but the need asks "does this look right?")
right
    artifact: { type: "screenshot", path: "./shots/checkout.png" }
    need: "Review the new checkout layout before it ships."
    items: [{ id: "review", options: [
      { id: "approve", title: "Approve", label: "Approve the checkout layout" },
      { id: "request_changes", title: "Request changes", label: "Ask for changes first" } ],
      recommendation: "approve", recommendation_why: "It matches the design." }]

## Screenshots

One PNG or JPEG, at most 20 MB, showing the real rendered state, not a mockup. Capture the whole
screen the human needs to judge, not a cropped fragment that hides context.

## When to use html_bundle instead

Use a prototype (html_bundle) when the human should click through states, not just look at one.
See the artifacts guide for the template and the staging rules.

## Several screens in one review

When the review covers more than one screen, attach them as one screenshots artifact (2 to 12
images): the human flips through them and pins comments on each. Use a gallery page (one
html_bundle with numbered, captioned images) only when the screens must sit together, for example
"before / after" pairs side by side. See the artifacts guide for both. You may also send several
artifacts, each with its own name, when the human needs a write-up and a prototype.

## Deprecated shortcut

`kind: "review"` with an artifact still works and fills the Approve and Request changes item for you.
Waggle will remove it after two releases. Give the item yourself.
