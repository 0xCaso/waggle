# How do we clean up the request page UI?

Decided: 2026-11-09 · Case: c_2812709b-c351-42cc-9824-d42b57da2355

## Question and choice
How do we change the request page of the Mac app, which the operator finds crowded? The operator chose "Mockups first": "Fix the table now. Then make 2 to 3 HTML mockups of the request page (light cleanup to minimal) in design/mockups/, and you pick one in Waggle."

## Why
- The operator: the page is "still quite crowded" and the UX can improve a lot; a markdown table in the "What I need from you" box shows as raw pipes.
- The layout changes touch the main screen, so the operator compares directions before the Swift code changes.
- The table bug is a bug, not a visual choice, so it is fixed first in all cases.

## Constraints
- Stay in SwiftUI. No rewrite in Rune (github.com/anomalyco/rune): it is pre-release, takes no PRs, and the app is about 68k lines of Swift.
- Native text selection stays, because comments on ask text depend on it.
- The need box keeps its safe rendering: no clickable links, nothing loads.

## Ruled out
- "Build the quick wins" directly: the operator would see the result only after the build, and the duplicate option cards would stay.
- "Only the table fix": the page would stay crowded.
- A rewrite in Rune: high cost, pre-release framework, it does not fix design problems.

## Comments
none

## Open questions
- Which mockup direction the operator picks (next ask).

## Sources
- Case c_2812709b-c351-42cc-9824-d42b57da2355
- apps/macos/Sources/Knock/Review/AgentMarkdown.swift (tables kept as plain text)
- apps/macos/Sources/Knock/Review/MarkdownView.swift (MarkdownTableView already exists)
- Operator screenshot of the round 2 request page, 2026-11-09
