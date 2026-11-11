# Request page: function check (task 12)

**How this was checked:** from the code, the unit tests and offscreen renders (`RequestPageRenderTests`). The app was not run. A pass in the running app comes after this one.

- "Before" is the place on `main` (from `FUNCTIONS.md`). "After" is the place in this branch. Paths are under `apps/macos/Sources/Knock/`.
- Proof: a render file name (from `KNOCK_RENDER_DIR=<dir> swift test --filter RequestPageRenderTests`; renders 30–50 go to the sibling `task10` folder), or a test name, or "code" when only the handler shows it.
- Status: **found** (same place and look), **changed** (moved or restyled as the spec says), **missing**, **fixed** (was missing or wrong, fixed in this pass).

Counts: 91 function rows. Found 52 · changed 38 · missing 0 · fixed 1 ("Use this reply" was in the wrong place, now in the send row).

## Sidebar

| Function | Before | After | Proof | Status |
|---|---|---|---|---|
| Hide the queue, ⌘[ | QueueListView.swift:397; SplitFoldState.swift:128 | Sidebar fold button, QueueListView.swift:397; key MainWindowView.swift:85, SplitFoldState.swift:128 | SplitFoldTests | found |
| Show the queue again (rail "N Needs you") | SplitFoldControls.swift:196-223 | Rail, SplitFoldControls.swift:188-223; MainWindowView.swift:63 | SplitFoldTests | found |
| ↑/↓, j/k, ↵, ⌘⌫ in the list | QueueListView.swift:152-188 | Same, QueueListView.swift:152-171 | AppModelTests | found |
| Open from Working / In planning | SidebarSections.swift:193-210 | Row click, SidebarSections.swift:240, 251 | WorkingFoldTests | found |
| Working fold "› WORKING · N" (new, C11) | none | SidebarSections.swift:218-232; key `queueWorkingGroupOpen` AnswerGrouping.swift:200 | WorkingFoldTests.theWorkingGroupIsClosedByDefaultAndRemembersTheChoice | changed |
| Answered fold | QueueListView.swift:406; AnswerGrouping.swift:185-190 | Same, QueueListView.swift:406; AnswerGrouping.swift:186 | AnswerGroupingTests; WorkingFoldTests.theWorkingKeyIsItsOwnAndNeverFollowsAnswered | found |
| Decided for you fold, "Change my mind" | QueueListView.swift:88-101; DecidedForYouView.swift:64 | Same, QueueListView.swift:90; DecidedForYouView.swift:6, 19 | WAG412Tests | found |
| Got it on a done row; Dismiss | QueueRowView.swift:81, 161 | Same, QueueRowView.swift:82, 162 | DoneCaseTests | found |
| Retry a failed delivery on the row | QueueRowView.swift:175-181 | Same | code | found |
| Unread comments dot, kind icon tooltip | QueueRowView.swift:99, 111 | Same | code | found |
| Undo a dismiss | DismissUndoToastView.swift:22 | Same, DismissUndoToastView.swift:18 | AppModelTests | found |
| Sessions popover; Settings (⌘,) | QueueListView.swift:482-495, 598 | QueueListView.swift:465-470, 501; ⌘, from the Settings scene, KnockApp.swift:158 | SessionActivityTests | found |
| Drag the sidebar border, double click resets (new, task 13a) | none (fixed 300 pt) | Views/PaneBorders.swift; MainWindowView.swift (handle on the sidebar's right line) | PaneBordersTests | changed |
| Drag the decision column border, double click resets (new, task 13a) | none (fixed 440 pt) | Views/PaneBorders.swift; CasePaneView.swift (handle on the column's left line); Plan/AskArtifactLayout.swift | PaneBordersTests | changed |

## Top bar and context line

| Function | Before | After | Proof | Status |
|---|---|---|---|---|
| Go home: ← Home, Esc | CasePaneView.swift:286-293, 692 | Top bar, CasePaneView.swift:656; Esc catcher :278-286 | HomeExpansionTests; render 1-text-only | found |
| Project crumb opens the project page | CasePaneView.swift:668-676 | Top bar, CasePaneView.swift:629-637 | WAG302HeaderTests; render 1-text-only | found |
| Folder tooltip; arrived / answered / took times | CasePaneView.swift:682, 699 | Top bar, CasePaneView.swift:645, 662 | WAG333CasePageTests; render 1-text-only | found |
| Share / Shared, view comments | CasePaneView.swift:705 | Top bar, CasePaneView.swift:668 | WAG392Tests | found |
| Dismiss (confirms if the agent waits) | CasePaneView.swift:709, 330-338 | ⋯ last in the top bar, CasePaneView.swift:681; dialog :323-330 | CaseDisplayTests | changed |
| Conversation icon with round badge, ⌘] | CasePaneView.swift:718, 306; ConversationColumnView.swift:89 | Top bar icon opens the Conversation tab, CasePaneView.swift:672; ⌘] :300; ConversationTab.swift:516 | ConversationTabTests.commandBracketOpensConversationThenGoesBackToDecision | changed |
| Fold both sides, ⌘\ | CasePaneView.swift:722; SplitFoldState.swift:105 | Top bar, CasePaneView.swift:675; key MainWindowView.swift:92, SplitFoldState.swift:130 | SplitFoldTests | found |
| Earlier requests ▾, "Open the history ›" | EarlierAsks.swift:75-122; AskDocPage.swift:205 | Top of the Conversation tab, ConversationTab.swift:412-454 | EarlierAsksTests; render 22-conversation-tab | changed |
| Follow-up header, open the first ask | FollowUpHeaderView.swift:22, 86 | Context line "↳ Follow-up to X", RequestContextLine.swift:32, 208 | ContextLineTests.aFollowUpHoldsTheLinkToTheEarlierAsk; render 10-plan-follow-up | changed |
| "Replaces" header | CasePaneView.swift:884 | Context line "Replaces X", RequestContextLine.swift:33 | ContextLineTests.aReplaceHoldsTheReplacedAsk | changed |

## Artifact box (pane)

| Function | Before | After | Proof | Status |
|---|---|---|---|---|
| Artifact tabs, title tooltip | LiveArtifactView.swift:667; ArtifactHeaderParts.swift:102-117 | Same, LiveArtifactView.swift:668; ArtifactHeaderParts.swift:76-117 | WAG382Tests | found |
| Version line "v2 · 4 min read" | LiveArtifactView.swift:679 | Same, LiveArtifactView.swift:679, 697 | render 2-artifact | found |
| Show changes, ⌃ ⌄ | WriteUpInlineView.swift:279-297 | Same | WriteUpInlineCommentTests | found |
| Open full size, new window, browser | LiveArtifactView.swift:706-770 | Same, LiveArtifactView.swift:705-759 | AskDocRulesTests; render 2-artifact | found |
| Interact / Comment (C), Esc | LiveArtifactView.swift:585-647 | Same, keys LiveArtifactView.swift:585-590 | WAG311Tests | found |
| Screen set ← →, thumbnails, ‹ › | LiveArtifactView.swift:591; ScreenSetBoxView.swift:58-161 | Same, LiveArtifactView.swift:591-592; ScreenSetBoxView.swift:39, 58 | WAG323Tests | found |
| Comments under the box | ArtifactCommentsSection.swift:31-36 | Comments tab, CasePaneView.swift:509-528 | render 24-comments-tab-pane | changed |
| Pinned bar on a narrow page: Open, choose artifact | AskArtifactLayout.swift:113-149 | Top of the column, CasePaneView.swift:447, 931; AskArtifactLayout.swift:113-170 | WAG333CasePageTests; render 3-narrow-pane | changed |
| Artifact follows the picked option | LiveArtifactView.swift:939-946 | CasePaneView.swift:267-269, 339 | WAG352Tests | found |
| Comment / Explain (E) on a selection | MarkdownCommentOverlays.swift:12-16 | Same; E key CommentableMarkdownView.swift:475, AskCommentTextView.swift:362 | code | found |
| Copy / save an image | ImageContextMenu.swift:48 | Same, ImageContextMenu.swift:8-9, 47 | code | found |

## Full size

| Function | Before | After | Proof | Status |
|---|---|---|---|---|
| Back (Esc) | ReviewWorkspaceView.swift:243 | ReviewWorkspaceView.swift:247-248 | code | found |
| ⌘[ ⌘] ⌘\ Esc (fold queue, column, both, leave) | ReviewWorkspaceView.swift:316-323 | ReviewWorkspaceView.swift:326-332 | SplitFoldTests | found |
| Column tabs (Decision, Comments with count) | ReviewColumnTabsView.swift:23-24 | Decision · Conversation · Comments, ReviewColumnTabsView.swift:20-22 | render 25-comments-tab-full-size, 26-conversation-tab-full-size | changed |
| Column width 440 → 340 pt to keep 60 % artifact (C9) | fixed column | AskLayout.fullSizeColumnWidth | FullSizeLayoutTests; render 27-full-size-* | changed |
| I, C, E, Esc, ↵ | ArtifactViewerView.swift:169-187 | Same, ArtifactViewerView.swift:170-187 | WAG374Tests | found |
| Fit ⌘0, 100% ⌘1, zoom ⌘+ ⌘= ⌘-, Reload ⌘R | ArtifactViewerView.swift:191-214; ScreenshotSetViews.swift:28-54 | Same, ArtifactViewerView.swift:192-214; ScreenshotSetViews.swift:28-45 | PrototypeZoomTests | found |
| One / Set | ScreenshotSetViews.swift:19-24 | Segmented switch, ScreenshotSetViews.swift:19-20 | render 28-full-size-toolbar-switches | changed |
| Compare (Side by side / Slider) | CompareViews.swift:115-140 | One segmented switch Off · Side by side · Slider, CompareViews.swift:92-133 | FullSizeLayoutTests.compareIsOneSwitchOffSideBySideSlider; render 28 | changed |
| Compare with vN, version chips, return to latest | ArtifactViewerView.swift:504, 716 | Same, ArtifactViewerView.swift:471-505, 716 | ReviewViewModelTests | found |
| Offline / Sandboxed badges, capture chip | ArtifactViewerView.swift:560-600 | Same, ArtifactViewerView.swift:547-583 | IsolationTests | found |
| Comment cards: Show, Edit, Delete, inline Save | CommentCardView.swift:122-138; InlineCommentCardView.swift:52-60 | Same, CommentCardView.swift:123-132; InlineCommentCardView.swift:52-60; also in the pane's Comments tab | CommentFlatListTests; render 24, 25 | found |
| "N comments on vN · view vN", "· Show" | AskColumnView.swift:269-293 | Comments tab, ArtifactCommentsSection.swift:43-52; AskColumnView.swift:283 | ConversationTabTests.priorRevisionLinkWords | changed |

## Options

| Function | Before | After | Proof | Status |
|---|---|---|---|---|
| Pick on mouse press; keys 1–9 | CalmOption.swift:386; DockShortcutsView.swift:27-32 | Same, CalmOption.swift:437, 567; DockShortcutsView.swift:27-32 | ComposerViewModelTests | found |
| ⌘D accepts the recommendation | DockShortcutsView.swift:23; ComposerFooterView.swift:96 | DockShortcutsView.swift:24; ComposerFooterView.swift:91 | SendFlowControllerTests | found |
| Lean ◐ / Rule out ×, tooltips | CalmOption.swift:361-364, 17-18, 527-555 | Always visible; on hover only on a narrow one-line row, CalmOption.swift:17-18, 420, 489-501, 686 | RequestPageOptionsTests (6 tests); render 12, 13, 14, 14a, 14b | changed |
| Pro / con / effect counts, each with a tooltip | CalmOption.swift:345-347, 468-481 | Always visible, CalmOption.swift:398-400 | render 1-text-only, 12-rows-wide-440 | found |
| Row popover on hover and keyboard focus | CalmOption.swift:397-411; OptionTipPresenter.swift:51-57 | Same, CalmOption.swift:439, 460; OptionTipPresenter.swift:10 | code | found |
| ✦ Recommended pill; "Your answer" tag | CalmOption.swift:348-357 | Same, CalmOption.swift:402-410 | render 1-text-only, 30-sent-waiting-with-menu | found |
| Pick-several header; Return sends | PickSeveralHeaderView.swift:16-37; DockShortcutsView.swift:34 | Same, PickSeveralHeaderView.swift:20-32; DockShortcutsView.swift:36 | MultiSelectTests; render 9-pick-several, 9b-pick-several-two-picked | found |
| "↻ Options from the update", "First options" | ComposerCardView.swift:296-302; AnswerBoxState.swift:26-34 | One line, first options in their own fold, ComposerCardView.swift:160, 307; AnswerBoxState.swift:27-34 | AnswerBoxStateTests; render 15-update-first-folded, 16-update-first-open | changed |
| Review hint "Pick Approve or Request changes…" | ComposerCardView.swift:177 | Same, ComposerCardView.swift:200; PromptBarLogic.swift:352 | ReviewRowsTests; render 7-review | found |
| Earlier round / earlier decision fold | DoneNote.swift:23-31; CasePaneView.swift:896-914 | "You chose X · Show", DoneNote.swift:14-16; CasePaneView.swift:789-813 | ContextLineTests.aPickReadsYouChoseItsTitle | changed |
| Sources button, pills, "Show in Sources", "Open link" | SourcesViews.swift:349-658 | Same, SourcesViews.swift:350, 447, 489-499 | WAG363LoopTests, WAG365LoopTests | found |

## Answer box and send row

| Function | Before | After | Proof | Status |
|---|---|---|---|---|
| Send labels (Decide, "Decide: X", with changes, "Decide: N picked", Ask, Keep talking, Lean to…, Rule out…, Send feedback, Send comments, + edit); ↵ / ⌘↵ | PromptBarLogic.swift:436-490; WithChanges.swift:12-31 | Same, PromptBarLogic.swift:340, 426-445, 511; WithChanges.swift:12-13; ⌘↵ ComposerFooterView.swift:96, DockShortcutsView.swift:26 | PromptBarLogicTests, ApproveWithChangesTests; render 9b ("Decide: 2 picked") | found |
| New line ⇧↵ | PromptBarLogic.swift:240-244 | PromptBarLogic.swift:278-280; PromptBarView.swift:240 | PromptBarLogicTests | found |
| Attach: +, paste, drop on the pane | PromptBarView.swift:585-603, 99-101; CasePaneView.swift:253 | PromptBarView.swift:207, 423, 805; drop CasePaneView.swift:246; picker AttachmentChipsView.swift:212 | ComposerAttachmentsTests | found |
| Attachment chip ×, Open, Show in Finder | AttachmentChipsView.swift:51-130 | Same, AttachmentChipsView.swift:52, 127-128 | ComposerAttachmentsTests | found |
| Quiet buttons, "More" overflow, never cut | PromptBarView.swift:279-287, 493-506 | PromptBarView.swift:430-437, 682-712 | PromptBarFieldSizingTests.measuredLabelsWiderThanTheEstimateMoveQuietButtonsIntoMore | changed |
| "Ask for more detail" quiet button | PromptBarView.swift:279-287 | Replaced by "Ask for…" at the left of the send row, PromptBarView.swift:344 | RequestPageOptionsTests.theOldQuietDetailButtonIsGone; render 1-text-only | changed |
| Open review (quiet button, review asks) | PromptBarView.swift:279-287 | Send row, PromptBarLogic.swift:318; PromptBarView.swift:656-657 | render 7-review | found |
| Plan "Change" / "Request changes" | PromptBarView.swift:279-287 | Send row, PromptBarView.swift:662-665 | WAG305Tests | found |
| Remove an in-place edit | PromptBarView.swift:450-466 | Same, under the field, PromptBarView.swift:566, 610 | DocumentEditTests | found |
| "Use this reply" | ComposerFooterView.swift:138-155 (button in the suggested-reply card) | Quiet button in the send row while the field is empty, PromptBarLogic.swift:320-327; PromptBarView.swift:659-661; the card keeps the text and why, ComposerFooterView.swift:59, 137 | WAG336Tests.useThisReplyIsTheLastQuietButtonOfTheSendRow; render 8-reply-only, 8b-reply-only-artifact | fixed |
| Drafts per case | ComposerDraftStore.swift | Same, ComposerDraftStore.swift:11, 45 | PrePickTests | found |
| Change answer; Open / View review | CasePaneView.swift:594-645, 1285-1299 | Status line buttons, RequestStatus.swift:14-25, 226-227, 157; wired CasePaneView.swift:752-768 | RequestStatusTests.sentWaitsWithChangeAnswerAndTheFallbackMenu; render 30, 31-sent-review-open-review | changed |
| Answer box height from the real text view | PromptBarLogic.swift:45-64, 100-131 | Measured from the field's layout manager | PromptBarFieldSizingTests (13 tests) | changed |

## Ask for…

| Function | Before | After | Proof | Status |
|---|---|---|---|---|
| Quick replies: Let's discuss, Look at my comments, Show me more | AskForDetailView.swift:9-36, 74-79 | In the "Ask for…" panel, AskForDetailView.swift:9-20 | RequestPageOptionsTests.theQuickRepliesStayInThePanel; render 17-ask-for-open-short | changed |
| Ask pills; "…" and ? open the panel | AskForDetailView.swift:173-180, 82-90; DockShortcutsView.swift:39-42 | Panel rows, AskForDetailView.swift:144-146; "Ask for…" button PromptBarView.swift:344; ? DockShortcutsView.swift:40-42 | RequestPageOptionsTests.thePanelListsEveryPillOfTheOldRow | changed |
| Panel keys 1–N, Something else, Esc back, ⌘↵ Ask | AskForDetailView.swift:294, 370-455 | Same, AskForDetailView.swift:376, 450-459 | RequestPageOptionsTests.eachPanelRowHasItsOwnKey; render 17–20 | found |

## Conversation

| Function | Before | After | Proof | Status |
|---|---|---|---|---|
| Toggle the column (overlay under 800 pt) | ConversationSplit.swift:12-28 | Conversation tab; the 380 pt column is gone, CasePaneView.swift:477-505 | ConversationTabTests; render 22, 23 | changed |
| Copy on hover (asked, updated, replied) | ConversationColumnView.swift:79-112; CopyControls.swift:26-80 | Message actions on hover, ConversationTab.swift:316-318 | render 22-conversation-tab (actions shown) | changed |
| "See vN" link | ConversationColumnView.swift:91 | Message action, ConversationTab.swift:80, 250 | ConversationTabTests | changed |
| Latest agent line above the tabs, dot on Conversation (new, C8) | none | ConversationTab.swift:543 | ConversationTabTests.latestLineShowsTheNewestAgentMessageOffTheConversationTab; render 21 | changed |

## Status

| Function | Before | After | Proof | Status |
|---|---|---|---|---|
| Done strip, Got it | CasePaneView.swift:818-844 | Status line "Done" · Got it, RequestStatus.swift:135-137 | RequestStatusTests.doneHasGotIt; render 38-done-got-it | changed |
| Agent status strip, open the follow-up | AgentStatusStrip.swift:65 | Status line, RequestStatus.swift:211-250 | RequestStatusTests.aSettledAnswerOpensItsFollowUp; render 32, 48 | changed |
| Delivered ✓, Retry, copy the reply, Continue in a new session | DeliveryOutcomeBanner.swift:50-134 | Status line, RequestStatus.swift:154-158 (delivered), 196-207 (not delivered; saved, with Copy answer and Continue) | RequestStatusTests.aDeliveredAnswerSaysDelivered, notDeliveredIsRedWithItsReasonRetryAndHide; render 33-delivered, 36-not-delivered-light, 37-saved-session-ended | changed |
| Offline or refused reply, Retry | DeliveryBannerView.swift:115-172 | Status line, RequestStatus.swift:181-191 | RequestStatusTests.refusedKeepsTheServicesReasonInFull, notSentWhileTheServiceIsOffline; render 39-offline, 44–46 | changed |
| Session closed, Continue in a new session | SessionClosed.swift:79-98 | Status line, RequestStatus.swift:143-146 | RequestStatusTests.aClosedSessionBeforeTheAnswerOffersANewSession; render 34, 35 | changed |
| Pickup fallback: Copy prompt, Nudge, Show the terminal | PickupFallback.swift:186-414 | ⋯ of the status line, PickupFallback.swift:293-310; RequestStatus.swift:382 | PickupFallbackTests; render 30-sent-waiting-with-menu | changed |
| Sent toast: Go back, Change answer (5 s) | SentToastView.swift:87-97 | Same, SentToastView.swift:7, 87-97 | AppModelTests | found |
| Late team comments bar | CasePaneView.swift:598 | Comments tab, CasePaneView.swift:515; dot on the tab | WAG401Tests; ConversationTabTests.commentsDotShowsUnreadOrLateCommentsUntilTheTabIsOpened | changed |
| Failed line contrast ≥ 4.5:1 | banner | RequestStatus.swift (statusFailedText) | RequestStatusTests.theFailedTextReadsAtFourPointFiveToOneInLightAndDark; render 42, 43 | changed |

## Plan and stepped asks

| Function | Before | After | Proof | Status |
|---|---|---|---|---|
| Step pills: jump to a step | StepDecisionViews.swift:11, 53 | Step numbers 1 · 2 · Send with title tooltips, StepDecisionViews.swift:12-14 | ContextLineTests.theStepBarShowsNumbersWithTheFullTitleInTheTooltip; render 6-stepped | changed |
| Back / Next / Review and send; ↵ | PromptBarLogic.swift:357-380; QuestionsDocModel.swift:366-368 | Same, PromptBarLogic.swift:394-412 | WAG305Tests, ItemsViewTests | found |
| Final step "Send your N decisions?" | CasePaneView.swift:1009 | Same, CasePaneView.swift:908 | QuestionsDocModelTests | found |
| Plan track dots (tooltips), "See revision" / Viewing | PlanViews.swift:36, 268-272 | Context line, words with ✓, RequestContextLine.swift:248-287 | ContextLineTests.eachStageWordSaysMoreInItsTooltip, aPlanFollowUpHoldsTheLinkAndTheTrackOnOneLine; render 10-plan-follow-up | changed |

## Answer box weak points (FUNCTIONS.md, last section)

| Weak point | Before | Now | Proof | Status |
|---|---|---|---|---|
| Placeholder cut with "…" | PromptBarView.swift:179-182, 240-241 | Wraps | render 7-review (own row); PromptBarFieldSizingTests | changed |
| Height from an estimate | PromptBarLogic.swift:45-64, 100-131 | From the field's layout manager | PromptBarFieldSizingTests.aWidthChangeMeasuresAgain | changed |
| Single-row width from estimated controls | PromptBarLogic.swift:105, 130, 161-166 | Measured labels; field takes its own row when the text needs it | PromptBarFieldSizingTests.theFieldMovesToItsOwnRowOnlyWhenTheTextNeedsTheWidth | changed |
| First frame unmeasured | PromptBarLogic.swift:106-108 | Every line on the first frame | PromptBarFieldSizingTests.aLongTextShowsEveryLineOnTheFirstFrame | changed |
| 6-line cap, hidden scroller | PromptBarLogic.swift:9-21, 71-75 | 40 % of the column, at least 6 lines, scroller visible | PromptBarFieldSizingTests.fortyLinesAreCappedAt40PercentAndScroll | changed |
| Quiet buttons cut with "…" | PromptBarView.swift:531-532, 316-317 | Into "More", never cut | PromptBarFieldSizingTests.measuredLabelsWiderThanTheEstimateMoveQuietButtonsIntoMore | changed |
| App-set text resets the caret | PromptBarView.swift:62-64 | Caret at the end | PromptBarFieldSizingTests.textSetByTheAppLeavesTheCaretAtTheEnd | changed |
| "Something else" own height rule | AskForDetailView.swift:243-245, 388-408 | Same field as the answer box | RequestPageOptionsTests; render 17 | changed |
| Dock not in a scroll; `.clipped()` cuts | CasePaneView.swift:244, 943, 1198 | Column scrolls as one, send row pinned | render 4-short-window, 5-short-text-only | changed |
| First options share the capped scroll | ComposerCardView.swift:183-193 | Own fold | render 16-update-first-open | changed |

The weak-point rows are not counted above (they are fixes, not functions).

**Chrome pass (2026-11-10, STYLE-AUDIT.md §6):** the sidebar, the top bar, the page header and the artifact card took the mockups' look. Every Sidebar and Top bar row above is still there, so the count stays 0 missing. Moved, not removed: on the page with no artifact the project crumb (it still opens the project page) and the arrived / answered / took times are in the eyebrow over the title, and "waiting Nm" is a pill at the right of the bar in both layouts; the Answered rows' age is in their meta line ("you → B · 16m ago"). Proof: renders `60-window-no-artifact-1440x900`, `61-window-artifact-1600x758`; the full suite.
