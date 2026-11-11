# Request page: every user-facing function, plus the answer box's weak points

All paths are under `apps/macos/Sources/Knock/`.

Two things you asked about are not what you expected:
- **The Working section has no expand/collapse control.** `SidebarWorkSections` (`Queue/SidebarSections.swift:194`) always shows a plain title. Only **Answered** and **Decided for you** fold.
- **The pro/con badges never say "✓2 ⚠2" in text.** They are SF Symbols `checkmark.circle` and `exclamationmark.triangle` with a number next to them.

## Sidebar
| Function | Control | When it shows | file:line |
|---|---|---|---|
| Hide the queue | panel fold button, ⌘[ | always | Queue/QueueListView.swift:397; Views/SplitFoldState.swift:128 |
| Show the queue again | rail "N Needs you" | queue folded | Review/SplitFoldControls.swift:196-223 |
| Move through rows, open one, dismiss one | ↑/↓, j/k, ↵, ⌘⌫ (asks to confirm) | the list has focus | Queue/QueueListView.swift:152-188 |
| Open an ask from Working or In planning | row click | rows exist; no fold | Queue/SidebarSections.swift:193-210 |
| Show or hide Answered | "› ANSWERED · N … SHOW/HIDE" | answered items exist; **closed by default**, the choice is saved (`queueAnsweredGroupOpen`) | Queue/QueueListView.swift:406; Queue/AnswerGrouping.swift:185-190 |
| Decided for you: fold, "Change my mind" | header, row button | a rule answered asks today; closed by default | Queue/QueueListView.swift:88-101; Queue/DecidedForYouView.swift:64 |
| Got it on a done row; Dismiss | button; right-click menu | done row / any row | Queue/QueueRowView.swift:81,161 |
| Retry a failed delivery | "Delivery failed · Retry" | delivery failed | Queue/QueueRowView.swift:175-181 |
| Unread team comments dot, kind icon tooltip | hover | unread > 0 | Queue/QueueRowView.swift:99,111 |
| Undo a dismiss | toast | right after a dismiss | Queue/DismissUndoToastView.swift:22 |
| Sessions popover; Settings | footer status text; gear (⌘,) | always | Queue/QueueListView.swift:482-495, 598 |

## Top bar / header
| Function | Control | When it shows | file:line |
|---|---|---|---|
| Go home | ← Home, or Esc | ask is not in Needs you | Queue/CasePaneView.swift:286-293, 692 |
| Open the project page | project crumb | always | :668-676 |
| Folder path tooltip; arrived/answered/took times | hover; meta text | always | :682, 699 |
| Share / Shared, view comments | button + sheet | sharing is available | :705; Sharing/ShareCaseView.swift:26 |
| Dismiss (confirms if the agent waits) | ⋯ menu | always | :709, 330-338 |
| Open the conversation column | speech icon with round badge, ⌘] | the ask has a thread | :718, 306; Queue/ConversationColumnView.swift:89 |
| Fold or unfold both sides | expand icon, ⌘\ | always | :722; Views/SplitFoldState.swift:105 |
| Earlier requests dropdown, "Open the history ›" | "… ▾" popover | earlier asks exist | AskDoc/EarlierAsks.swift:75-122; AskDoc/AskDocPage.swift:205 |
| Follow-up header; open the first ask | "Follow-up to: X" | `followsCaseId` is set | Queue/FollowUpHeaderView.swift:22,86 |
| "Replaces" header | text | `replacesCaseId` is set | Queue/CasePaneView.swift:884 |

## Artifact box (in the pane)
| Function | Control | When it shows | file:line |
|---|---|---|---|
| Switch artifact tabs | tab strip; tooltip shows the title | more than 1 tab | AskDoc/LiveArtifactView.swift:667; AskDoc/ArtifactHeaderParts.swift:102-117 |
| Version line "v2 · 4 min read" | text | side-by-side layout | AskDoc/LiveArtifactView.swift:679 |
| Show changes; step to previous/next change | switch, ⌃ ⌄ | write-up has more than one version | Review/WriteUpInlineView.swift:279-297 |
| Open full size / Full size, In a new window, In the browser | button + ▾ menu (browser item for pages only) | always | AskDoc/LiveArtifactView.swift:706-770 |
| Interact or Comment (C), Esc | floating toolbar, keys | box has focus and the answer is open | :585-647 |
| Flip screens of a set | ← →, thumbnails, ‹ › | screenshot set | :591; AskDoc/ScreenSetBoxView.swift:58-161 |
| Comments list, show a comment | section under the box | comments exist | AskDoc/ArtifactCommentsSection.swift:31-36 |
| Pinned bar on a stacked page: Open, choose artifact | button + menu | stacked layout with an artifact | Plan/AskArtifactLayout.swift:113-149 |
| Artifact follows the picked option | automatic | single decision | AskDoc/LiveArtifactView.swift:939-946 |
| Comment / Explain (E) on selected text | overlay on the selection | text is selected | Review/Comments/MarkdownCommentOverlays.swift:12-16 |
| Copy or save an image | right-click menu | images | Review/ImageContextMenu.swift:48 |

## Full-size review workspace
| Function | Control | file:line |
|---|---|---|
| Back | Esc (hidden button) | Review/ReviewWorkspaceView.swift:243 |
| Toggle queue / decision / both sides, leave both-folded | ⌘[ ⌘] ⌘\ Esc | :316-323 |
| Decision and Comments column tabs (with count badge) | segments | Review/ReviewColumnTabsView.swift:23-24 |
| Interact (I), Comment (C), Edit (E), Clear highlight (Esc), Open Screen (↵) | keys + toolbar | Review/ArtifactViewerView.swift:169-187, 393-441; Review/CanvasToolbarView.swift:31-33 |
| Fit ⌘0, 100% ⌘1, zoom ⌘+ / ⌘= / ⌘-, Reload ⌘R | keys + segments | Review/ArtifactViewerView.swift:191-214; Review/Comments/ScreenshotSetViews.swift:28-54 |
| One / Set; Compare switch (Side by side / Slider) | segments | Review/Comments/ScreenshotSetViews.swift:19-24; Review/Comments/CompareViews.swift:115-140 |
| Compare with vN, version chips, return to latest | buttons | Review/ArtifactViewerView.swift:504, 716 |
| Offline / Sandboxed badges, capture chip | hover labels | :560-600 |
| Comment cards: Show, Edit, Delete; inline Save | buttons | Review/Comments/CommentCardView.swift:122-138; Review/Comments/InlineCommentCardView.swift:52-60 |
| "N comments on vN · view vN", "· Show" | links | Review/AskColumnView.swift:269-293 |

## Decision area / options
| Function | Control | When it shows | file:line |
|---|---|---|---|
| Pick an option on mouse press; pick by number | row; keys 1–9 | field not focused | Composer/CalmOption.swift:386; Composer/DockShortcutsView.swift:27-32 |
| Accept the recommendation | ⌘D | no comments | :23; Composer/ComposerFooterView.swift:96 |
| Lean ◐ / Rule out × | icon buttons; tooltips "I lean to this, but I am not sure" / "Rule this out" | discuss is supported and not locked | Composer/CalmOption.swift:361-364, 17-18, 527-555 |
| Badges for good points, things to watch, effects | icon + number, each with its own tooltip; resting on one opens the row popover | the option has them | :345-347, 468-481 |
| Row tooltip popover (shows after a delay) | hover or keyboard focus | the option has detail | :397-411; Composer/OptionTipPresenter.swift:51-57 |
| ✦ Recommended pill; "Your answer" tag | pill / tag | recommended / locked | :348-357 |
| Pick-several header: "Pick up to N · x of N", "limit reached", Tick the recommended, Clear; Return sends | header + Return | multi-select | Composer/PickSeveralHeaderView.swift:16-37; Composer/DockShortcutsView.swift:34 |
| Update header "↻ Options from the update", "First options" / "Hide first options" | link | update arrived with options | Composer/ComposerCardView.swift:296-302; Composer/AnswerBoxState.swift:26-34 |
| Review hint "Pick Approve or Request changes…" | text | review with no pick | Composer/ComposerCardView.swift:177 |
| Earlier round / Earlier decision fold | Show/Hide | done note, working note, or update | Queue/DoneNote.swift:23-31; Queue/CasePaneView.swift:896-914 |
| Sources button, pills, "Show in Sources", "Open link" | buttons, Esc | the round has sources | AskDoc/SourcesViews.swift:349-658 |

## Composer and footer buttons
| Function | Control | When it shows | file:line |
|---|---|---|---|
| Send button; its label changes with state | Send, Decide, "Decide: X", "Decide with changes" / "Approve with changes" (+N comments), "Decide: N picked", Ask, Keep talking, "Lean to 1, keep talking", "Rule out 3…", Send feedback, Send comments, "+ edit"; ↵ / ⌘↵ | by state | Composer/PromptBarLogic.swift:436-490; Composer/WithChanges.swift:12-31 |
| New line | ⇧↵ | always | Composer/PromptBarLogic.swift:240-244 |
| Attach files (picker, paste, drop on the pane) | + | host has files | Composer/PromptBarView.swift:585-603, 99-101; Queue/CasePaneView.swift:253 |
| Remove an attachment; open it / show in Finder | chip ×, right-click menu | files attached | Composer/AttachmentChipsView.swift:51-130 |
| Ask for more detail; Open review; plan "Change" / "Request changes"; "More" overflow menu | quiet buttons | by host and width | Composer/PromptBarView.swift:279-287, 493-506 |
| Remove an in-place edit | "Your edit · vN …" Remove | an edit is attached | :450-466 |
| Use the suggested reply | "Use this reply" | reply-only ask, empty field | Composer/ComposerFooterView.swift:138-155 |
| Drafts kept per case | automatic | — | Composer/ComposerDraftStore.swift |
| Change answer; Open review / View review (↵ bar) | buttons | reply queued / delivered | Queue/CasePaneView.swift:594-645, 1285-1299 |

## Chips / ask for detail
| Function | Control | file:line |
|---|---|---|
| Quick replies: Let's discuss, Look at my comments (only with pinned comments), Show me more | chips | Composer/AskForDetailView.swift:9-36, 74-79 |
| Ask pills: how it works, trade-offs, prototype, screenshots, numbers, example, diagram… ; "…" opens the full panel (also ? key) | chips | :173-180, 82-90; Composer/DockShortcutsView.swift:39-42 |
| Panel: keys 1–N, Something else (inline field), Back to options (Esc), Ask (⌘↵) | keys + buttons | :294, 370-455 |

## Conversation column
| Function | Control | file:line |
|---|---|---|
| Toggle the column (overlays the page below 800 pt) | ⌘], icon | Queue/ConversationSplit.swift:12-28 |
| Copy on hover for asked, updated and replied entries | Copy / Copied | Queue/ConversationColumnView.swift:79-112; Review/CopyControls.swift:26-80 |
| "See vN" link to a prior revision | link | Queue/ConversationColumnView.swift:91 |

## Status / delivery banners
| Function | Control | file:line |
|---|---|---|
| Done strip, Got it | button | Queue/CasePaneView.swift:818-844 |
| Agent status strip, open the follow-up | button | Queue/AgentStatusStrip.swift:65 |
| Delivered ✓, Retry, copy the reply, Continue in a new session | banner | Composer/Delivery/DeliveryOutcomeBanner.swift:50-134 |
| Offline or refused reply, Retry | banner | Composer/Delivery/DeliveryBannerView.swift:115-172 |
| Session closed, Continue in a new session | notice | Queue/SessionClosed.swift:79-98 |
| Pickup fallback: Copy prompt, Nudge, Show the terminal | buttons | Queue/PickupFallback.swift:186-414 |
| Sent toast: Go back, Change answer | links | Queue/SentToastView.swift:87-97 |
| Late team comments bar | bar | Queue/CasePaneView.swift:598 |

## Plan / stepped asks
| Function | Control | file:line |
|---|---|---|
| Step pills: jump to a step | pills | AskDoc/StepDecisionViews.swift:11, 53 |
| Back / Next / Review and send | quiet buttons + pill; ↵ | Composer/PromptBarLogic.swift:357-380; AskDoc/QuestionsDocModel.swift:366-368 |
| Final step "Send your N decisions?" | review step | Queue/CasePaneView.swift:1009 |
| Plan track dots (tooltips), "See revision" / Viewing | menu | Plan/PlanViews.swift:36, 268-272 |

## Answer text box: known weak points

| Issue | Where |
|---|---|
| **Placeholder cut to one line with "…".** The layout code can detect a cut-off placeholder, but the view never passes the placeholder in, so that check never runs. | Composer/PromptBarView.swift:179-182, 240-241; Composer/PromptBarLogic.swift:109-115 |
| **Height comes from an estimate, not from the real text view.** A separate `NSLayoutManager` counts lines. The field is then fixed to that height. If the count is wrong, a wrapped second line is hidden. | Composer/PromptBarLogic.swift:45-64, 100-131; Composer/PromptBarView.swift:258 |
| **Single-row width comes from estimated control widths** (text sizes plus 8 pt slack). If the estimate is short, text wraps inside a one-line-tall field. The width never goes below 40 pt. | Composer/PromptBarLogic.swift:105, 130, 161-166; Composer/PromptBarView.swift:221 |
| **The first frame is unmeasured.** Before the bar's width is known, lines are counted by newlines only, so long text can be clipped for one frame. | Composer/PromptBarLogic.swift:106-108 |
| **Maximum height:** 6 lines in the pane, 4 in the workspace. 18 pt per line + 10 pt inset, so 118 pt in the pane. Past that the field scrolls inside itself, and the overlay scroller hides itself, so nothing shows that there is more text. | Composer/PromptBarLogic.swift:9-21, 71-75; Composer/PromptBarView.swift:24-26 |
| **Quiet buttons truncate with "…"** before the Send button gives way. Send keeps its natural width. | Composer/PromptBarView.swift:531-532, 316-317 |
| **Text set by the app replaces the whole string** ("Use this reply", evidence hooks). This can reset the caret. It is skipped while IME text is being composed. | Composer/PromptBarView.swift:62-64 |
| **"Something else" field** uses its own height rule. Its width starts at a guessed 300 pt until measured, and it also caps at 6 lines. | Composer/AskForDetailView.swift:243-245, 388-408 |
| **The dock is not inside a scroll view.** Options (capped at 420 pt, or 40–45 % of the window), chips, the 6-line field and attachment chips stack above the footer. On short windows the page scroll above gets squeezed, and the pane's `.clipped()` can cut content. The locked sent note has no line limit, so a long one grows the dock without bound. | Queue/CasePaneView.swift:244, 943, 1198; AskDoc/AskDocRules.swift:48-57; Composer/ComposerCardView.swift:228, 353-365 |
| **"First options" rows share the same capped scroll,** so opening them pushes the current options out of view. | Composer/ComposerCardView.swift:183-193 |
