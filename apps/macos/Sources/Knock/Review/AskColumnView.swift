import SwiftUI

/// The review workspace's right column (docs/design/mvp-values.md §M4
/// `MYn95` → `O2LGd`, fixed width 430pt): the ask — title, the context card,
/// need and why, and the decision card (HAIL-107) — plus the docked answer box
/// (docs/design/mvp-values.md §M7 panels A/B).
struct AskColumnView: View {
    let knockCase: Case
    /// The rounds of a plan ask (HAIL-151); `nil` for any other ask.
    var planRounds: [PlanRound]? = nil
    /// The case's messages, for the agent's full text (WAG-393); the case row holds a cut preview.
    var messages: [Message] = []
    @ObservedObject var composer: ComposerViewModel
    @ObservedObject var sendFlow: SendFlowController
    let commentCount: Int
    /// How many captures this session's comments are spread across (HAIL-35
    /// contract: "N comments on M captures · Show"). `0` when `commentCount`
    /// is `0` — the summary line never shows either way.
    var captureCount: Int = 0
    /// Non-nil for a case whose latest revision just arrived (docs/design/
    /// mvp-values.md §M9): swaps the WHY block for the agent's Thread
    /// message and the prior-revision link, and the composer's placeholder.
    var revisionArrival: RevisionArrival? = nil
    /// `AppModel.now`, for the Thread message's relative timestamp.
    var now: Date = Date()
    /// The ask's thread (HAIL-68), the same one the pane shows. It carries the
    /// agent's update in full, so the M9 Thread message below is left out when it shows.
    var thread: (model: ThreadModel, turn: ThreadTurn)? = nil
    var onViewPriorRevision: () -> Void = {}
    /// "See vN" in a plan's answered history (HAIL-156), and the revision shown read-only now.
    var onSeePlanRevision: ((Int) -> Void)? = nil
    var viewingRevision: Int? = nil
    /// "Show": `ReviewViewModel.showExistingComments()` (HAIL-35 contract) -
    /// enters Comment mode on the latest capture without freezing a new one.
    var onShowComments: () -> Void = {}
    /// The client to fetch a followed-ask's title/recap with, and where to
    /// send its "open" tap (HAIL-33 amendment). `nil` keeps every existing
    /// call site - and every pre-HAIL-33 test - compiling unchanged; a
    /// `nil` client simply never shows the follow-up header.
    var client: KnockClient? = nil
    var onOpenCase: (String) -> Void = { _ in }
    /// The session line and the earlier asks (HAIL-102), rows of the context card. `nil` shows neither.
    var sessionContext: SessionContextBlock? = nil
    /// The right column's Question | Comments switch (HAIL-56 contract).
    let tab: ReviewColumnTab
    var onSelectTab: (ReviewColumnTab) -> Void = { _ in }
    /// The one page's answer area once the answer is sent (HAIL-86): replaces the composer and
    /// the Question | Comments switch, and the question above stays.
    var sentCard: AnyView? = nil
    /// The menu of earlier asks over the title. The crumb text is in the titlebar (WAG-302).
    var earlierAsks: EarlierAsksModel? = nil
    /// The crumb text over the title, "Project · session title" (WAG-309). `nil` shows none.
    var crumb: String? = nil
    /// The folder path, as a hover tip on the crumb.
    var crumbHelp: String? = nil
    /// The answers of an ask with questions (WAG-305): the same controller the case pane uses.
    /// `nil` for an ask without questions.
    var askDoc: AskDocController? = nil
    /// The sharing state of the case (WAG-387). The team's comments show when there are any.
    var shared: SharingModel? = nil

    /// The need, the revision thread, the questions and the pick of the round (folded under a message-only update, WAG-337).
    @ViewBuilder
    private var roundBody: some View {
        // A returned revision shows the agent's message where Why would be (docs/design/mvp-values.md §M9).
        VStack(alignment: .leading, spacing: 12) {
            // The questions branch shows the need once, on its first step.
            if !hidesNeedForSteps {
                NeedCalloutView(
                    need: knockCase.displayNeed(planRounds: planRounds),
                    why: revisionArrival == nil ? knockCase.currentWhy : nil,
                    isCompact: true,
                    labelAbove: knockCase.plan.map { PlanText.progressLabel($0.stage) })
            }

            if let revisionArrival {
                threadSection(revisionArrival)
            }

            // An ask with questions: the steps, one question at a time, as in the case pane (WAG-305).
            if let askDoc, askDoc.doc != nil, AskPanelLayout.showsQuestions(knockCase) {
                AskColumnQuestionsBody(knockCase: knockCase, askDoc: askDoc)
            }

            if let instruction = knockCase.roundHeading?.instruction {
                RoundInstructionView(text: instruction)
            }

            // The pick, or before a pick the recommendation: the same block as the case pane (WAG-303).
            if AskPanelLayout.showsPickBlock(knockCase) {
                DecisionPickBlockView(composer: composer, columns: AskPanelLayout.blockColumns)
            }
            SourcesButtonSlot()
        }
        .coachMarkAnchor(.options)
    }

    /// The message-only update with the agent's full text (WAG-393).
    private var messageNote: MessageOnlyUpdate? {
        knockCase.messageOnlyUpdate?.fullText(from: messages, after: knockCase.latestReplyAtDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if sentCard == nil {
                        ReviewColumnTabsView(tab: tab, commentCount: commentCount, onSelect: onSelectTab)
                    }
                    if let followsCaseId = knockCase.followsCaseId, let client {
                        FollowUpHeaderView(followsCaseId: followsCaseId, client: client, onOpen: onOpenCase)
                    }
                    if let replacesCaseId = knockCase.replacesCaseId, let client {
                        ReplacesHeaderView(replacesCaseId: replacesCaseId, client: client)
                    }
                    // A plan ask: the stage track, the progress line and the folded answers (HAIL-151).
                    if let plan = knockCase.plan {
                        PlanColumnHeaderView(
                            plan: plan, rounds: planRounds ?? [], viewingRevision: viewingRevision,
                            onSeeRevision: onSeePlanRevision)
                    }
                    // The same header as the case page (WAG-333): the crumb, then the title, once. A stepped
                    // ask shows each question as its title.
                    AskCrumbLine(
                        crumb: crumb, help: crumbHelp, earlierAsks: earlierAsks, onOpenCase: onOpenCase, onOpenHistory: nil)
                    if let note = knockCase.workingNoteText {
                        WorkingNoteLine(note: note)
                    } else if let update = messageNote {
                        LatestMessageNote(note: update, width: .narrow)
                    } else if AskCrumbs.showsCaseTitle(doc: askDoc?.doc) {
                        AskTitleView(heading: knockCase.roundHeading, title: knockCase.title, width: .narrow)
                    }

                    commentsSummaryLine

                    if let shared { TeamCountLine(model: shared) { onSelectTab(.comments) } }

                    if knockCase.workingNoteText != nil || messageNote?.staysLive == false {
                        EarlierDecisionFold(title: "Earlier round") { roundBody }
                    } else {
                        roundBody
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { EvidenceLayoutLog.event("ask.contentHeight", "old=\(scrollContentHeight) new=\($0)"); scrollContentHeight = $0 }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { EvidenceLayoutLog.event("ask.viewportHeight", "old=\(scrollViewportHeight) new=\($0)"); scrollViewportHeight = $0 }
            .overlay(alignment: .bottom) {
                // Content runs under the dock: a soft fade says there is more (WAG-303, audit F3).
                if AskPanelLayout.showsBottomFade(contentHeight: scrollContentHeight, viewportHeight: scrollViewportHeight) {
                    LinearGradient(colors: [Theme.Colors.win.opacity(0), Theme.Colors.win], startPoint: .top, endPoint: .bottom)
                        .frame(height: AskPanelLayout.fadeHeight)
                        .allowsHitTesting(false)
                }
            }
            if let sentCard {
                sentCard.padding(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16))
            } else {
                composerFooter
            }
        }
        .frame(minWidth: 340, idealWidth: 430, maxWidth: 430)
        .frame(width: Self.evidenceColumnWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.Colors.win)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { EvidenceLayoutLog.event("ask.columnHeight", "old=\(columnHeight) new=\($0)"); columnHeight = $0 }
        // Files dropped on the request attach to the reply (WAG-345).
        .attachesDroppedFiles(to: composer.files)
    }

    /// A stepped ask shows its need on its first step, inside the questions branch.
    private var hidesNeedForSteps: Bool { askDoc?.doc?.isStepped == true && AskPanelLayout.showsQuestions(knockCase) }

    @State private var scrollContentHeight: CGFloat = 0
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var columnHeight: CGFloat = 800

    /// `KNOCK_EVIDENCE_ASK_COLUMN_WIDTH=<points>` (HAIL-157 evidence only): pins the column to a width so
    /// a capture can show the plan track at several widths. Nil, so no effect, when unset.
    private static let evidenceColumnWidth: CGFloat? = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_ASK_COLUMN_WIDTH"]
        .flatMap(Double.init).map { CGFloat($0) }

    /// The unified composer card (docs/stories/HAIL-54.md) for an options
    /// ask, or the plain `ComposerFooterView` for a free-text one - the same
    /// split the case pane makes. `AskColumnView` only ever renders this
    /// editable; `AnsweredAskColumnView` covers the locked/answered display
    /// once `ReviewWorkspaceView.rightColumnKind` resolves to
    /// `.answeredRecap`, so `ComposerCardView` never needs `isLocked: true`
    /// here.
    @ViewBuilder
    private var composerFooter: some View {
        if let askDoc, AskPanelLayout.showsQuestions(knockCase) {
            AskColumnQuestionsDock(askDoc: askDoc, sendFlow: sendFlow, columnHeight: columnHeight)
        } else if knockCase.options.isEmpty || knockCase.earlierRoundIsReadOnly {
            ComposerFooterView(
                composer: composer,
                sendFlow: sendFlow,
                deliveryState: sendFlow.deliveryState,
                commentCount: commentCount,
                placeholder: PromptBarLogic.placeholder(for: .reply, hasRevision: revisionArrival != nil),
                maxReplyLines: PromptBarLogic.workspaceMaxLines
            )
        } else {
            ComposerCardView(
                composer: composer,
                sendFlow: sendFlow,
                deliveryState: sendFlow.deliveryState,
                recommendationId: knockCase.recommendation,
                commentCount: commentCount,
                placeholder: PromptBarLogic.placeholder(for: .decide, hasRevision: revisionArrival != nil),
                maxOptionsHeight: AskPanelLayout.dockCap(columnHeight: columnHeight),
                maxReplyLines: PromptBarLogic.workspaceMaxLines,
                showsFullOptions: true,
                fullLabelOnlyWhenSelected: true
            )
        }
    }

    /// docs/design/mvp-values.md §M9 `xAVpQ`: the agent's own message from
    /// the update that returned this revision, plus (when the prior revision
    /// has any) the link back to its comments.
    @ViewBuilder
    private func threadSection(_ arrival: RevisionArrival) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if thread == nil, let message = arrival.agentMessage {
                agentMessageBubble(message)
            }
            if arrival.priorCommentCount > 0 {
                priorRevisionLink(arrival)
            }
        }
    }

    private func agentMessageBubble(_ message: Message) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Theme.Colors.side)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "cpu")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Colors.ink2)
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Claude Code")
                        .knockTextStyle(Theme.Typography.threadAuthor12_5w600)
                        .foregroundColor(Theme.Colors.ink)
                    Text(KnockDateFormat.relativeShort(from: message.createdAtDate ?? now, now: now))
                        .knockTextStyle(Theme.Typography.threadTimestamp11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
                Text(message.text)
                    .knockTextStyle(Theme.Typography.threadMessageBody13w400)
                    .foregroundColor(Theme.Colors.ink)
            }
        }
    }

    /// "`<k> comments on v<n-1>` · view v<n-1>" (docs/design/mvp-values.md
    /// §M9 `E0OSB`): switches the artifact viewer to that revision,
    /// read-only.
    private func priorRevisionLink(_ arrival: RevisionArrival) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 12))
                .foregroundColor(Theme.Colors.ink3)
            Text("\(arrival.priorCommentCount) comment\(arrival.priorCommentCount == 1 ? "" : "s") on v\(arrival.priorRevision) · view v\(arrival.priorRevision)")
                .knockTextStyle(Theme.Typography.priorRevisionLink12w500)
                .foregroundColor(Theme.Colors.ink2)
        }
        .padding(.leading, 32)
        .contentShape(Rectangle())
        .onTapGesture(perform: onViewPriorRevision).pointerCursor()
    }

    /// "N comments on M captures · Show" (HAIL-35 contract), only while
    /// there is anything to show - a case with no comments yet has nothing
    /// this line would usefully say.
    @ViewBuilder
    private var commentsSummaryLine: some View {
        if let prefix = Self.commentsSummaryPrefix(commentCount: commentCount, captureCount: captureCount) {
            HStack(spacing: 6) {
                Text(prefix)
                    .knockTextStyle(Theme.Typography.priorRevisionLink12w500)
                    .foregroundColor(Theme.Colors.ink2)
                Text("· Show")
                    .knockTextStyle(Theme.Typography.priorRevisionLink12w500)
                    .foregroundColor(Theme.Colors.accent)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onShowComments).pointerCursor()
        }
    }

    /// Pure text for `commentsSummaryLine` - unit-tested without hosting the
    /// view (same pattern as `ReviewWorkspaceView.rightColumnKind`). `nil`
    /// hides the line entirely.
    static func commentsSummaryPrefix(commentCount: Int, captureCount: Int) -> String? {
        guard commentCount > 0 else { return nil }
        // Comments on the text of an explanation (HAIL-150) have no capture to count.
        if captureCount == 0 { return "\(commentCount) comment\(commentCount == 1 ? "" : "s")" }
        return "\(commentCount) comment\(commentCount == 1 ? "" : "s") on \(captureCount) capture\(captureCount == 1 ? "" : "s")"
    }
}

/// What the review panel's Decision tab holds (WAG-276). The options are not part of it: they sit once, as
/// the dock rows below the doc.
enum AskPanelLayout {
    enum Part: Equatable { case crumb, title, need, why, pickedPoints }

    /// The parts of the Decision tab's doc, top to bottom. There is no Context box, no Need and Why cards
    /// and no list of options: the options are the dock rows, shown once.
    static func parts(for knockCase: Case, picked: Option?, hasCrumb: Bool = true) -> [Part] {
        var parts: [Part] = []
        if knockCase.plan == nil {
            if hasCrumb { parts.append(.crumb) }
            parts.append(.title)
        }
        parts.append(.need)
        if let why = knockCase.currentWhy, !why.isEmpty { parts.append(.why) }
        if picked != nil { parts.append(.pickedPoints) }
        return parts
    }

    /// Where the panel shows the ask's options: the dock, and only there.
    static func optionsPlaces(for knockCase: Case) -> [AskOptionsPlace] { AskDocRules.optionsPlaces(for: knockCase) }

    /// The sticky area shows a pick whose pros and cons the doc then spells out.
    static func pickedOption(in knockCase: Case, selectedId: String?) -> Option? {
        guard let selectedId else { return nil }
        return knockCase.options.first { $0.id == selectedId }
    }

    /// The pick block shows for every ask with single-choice options, before a pick too (WAG-303, audit F1).
    /// An ask with questions shows its steps and the steps bar, not the free reply field (WAG-305).
    static func showsQuestions(_ knockCase: Case) -> Bool { AskBarMode.forCase(knockCase) == .answers }

    static func showsPickBlock(_ knockCase: Case) -> Bool {
        AskBarMode.forCase(knockCase) == .decide && knockCase.select != .many
    }

    /// The column is at most 430pt wide, so the lists stack in one column.
    static let blockColumns = false

    /// The tallest the option rows of the workspace dock get: 40% of the column, never under `DecisionDock.minCap`.
    /// Past it only the rows scroll, so they never cover the pick box (WAG-303, audit F3).
    static func dockCap(columnHeight: CGFloat) -> CGFloat { max(DecisionDock.minCap, columnHeight * DecisionDock.stepShare) }

    /// The soft fade at the bottom edge of the scroll area, only while content runs under the dock.
    static let fadeHeight: CGFloat = 28
    static func showsBottomFade(contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        viewportHeight > 0 && contentHeight > viewportHeight + 1
    }

    /// "YOUR PICK · 1 FLAGGED FIRST".
    static func pickLabel(_ option: Option, position: Int) -> String { CalmOption.pickLabel(option, position: position) }
}
