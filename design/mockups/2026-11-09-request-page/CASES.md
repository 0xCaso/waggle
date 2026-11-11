# Request page: case map

What the request page shows today, case by case, and how direction B ("options in place") must handle it. Source: the code in `apps/macos/Sources/Knock` (file:line in the appendix).

## Today: three layouts for one page

| Layout | When | What is on screen |
|---|---|---|
| Stacked | No artifact, or pane under 1000 pt | One scrolling column; options in a dock at the bottom |
| Side by side | Artifact and pane ≥ 1000 pt | Artifact 57 % left, question 43 % right, options dock under the question |
| Full size | "Open full size", Comment on a visual artifact, Open review | A separate screen: queue and pane are gone; artifact + a 340–430 pt column with Decision / Comments tabs |

Conversation: a 380 pt column, **closed by default in every case**, opened only by the bubble icon, ⌘] or "Open the history". It never opens by itself.

## The cases

| # | Case | Today | What B must do |
|---|---|---|---|
| 1 | Text only, pick one | Stacked; options twice (cards + dock) | Options in place, Send under them (the mockup) |
| 2 | Pick several | Checkboxes + "Pick up to N", "Tick the recommended", Clear | Same rows with checkboxes; Send shows the count |
| 3 | Reply only (no options) | Footer with a text field | The field is the decision area |
| 4 | Several questions (stepped) | Step bar, one question per step, "Send your N decisions?" | One step = one B block; the step bar stays at the top |
| 5 | Review (Approve / Request changes) | Options + a "why" field; "Open review" | Two large choices; the artifact is the focus |
| 6 | One artifact (markdown, prototype, screenshots, diagram) | Side by side 57/43, or a pinned bar when narrow | Artifact left, B column right, always the same width |
| 7 | Several artifacts | Tabs on the artifact box | Same tabs |
| 8 | Plan (Questions → Approaches → Design → Spec) | Stage track above the title | Stage track stays, one line high |
| 9 | Update with new options | Blue "Options from the update" bar + "First options" | One line above the options; old options folded |
| 10 | Message-only update, working note | A note heads the page | The latest agent message in one line at the top, full text in the conversation |
| 11 | Sent, waiting, delivered, failed | Footer + green "Delivered" banner + status strip | One status line in the header; Retry only on failure |
| 12 | Done | Green strip + Got it | Same, without the dock |
| 13 | Follow-up / replaces | Header above the title | One line in the crumb |
| 14 | Sources, team comments | Pills, a 380 pt list panel, comments section | Unchanged |
| 15 | Offline | Dimmed, no composer | Unchanged |

## What makes the page crowded across cases

1. **Three layouts with different rules.** The same request looks different in the pane and in full size; the decision moves between the bottom dock and a side column.
2. **The conversation is hidden.** Agent replies after round 1 live only in the closed column.
3. **Too many controls at once.** Option rows show counts, lean, rule out and Recommended; 9 chips; a note field; banners.
4. **Too much text from the agent.** The need box often holds a whole report (one real case: 5 paragraphs).

## Appendix: where in the code

- Layout split: `Plan/AskArtifactLayout.swift:16-27, 83-86`
- Conversation default closed: `Queue/CasePaneView.swift:85-88`; column 380 pt: `Queue/ConversationSplit.swift:7`
- Full size: `Views/MainWindowView.swift:52-54`, `Review/ReviewWorkspaceView.swift:170-181`
- Options dock: `Composer/ComposerCardView.swift:242-283`; chips: `Composer/AskForDetailView.swift:4-13, 173-181`
- Stepped asks: `Queue/CasePaneView.swift:993-1019`
