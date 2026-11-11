# Do tables stay in agent text?

Decided: 2026-11-11 · Follows: docs/decisions/2026-11-10-match-request-page-to-mockups.md (case c_85293341-be6c-4e69-8de4-5b4ac7a4deb2)

## Question and choice
The PR #1 review noted that AGENTS.md, SECURITY.md and `docs/protocol-mvp.md` allow bold, italics, inline code,
lists and paragraphs only, while the request page now renders pipe tables in agent text. Keep the tables with a
record, or drop them?

Kept. The operator chose "Quiet honey box" on 10 Nov: the need text with its table styled as in mockup B. Agent
text may hold a pipe table: a header row, a `---` separator row, then body rows.

## Why
- Mockup B shows the need's numbers in a table, and the operator wants the page identical to the mockup.
- A table adds no new way out of the app: its cells are the same safe inline markdown (bold, italics, inline
  code). No links, no images, no HTML, in a cell or anywhere else.

## Constraints
- A body row takes the header's cell count: a short row gets empty cells, extra cells are dropped.
- The queue row and notifications still show one plain line with the markers stripped.
- AGENTS.md, SECURITY.md and `docs/protocol-mvp.md` list tables with the other safe markdown.

## Ruled out
- "Drop the tables": the need loses the mockup's table, and numbers go back to lists that are harder to compare.

## Open questions
none
