import SwiftUI

/// The case pane / detail column (docs/design/mvp-values.md §M3 `aWM03` →
/// `BFz3X`, and the disconnected §M11 `SyfHH` → `neoem` variant).
///
/// KNOCK-08 built the read-only Needs-you queue (M3) and the offline state
/// (M11). HAIL-25 makes the options interactive and adds the artifact
/// preview card; both live in `CasePaneDetailView` below, keyed by case id
/// so their state resets when the selected case changes. "Open review" sets
/// `model.reviewRequestCaseId`, which `MainWindowView` uses to swap in the
/// KNOCK-10 review workspace (M4).
struct CasePaneView: View {
    @ObservedObject var model: AppModel
    /// The header's expand icon (HAIL-96): folds the queue and the conversation together.
    var isBothFolded = false
    var onToggleBothFolded: (() -> Void)?
    /// "Your agent is on it" while the first job runs (WAG-338), and the action behind "Try a sample instead".
    @ObservedObject var firstRun: GettingStartedModel = .inert
    var onTrySample: () -> Void = {}

    private var isOffline: Bool { model.connectionState != .connected }

    var body: some View {
        Group {
            if let detail = model.selectedCaseDetail {
                CasePaneDetailView(
                    model: model, detail: detail,
                    isBothFolded: isBothFolded, onToggleBothFolded: onToggleBothFolded)
                    .id(detail.case.id)
            } else if !isOffline, let working = firstRun.agentOnIt {
                AgentOnItCard(working: working, sample: firstRun.sample, onTrySample: onTrySample)
            } else if !isOffline && model.needsYouCases.isEmpty {
                // WAG-362: Home replaces the plain "Select a case…" placeholder once no ask needs you.
                HomeView()
            } else {
                VStack {
                    Spacer()
                    Text(isOffline ? "No cached case selected." : "Select a case to see its details.")
                        .knockTextStyle(Theme.Typography.body13w400)
                        .foregroundColor(Theme.Colors.ink2)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.win)
    }
}

/// One selected case's toolbar, body and bottom action bar. A fresh instance
/// per case id (`CasePaneView` keys it with `.id`), so `sendFlow` - and the
/// `ComposerViewModel` it owns - never leaks a prior case's selection into a
/// newly opened one. Not `private`: `footerKind` below is a pure static
/// function tests reach via `@testable import Knock`, the same pattern
/// `ReviewWorkspaceView.rightColumnKind` uses.
struct CasePaneDetailView: View {
    @ObservedObject var model: AppModel
    let detail: CaseDetail
    @StateObject private var sendFlow: SendFlowController
    /// The decision doc's own state: the answers, the open artifact and its viewer (WAG-257).
    @StateObject private var askDoc: AskDocController
    /// WAG-280: the case's comments, so the Send count follows a pin placed on the opened artifact.
    @ObservedObject private var commentsStore: CommentsSessionStore
    /// The live artifact of the page and its tabs (WAG-276).
    @StateObject private var liveArtifact: LiveArtifactModel
    /// WAG-410: "Continue in a new session" for a case whose agent session ended. Starts only on a click.
    @StateObject private var continueSession = ContinueEvidence.makeModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Identifies this pane's unsent-work check in `AppModel` (HAIL-118).
    @State private var probeId = UUID()
    /// The sources of the round on screen and their card and list (WAG-356). Not observed here: the host and
    /// the pills observe it, so a hover does not redraw the page.
    @State private var sourcesHub: SourcesHub
    @State private var askHub: AskCommentsHub
    /// Gates the Dismiss confirmation (HAIL-32); non-nil only while that
    /// dialog is on screen.
    @State private var showDismissConfirmation = false
    /// The pane's own width, for the split's collapse (HAIL-71). Starts wide so
    /// the first frame does not flash the toggle.
    @State private var paneWidth: CGFloat = 1200
    /// The decision column's own width, for the plan page's two columns (WAG-290).
    @State private var decisionHeight: CGFloat = 800
    @State private var decisionWidth: CGFloat = 1200
    /// Whether the conversation column is open (WAG-299). It starts closed for every case: the
    /// pane is keyed by case id, so moving to another case closes it again. A narrow pane slides
    /// it over the decision; a wide pane puts it beside.
    @State private var isConversationOpen: Bool
    let isBothFolded: Bool
    let onToggleBothFolded: (() -> Void)?

    private var isOffline: Bool { model.connectionState != .connected }
    /// The ask's thread, once you have replied; the split pane applies only then (HAIL-71).
    private var thread: ThreadModel? {
        isOffline ? nil : detail.threadModel(artifactKind: model.artifactKindByCaseId[detail.case.id])
    }
    private var lockState: ReplyLockState { detail.case.replyLockState }
    init(
        model: AppModel, detail: CaseDetail,
        isBothFolded: Bool = false, onToggleBothFolded: (() -> Void)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.model = model
        self.detail = detail
        _commentsStore = ObservedObject(wrappedValue: model.commentsStore(forCase: detail.case.id))
        self.isBothFolded = isBothFolded
        self.onToggleBothFolded = onToggleBothFolded
        let sendFlow = SendFlowController(
            knockCase: detail.case,
            // WAG-280: the case's one comment store, shared with the opened artifact's viewer, the
            // own window and the review workspace. Send goes straight through, comments included.
            commentsStore: model.commentsStore(forCase: detail.case.id),
            coordinator: model.sendCoordinator,
            client: model.client,
            revisionArrival: detail.revisionArrival,
            replies: detail.replies,
            usage: model.usage,
            onSent: {},
            onAnswerSent: { model.advanceAfterSend(answeredCaseId: detail.case.id, answer: $0) }
        )
        // Every `KNOCK_PANE_*` hook below targets only the case `KNOCK_OPEN_CASE`
        // named (Contract HAIL-53 fold): a case with no `KNOCK_OPEN_CASE` set
        // acts on any case, same as before. With one set, `AppModel.
        // advanceAfterSend`'s "Next ask" (this story) can open a SECOND
        // needs_you case right after the first send - a fresh
        // `CasePaneDetailView` for it, with the same process-wide env vars
        // still set, would otherwise re-select and re-send on THAT case too,
        // cascading through the whole queue instead of touching only the one
        // case evidence asked for.
        let isEvidenceHookTarget = environment["KNOCK_OPEN_CASE"] == nil || environment["KNOCK_OPEN_CASE"] == detail.case.id
        // `KNOCK_PANE_SELECT_OPTION=<option id>` (Amendments): the
        // orchestrator's evidence hook for a non-default selection, since it
        // cannot click a specific option row itself - the same pattern as
        // `KNOCK_REVIEW_STEP`/`KNOCK_REVIEW_MODE`.
        if isEvidenceHookTarget, let optionId = environment["KNOCK_PANE_SELECT_OPTION"],
           detail.case.options.contains(where: { $0.id == optionId }) {
            sendFlow.composer.selectOption(optionId)
            // `KNOCK_PANE_DESELECT_OPTION=1` (HAIL-43 evidence): clicks the
            // same option again, since the orchestrator cannot click a chip
            // twice itself - proves the chip clears rather than staying
            // picked.
            if environment["KNOCK_PANE_DESELECT_OPTION"] == "1" {
                sendFlow.composer.selectOption(optionId)
            }
        }
        // `KNOCK_PANE_DRAFT_TEXT=<text>` (HAIL-41 evidence): the
        // orchestrator's evidence hook for a typed reply, since it cannot
        // type into the composer's field itself - the same pattern as
        // `KNOCK_PANE_SELECT_OPTION` above.
        if isEvidenceHookTarget, let draftText = environment["KNOCK_PANE_DRAFT_TEXT"] {
            sendFlow.composer.draftText = draftText
        }
        // `KNOCK_PANE_SEND=1` (HAIL-41 evidence): the orchestrator's evidence
        // hook for the pane's own Send action (the selected option plus
        // whatever is typed) - distinct from `KNOCK_PANE_SEND_RECOMMENDATION`
        // below, which always sends the recommendation regardless of any
        // selection or typed text. Same re-render guard as that hook.
        if isEvidenceHookTarget, environment["KNOCK_PANE_SEND"] == "1", detail.case.status == .needsYou {
            sendFlow.send()
        }
        // `KNOCK_PANE_SEND_RECOMMENDATION=1` (Amendments, HAIL-32 evidence):
        // the orchestrator's evidence hook for the M8 Sending/Sent/Delivered
        // sequence, since it cannot click "Send recommended answer" itself -
        // the same pattern as `KNOCK_PANE_SELECT_OPTION` above. Gated on
        // `detail.case.status == .needsYou`: this initializer runs again on
        // every SwiftUI re-render of this case (an unchanged `@StateObject`
        // identity, but a fresh struct init each time), and unlike selecting
        // an option, sending is not a no-op to repeat - without this guard a
        // single case.updated event from the first send retriggers another
        // send, which retriggers another event, forever.
        if isEvidenceHookTarget, environment["KNOCK_PANE_SEND_RECOMMENDATION"] == "1", detail.case.status == .needsYou {
            sendFlow.acceptRecommendation()
        }
        // `KNOCK_PANE_CHANGE_ANSWER=1` (Amendments, HAIL-34 evidence): the
        // orchestrator's evidence hook for the queued "Change answer" flow,
        // since it cannot click that text button itself - the same pattern
        // as `KNOCK_PANE_SEND_RECOMMENDATION` above. Gated on `.queued`, the
        // one state the button is even shown in.
        if isEvidenceHookTarget, environment["KNOCK_PANE_CHANGE_ANSWER"] == "1", detail.case.replyLockState == .queued {
            sendFlow.beginChangingAnswer()
        }
        // `KNOCK_PANE_ASK_FOR_DETAIL=1` (HAIL-33 evidence): the orchestrator's
        // evidence hook for the inline "Ask for more detail" field, since it
        // cannot click that secondary button itself - the same pattern as
        // `KNOCK_PANE_CHANGE_ANSWER` above.
        if isEvidenceHookTarget, environment["KNOCK_PANE_ASK_FOR_DETAIL"] == "1", detail.case.replyLockState == .editable {
            sendFlow.composer.beginAskingForDetail()
        }
        // `KNOCK_PANE_ASK_MORE_DETAIL=<text>` or `format:<eli5|diagram|page>` (HAIL-147 evidence):
        // sends the detail request itself, so the delivery banner can be captured.
        if isEvidenceHookTarget, let ask = environment["KNOCK_PANE_ASK_MORE_DETAIL"], detail.case.status == .needsYou,
           !Self.evidenceMoreDetailSent {
            Self.evidenceMoreDetailSent = true
            sendFlow.composer.beginAskingForDetail()
            if ask.hasPrefix("format:") {
                sendFlow.askForMoreDetail(format: ReplyFormat(rawValue: String(ask.dropFirst(7))))
            } else {
                sendFlow.composer.fillDetailChip(ask)
                sendFlow.askForMoreDetail()
            }
        }
        // `KNOCK_CONVERSATION_OPEN=1` (WAG-299 evidence): opens the column on the targeted case, since
        // a capture run cannot click the header icon.
        _isConversationOpen = State(initialValue: isEvidenceHookTarget && environment["KNOCK_CONVERSATION_OPEN"] == "1")
        _sendFlow = StateObject(wrappedValue: sendFlow)
        _sourcesHub = State(initialValue: SourcesHub(book: detail.currentSourceBook, evidenceOpen: EvidenceSources.open))
        _askHub = State(initialValue: AskCommentsHub(store: model.commentsStore(forCase: detail.case.id)))
        _askDoc = StateObject(wrappedValue: AskDocController(client: model.client, usage: model.usage, request: detail.case, commentsStore: model.commentsStore(forCase: detail.case.id), store: model.askDocMemory, itemAnswers: Self.sentItemAnswers(detail)))
        _liveArtifact = StateObject(wrappedValue: LiveArtifactModel(
            caseId: detail.case.id, client: model.client, tabs: detail.artifactTabs(),
            commentsStore: model.commentsStore(forCase: detail.case.id)))
    }

    /// Re-renders re-run `init`; the evidence send must happen once.
    @MainActor private static var evidenceMoreDetailSent = false

    var body: some View {
        EvidenceLayoutLog.bump("body.casePane")
        let thread = thread
        let isCollapsed = ConversationSplit.isCollapsed(paneWidth: paneWidth)
        return VStack(spacing: 0) {
            toolbarRow(thread: thread)
            if isOffline {
                offlineBody
            } else {
                AskCommentsHost(hub: askHub, onExplain: { [sendFlow] in sendFlow.explain(selection: $0) }) {
                SourcesHost(hub: sourcesHub) {
                    ZStack(alignment: .trailing) {
                        HStack(spacing: 0) {
                            decisionColumn(isCollapsed: isCollapsed)
                            if let thread, isColumnShown, !isCollapsed {
                                conversationColumn(thread)
                                    .transition(.move(edge: .trailing))
                            }
                        }
                        if let thread, isColumnShown, isCollapsed {
                            conversationColumn(thread)
                                .shadow(color: Theme.Colors.ink.opacity(0.08), radius: 10, x: -2, y: 0)
                                .transition(.move(edge: .trailing))
                        }
                    }
                }
                }
                .clipped()
                .onChange(of: isAnswerDisplayLocked, initial: true) { _, _ in askHub.sync(detail: detail, canComment: !isAnswerDisplayLocked) }
                .onChange(of: detail.replies) { _, _ in askHub.sync(detail: detail, canComment: !isAnswerDisplayLocked) }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { EvidenceLayoutLog.event("case.paneWidth", "old=\(paneWidth) new=\($0)"); paneWidth = $0 }
        .boundedIdealWidth()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Files dropped on the request attach to the reply (WAG-345), until it is sent.
        .attachesDroppedFiles(to: sendFlow.composer.files, enabled: !isAnswerDisplayLocked || sendFlow.isEditingLockedAnswer)
        // A stale `.sent` from a prior send-and-cycle: the case returning to
        // needs_you (a `knock_update`, docs/protocol-mvp.md "Case and reply
        // states") means it is time to compose a fresh reply, not still show
        // the last one's outcome (docs/stories/HAIL-32.md "One state
        // source" - the footer must never show a state older than reality).
        // WAG-387: opening a shared case uploads missing rounds and fetches new comments.
        .task(id: detail.case.id) { await sharing.refresh() }
        .onChange(of: detail.case) { _, updated in
            Task { await sharing.load() }
            // An update may bring new options (HAIL-108): the composer reads the newest set.
            sendFlow.refreshCase(updated)
            askDoc.refresh(with: updated, itemAnswers: Self.sentItemAnswers(detail))
        }
        .onChange(of: detail.currentSourceBook) { _, book in sourcesHub.update(book: book) }
        .onChange(of: detail.revisions) { _, _ in
            liveArtifact.update(tabs: detail.artifactTabs())
        }
        .onChange(of: detail.planRounds) { _, _ in
            liveArtifact.update(tabs: detail.artifactTabs())
        }
        // WAG-352: the artifact follows the decision on screen.
        .onChange(of: decisionFocus) { _, focus in followDecision(focus) }
        .task { followDecision(decisionFocus) }
        .onChange(of: sendFlow.isEditingLockedAnswer) { _, editing in
            if editing { askDoc.doc?.unlock() }
        }
        .onChange(of: detail.case.status) { _, newStatus in
            if newStatus == .needsYou {
                sendFlow.startNewRound()
            }
        }
        .background(
            EscapeKeyCatcher(
                shouldHandle: { window in
                    HomeLink.escapeGoesHome(
                        isVisible: showsHomeLink, textInputFocused: HomeLink.textInputHasFocus(in: window),
                        holdsUnsentWork: model.holdsUnsentWork,
                        dialogOpen: showDismissConfirmation || window?.attachedSheet != nil || askDoc.open != nil || sourcesHub.isOpen, isBothFolded: isBothFolded)
                },
                onEscape: model.goHome)
        )
        .background(
            CaseScreenKeyCatcher { delta, window in
                guard CaseScreenKeys.flips(
                    isFlippable: liveArtifact.isFlippable(liveArtifact.selectedTab), allowsScreenKeys: liveArtifact.allowsScreenKeys,
                    textInputFocused: HomeLink.textInputHasFocus(in: window), fullSizeOpen: askDoc.open != nil,
                    sheetOpen: showDismissConfirmation || window?.attachedSheet != nil) else { return false }
                liveArtifact.stepScreen(by: delta)
                return true
            }
        )
        .background(
            Button("Toggle conversation") { toggleConversation() }
                .keyboardShortcut(SplitFoldShortcuts.ask)
                .disabled(thread == nil)
                .opacity(0)
        )
        .onAppear {
            startRequestedChangeAnswer()
            model.registerUnsentWorkProbe(id: probeId) { [weak sendFlow] in sendFlow?.hasUnsentWork ?? false }
        }
        .onDisappear { model.unregisterUnsentWorkProbe(id: probeId) }
        .task { await runUsageEvidenceSteps() }
        .task {
            guard let delay = ContinueEvidence.clickDelay else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            continueInNewSession()
        }
        .task {
            // `KNOCK_EVIDENCE_OPEN_REVIEW=1` (HAIL-150): opens the review workspace once, as a click would.
            guard ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_OPEN_REVIEW"] == "1" else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            openReview()
        }
        .onChange(of: model.changeAnswerRequestCaseId) { _, _ in startRequestedChangeAnswer() }
        .onChange(of: detail.case.replyLockState) { _, _ in startRequestedChangeAnswer() }
        .confirmationDialog(
            "Dismiss this decision?",
            isPresented: $showDismissConfirmation
        ) {
            Button("Dismiss", role: .destructive) { Task { await model.dismiss(caseId: detail.case.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent is waiting on \"\(detail.case.title)\". Dismissing it now sends back \"The human dismissed this ask without answering.\"")
        }
    }

    /// The decision on screen of a request with several decisions, for the artifact box. `nil` otherwise.
    private var decisionFocus: DecisionFocus? {
        askDoc.doc.flatMap { DecisionFocus.make(case: detail.case, doc: $0) }
    }

    private func followDecision(_ focus: DecisionFocus?) {
        guard let focus else { return }
        Task { await liveArtifact.follow(decision: focus) }
    }

    /// `KNOCK_EVIDENCE_USAGE=open,full,pick:2,send` (HAIL-83 evidence hook, same
    /// style as the other `KNOCK_PANE_*` ones): runs those steps once on the
    /// case `KNOCK_OPEN_CASE` names, since a capture run cannot click. `open` is a queue click; `full`
    /// records the preview's "Open full size" without switching screens; `pick:N`
    /// is the number key N; `send` is the composer's Send.
    private func runUsageEvidenceSteps() async {
        let env = ProcessInfo.processInfo.environment
        guard let steps = env["KNOCK_EVIDENCE_USAGE"], env["KNOCK_OPEN_CASE"] == detail.case.id else { return }
        for step in steps.split(separator: ",") {
            if step == "open" {
                await model.open(caseId: detail.case.id, source: .queue)
            } else if step == "full" {
                for _ in 0..<60 where model.artifactKindByCaseId[detail.case.id] == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                model.recordPreviewOpen(
                    .artifactOpenedFull, caseId: detail.case.id, artifactKind: model.artifactKindByCaseId[detail.case.id])
            } else if step.hasPrefix("pick:"), let n = Int(step.dropFirst(5)) {
                sendFlow.composer.selectOption(atPosition: n)
            } else if step == "send", detail.case.status == .needsYou {
                sendFlow.send()
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// The toast's "Change answer" (HAIL-79): once this pane shows the answered
    /// case with a queued reply, starts the same flow as the footer's button.
    /// A reply that is no longer queued drops the request.
    private func startRequestedChangeAnswer() {
        guard model.changeAnswerRequestCaseId == detail.case.id else { return }
        switch lockState {
        case .queued:
            if !sendFlow.isEditingLockedAnswer { sendFlow.beginChangingAnswer() }
            model.clearChangeAnswerRequest()
        case .delivered, .failed:
            model.clearChangeAnswerRequest()
        case .editable:
            break
        }
    }

    /// The plan page's layout at the decision column's width (WAG-290).
    private var planLayout: AskLayout.Layout {
        AskLayout.layout(width: decisionWidth, hasArtifact: detail.case.hasArtifact)
    }

    /// Two columns: the artifact beside the question. A side panel or a full page keeps the usual stack.
    private var showsSideBySide: Bool { planLayout == .sideBySide && askDoc.open == nil }

    /// The left column: the question and the dock (the whole pane when there is no thread).
    private func decisionColumn(isCollapsed: Bool) -> some View {
        VStack(spacing: 0) {
            if let open = askDoc.open, open.placement == .fullPage {
                ArtifactFullPageView(controller: askDoc, open: open, isLocked: isAnswerDisplayLocked)
                answerDock
                footer
            } else if showsSideBySide {
                sideBySideBody(contextThread: contextThread(isCollapsed: isCollapsed))
            } else {
                onlineBody(contextThread: contextThread(isCollapsed: isCollapsed))
                if detail.case.hasArtifact { pinnedArtifactBar }
                answerDock
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { EvidenceLayoutLog.event("case.decisionWidth", "old=\(decisionWidth) new=\($0)"); decisionWidth = $0 }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { EvidenceLayoutLog.event("case.decisionHeight", "old=\(decisionHeight) new=\($0)"); decisionHeight = $0 }
    }

    /// An ask with an artifact on a wide window (WAG-290 for a plan, every ask since WAG-306): the artifact at full height on the left,
    /// scrolling on its own; the question, its option cards, the note and Decide on the right.
    private func sideBySideBody(contextThread: ThreadModel?) -> some View {
        VStack(spacing: 0) {
            statusCard
            if liveCase.sessionClosedBeforeAnswer { SessionClosedNotice(continueSession: continueSession, onContinue: { continueInNewSession() }) }
            AskColumnsLayout {
                DecisionArtifactView(
                    model: liveArtifact, composer: sendFlow.composer, caseKind: detail.case.kind, client: model.client,
                    onOpen: { openReview(.artifactOpenedFull) }, onInteract: { recordPreviewInteraction() },
                    fillsHeight: true, onOpenWindow: openTabInWindow, onOpenBrowser: openTabInBrowser,
                    canComment: !isAnswerDisplayLocked, followsComposer: askDoc.doc?.isStepped != true)
                    .coachMarkAnchor(.artifact)
                    .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 12))
                    .frame(maxWidth: .infinity)
                VStack(spacing: 0) {
                    scrollBody(contextThread: contextThread, isSideBySide: true)
                    // The option cards sit in the bottom part with the note and Decide (WAG-291); past the cap
                    // they scroll inside it and the question above scrolls on its own.
                    answerDock(optionsCap: DecisionDock.cap(.plan, windowHeight: decisionHeight))
                    footer
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Whether the column is on screen: the case has a thread, it is open, and the sides are not
    /// both folded (WAG-299).
    private var isColumnShown: Bool {
        ConversationSplit.isShown(hasThread: thread != nil, isOpen: isConversationOpen, isBothFolded: isBothFolded)
    }

    /// The header icon, ⌘] and the menu command (WAG-299). The column slides in from the right:
    /// 220 ms ease-out in, 150 ms out, no motion with Reduce Motion.
    private func toggleConversation() {
        guard thread != nil else { return }
        let opening = !isConversationOpen
        withAnimation(reduceMotion ? nil : .easeOut(duration: opening ? 0.22 : 0.15)) { isConversationOpen.toggle() }
    }

    /// The thread steps the context card carries (HAIL-107): all of them while the conversation
    /// column is out of sight, none while it shows them (the card then keeps the session rows only).
    private func contextThread(isCollapsed: Bool) -> ThreadModel? {
        isColumnShown ? nil : thread
    }

    private func conversationColumn(_ thread: ThreadModel) -> some View {
        ConversationColumnView(
            model: thread,
            turn: detail.threadTurn(
                thread, delivery: model.deliveryStatusByCaseId[detail.case.id],
                settled: AnswerGrouping.settled(
                    detail.case, allCases: model.needsYouCases + model.waitingOnAgentCases, now: model.now)),
            onSeeInReview: detail.case.hasArtifact ? { openReviewOnPriorRevision() } : nil)
    }

    /// Which footer to show, as a pure function of state (docs/stories/
    /// HAIL-34.md fold, gap 1: "the queued state and Change answer apply to
    /// the pane AND the review workspace, for every ask kind") -
    /// unit-testable without hosting the view.
    enum FooterKind: Equatable {
        case composer
        case confirmedOutcome
        case changeAnswerBar
        /// Review-kind only, queued and not yet being edited in the pane: the
        /// same Sent line + Change answer the question kind shows, plus
        /// "Open review" as a secondary action (HAIL-41: "Change answer" now
        /// puts the pane itself into edit mode - `.composer` - rather than
        /// only opening the workspace; "Open review" stays reachable for
        /// pins/Comment mode).
        case reviewChangeAnswerBar
        case openReviewBar
    }

    static func footerKind(
        kind: Case.Kind, lockState: ReplyLockState, isEditingLockedAnswer: Bool, hasConfirmedOutcome: Bool
    ) -> FooterKind {
        // Checked before the kind split (HAIL-41): a review ask being edited
        // via "Change answer" now composes in the pane too, exactly like a
        // question ask - previously this pane never reached `.composer` for
        // a review ask at all, so "Change answer" had to hand off to the
        // workspace instead.
        if isEditingLockedAnswer { return .composer }
        if hasConfirmedOutcome {
            return kind == .review ? .openReviewBar : .confirmedOutcome
        }
        if lockState == .queued {
            return kind == .review ? .reviewChangeAnswerBar : .changeAnswerBar
        }
        // Editable and unanswered (HAIL-41): a review ask now gets the same
        // composer a question ask gets, not just an "Open review" bar - the
        // operator can pick an option and reply right here.
        return .composer
    }

    private var footerKind: FooterKind {
        Self.footerKind(
            kind: detail.case.kind, lockState: lockState,
            isEditingLockedAnswer: sendFlow.isEditingLockedAnswer,
            hasConfirmedOutcome: model.deliveryStatusByCaseId[detail.case.id] != nil
        )
    }

    /// The question-kind footer once a confirmed outcome exists
    /// (`AppModel.deliveryStatusByCaseId`): collapses to
    /// `CaseFooterConfirmedView` instead of the live composer, so this pane
    /// never shows two disagreeing views of the same delivery (HAIL-32 "One
    /// state source"). Falls back to the normal composer/in-flight banner
    /// while no outcome is confirmed yet. Review-kind cases never reach the
    /// composer/confirmedOutcome/changeAnswerBar cases here - `footerKind`
    /// routes them to `reviewFooter` instead.
    @ViewBuilder
    private var footer: some View {
        if detail.case.isDone {
            EmptyView()
        } else if footerKind == .confirmedOutcome, let confirmed = model.deliveryStatusByCaseId[detail.case.id],
                  DeliveryBannerSlot.slot(for: confirmed) == .footer {
            CaseFooterConfirmedView(
                state: confirmed,
                onRetry: { Task { await model.retryDelivery(caseId: detail.case.id) } }
            )
            .padding(EdgeInsets(top: 14, leading: 24, bottom: 18, trailing: 24))
            .overlay(
                Rectangle().fill(Theme.Colors.line).frame(height: 1),
                alignment: .top
            )
        } else {
            switch footerKind {
            case .composer, .confirmedOutcome:
                // An options case already carries its reply field and
                // toolbar inside `answerDock`'s `ComposerCardView` - showing
                // `ComposerFooterView` here too would duplicate it. A
                // free-text case (no options) has no card above, so it still
                // gets the standalone footer.
                if AskBarMode.forCase(detail.case) == .reply {
                    composerFooter
                }
            case .changeAnswerBar:
                changeAnswerBar
            case .reviewChangeAnswerBar:
                reviewChangeAnswerBar
            case .openReviewBar:
                openReviewBar
            }
        }
    }

    private var composerFooter: some View {
        ComposerFooterView(
            composer: sendFlow.composer,
            sendFlow: sendFlow,
            deliveryState: sendFlow.deliveryState,
            commentCount: commentsStore.model.comments.count,
            placeholder: PromptBarLogic.placeholder(for: .reply, hasRevision: detail.revisionArrival != nil),
            // Review-kind only (HAIL-41): the pane's own escape hatch to the
            // full review workspace for pins and Comment mode, which the
            // pane itself never offers (Non-goal). A question ask has no
            // workspace to open, so this stays nil for it.
            onOpenReview: detail.case.kind == .review ? { openReview() } : nil,
            showsFailure: false
        )
    }

    // The top status strip is the one "waiting for the agent" line; the bars below no longer repeat it (WAG-336, F17).

    /// "Sent · waiting for the agent to pick it up" plus "Change answer"
    /// (docs/stories/HAIL-34.md): the queued state's own footer, replacing
    /// the composer until the operator asks to edit. "Change answer" is an
    /// outlined secondary button, the same style "Ask for more detail" uses
    /// (docs/stories/HAIL-36.md amendment 1, operator: "change answer not
    /// clickable here right?") - it used to read as plain grey text.
    private var changeAnswerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            PickupFallbackView(item: detail.case)
            // WAG-401: late team comments on a decided shared case. It shows nothing when there are none.
            LateCommentsBarView(
                sharing: sharing, item: detail.case, onChangeAnswer: sendFlow.beginChangingAnswer,
                sendPrompt: LateCommentsSend.toSession(client: model.client, item: detail.case))
            // The bar carries its own Change answer.
            if sharing.lateComments.count == 0 {
                SecondaryOutlineButtonView(label: "Change answer", action: sendFlow.beginChangingAnswer)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 24, bottom: 18, trailing: 24))
        .overlay(
            Rectangle().fill(Theme.Colors.line).frame(height: 1),
            alignment: .top
        )
    }

    /// The review-kind counterpart of `changeAnswerBar` (docs/stories/
    /// HAIL-34.md fold, gap 1): same Sent line, but "Change answer" now edits
    /// in the pane itself (HAIL-41: `sendFlow.beginChangingAnswer()`, the
    /// same call the question kind's `changeAnswerBar` makes) rather than
    /// opening the review workspace - the pane carries a review ask's
    /// composer now, same as a question ask's. "Open review" stays
    /// reachable alongside it as the lighter link to the full workspace
    /// (pins, Comment mode), reading "View review" once delivered via
    /// `openReviewLabel` - "Change answer" is the outlined button, same as
    /// `changeAnswerBar` above.
    private var reviewChangeAnswerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            PickupFallbackView(item: detail.case)
            LateCommentsBarView(
                sharing: sharing, item: detail.case, onChangeAnswer: sendFlow.beginChangingAnswer,
                sendPrompt: LateCommentsSend.toSession(client: model.client, item: detail.case))
            HStack(spacing: 18) {
                if sharing.lateComments.count == 0 {
                    SecondaryOutlineButtonView(label: "Change answer", action: sendFlow.beginChangingAnswer)
                }
                Text(openReviewLabel)
                    .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                    .foregroundColor(Theme.Colors.ink3)
                    .contentShape(Rectangle())
                    .onTapGesture { openReview() }.pointerCursor()
            }
        }
        .padding(EdgeInsets(top: 14, leading: 24, bottom: 18, trailing: 24))
        .overlay(
            Rectangle().fill(Theme.Colors.line).frame(height: 1),
            alignment: .top
        )
    }

    private func requestDismiss() {
        if detail.case.needsDismissConfirmation {
            showDismissConfirmation = true
        } else {
            Task { await model.dismiss(caseId: detail.case.id) }
        }
    }

    /// The page header. The conversation icon is part of it (WAG-299), so it spans the whole width.
    private func toolbarRow(thread: ThreadModel?) -> some View {
        toolbar(thread: thread)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "← Home" shows for a case that is not in Needs you (HAIL-119).
    private var showsHomeLink: Bool { HomeLink.isVisible(caseId: detail.case.id, needsYou: model.needsYouCases) }

    /// The crumbs line. The project name opens the project page (WAG-260).
    private var breadcrumb: some View {
        let task = detail.task
        return HStack(spacing: 0) {
            Button { model.openProjectPage(task.project) } label: {
                Text(AskCrumbs.projectName(task))
                    .knockTextStyle(Theme.Typography.monoMeta12w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help("Open the project page")
            if let rest = AskCrumbs.titlePart(task: task, sessionTitle: model.sessionTitle(for: detail.case)) {
                Text("  /  \(rest)")
                    .knockTextStyle(Theme.Typography.monoMeta12w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1)
                    .help(AskCrumbs.folderHelp(task))
            }
        }
    }

    /// The case's sharing state (WAG-387).
    private var sharing: SharingModel { SharingModels.model(for: detail.case.id, client: model.client) }

    private func toolbar(thread: ThreadModel?) -> some View {
        HStack(spacing: 14) {
            if showsHomeLink {
                HStack(spacing: 6) { HomeLinkButton(action: model.goHome) }
            }
            breadcrumb
            // "Arrived 21:14 · answered 21:30 · took 16m" (docs/stories/
            // HAIL-34.md 21:38): the opened ask's own header meta, ticking
            // every minute off `model.now` while still pending.
            Text(detail.headerMetaLabel(now: model.now))
                .knockTextStyle(Theme.Typography.monoMeta12w400)
                .foregroundColor(Theme.Colors.ink3)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            ShareCaseButton(
                model: sharing,
                onViewComments: AppModel.canOpenReview(kind: detail.case.kind, hasArtifact: detail.case.hasArtifact)
                    ? { model.openReviewOnComments(caseId: detail.case.id) } : nil)
            Menu {
                Button("Dismiss", role: .destructive, action: requestDismiss)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Colors.ink2)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if let thread, ConversationSplit.hasColumn(thread: thread) {
                ConversationIconButton(
                    roundCount: thread.roundCount, isOpen: isColumnShown, action: toggleConversation)
            }
            FoldIconButton(
                symbol: BothFoldedCopy.symbol(isBothFolded: isBothFolded), isActive: isBothFolded,
                help: BothFoldedCopy.help(isBothFolded: isBothFolded), action: { onToggleBothFolded?() })
        }
        .padding(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24))
        .opacity(isOffline ? 0.55 : 1)
        .overlay(
            Rectangle().fill(Theme.Colors.line).frame(height: 1),
            alignment: .bottom
        )
    }

    /// The Delivered/Failed outcome once `reply.state_changed` confirms it
    /// (docs/design/mvp-values.md §M8 panels 2/4, Amendment 2 KNOCK-13 fold):
    /// the review workspace has already closed for this case by the time
    /// the event arrives, so `AppModel.deliveryStatusByCaseId` is the only
    /// place left to show it.
    private func deliveryOutcome(status: DeliveryState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DeliveryOutcomeBanner(
                state: status, onRetry: { Task { await model.retryDelivery(caseId: detail.case.id) } },
                copyLine: DeliveryOutcomeBanner.copyLine(for: liveCase), caseId: liveCase.id,
                continueSession: liveCase.sessionState == .ended ? continueSession : nil,
                onContinue: { continueInNewSession() })
            // "After Delivered, the pane says what happens next"
            // (docs/stories/HAIL-34.md): a reply is one-way, so this is the
            // only forward-looking line the pane ever shows for it.
            if case .delivered = status {
                Text("The agent has your answer. If it needs more from you, it will ask again.")
                    .knockTextStyle(Theme.Typography.body13w400)
                    .foregroundColor(Theme.Colors.ink2)
            }
        }
    }

    /// WAG-410: starts a new session with the question, the options and the answer (the sent one, else the open draft).
    private func continueInNewSession() {
        let composer = sendFlow.composer
        let draft = ContinuePrompt.draftAnswer(
            options: liveCase.options, selectedIds: composer.selectedOptionIds, note: composer.draftText)
        let item = liveCase
        let failedReplyId = detail.replies.last { $0.state == .failed }?.id
        Task {
            await continueSession.start(item: item, answer: draft) { try await model.client.sessionsList() }
            // WAG-410: the new session has the answer, so the failed reply is handed over.
            if continueSession.phase == .started { await model.handOverFailedReply(caseId: item.id, failedReplyId: failedReplyId) }
        }
    }

    /// The case with the session fields the lists keep fresh (WAG-258).
    private var liveCase: Case { model.listedCase(id: detail.case.id) ?? detail.case }

    private func onlineBody(contextThread: ThreadModel?) -> some View {
        VStack(spacing: 0) {
            statusCard
            if liveCase.sessionClosedBeforeAnswer { SessionClosedNotice(continueSession: continueSession, onContinue: { continueInNewSession() }) }
            HStack(spacing: 0) {
                scrollBody(contextThread: contextThread)
                if let open = askDoc.open, open.placement == .beside {
                    ArtifactPanelView(controller: askDoc, open: open, isLocked: isAnswerDisplayLocked)
                        .onChange(of: askDoc.doc?.step) { _, _ in followStepInPanel() }
                        .transition(reduceMotion ? .identity : .move(edge: .trailing))
                }
            }
            .clipped()
            // The panel slides in over 220 ms, ease-out; with Reduce Motion it just appears.
            .animation(
                reduceMotion ? nil : .easeOut(duration: Theme.AskDoc.Metrics.panelSlide),
                value: askDoc.open?.placement == .beside)
        }
    }

    /// The status strip while the open ask waits on the agent (HAIL-62).
    @ViewBuilder
    private var statusCard: some View {
        if detail.case.isDone {
            doneCard
        } else if detail.case.status == .waitingOnAgent {
            let delivery = model.deliveryStatusByCaseId[detail.case.id]
            let status = AgentStatus.forCase(liveCase, deliveryStatus: delivery)
            AgentStatusStrip(
                status: status,
                runtime: detail.case.runtimeLabel,
                since: AgentStatus.timerStart(detail.case, status: status, deliveryStatus: delivery),
                readAt: Self.readAt(delivery) ?? detail.case.latestReplyDeliveredAtDate,
                item: liveCase,
                settled: AnswerGrouping.settled(
                    detail.case, allCases: model.needsYouCases + model.waitingOnAgentCases,
                    deliveredAt: Self.readAt(delivery), now: model.now),
                onOpenCase: { id in Task { await model.open(caseId: id, source: .queue) } }
            )
        }
    }

    /// The strip of a done case (HAIL-152): the agent finished and needs no answer. Got it closes
    /// the ask and sends nothing to the agent.
    private var doneCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(Theme.Colors.ok)
            Text("Done · \(detail.case.runtimeLabel) finished and needs no answer")
                .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                .foregroundColor(Theme.Colors.ok)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button { Task { await model.dismiss(caseId: detail.case.id) } } label: {
                Text("Got it")
                    .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                    .foregroundColor(Theme.Colors.ink)
                    .padding(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                    .background(Theme.Colors.win)
                    .cornerRadius(Theme.Radius.buttonSmall)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall).stroke(Theme.Colors.line2, lineWidth: 1))
            }
            .buttonStyle(.plain).pointerCursor()
            .accessibilityLabel("Got it")
        }
        .padding(EdgeInsets(top: 9, leading: 24, bottom: 9, trailing: 24))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.okSoft)
    }

    private static func readAt(_ delivery: DeliveryState?) -> Date? {
        if case .delivered(let at)? = delivery { return at }
        return nil
    }

    private func scrollBody(contextThread: ThreadModel?, isSideBySide: Bool = false) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Inside the scroll, not pinned above it (operator, 29 Sep:
                // "why there's this weird empty box there?"): pinned, the
                // content scrolled under it and the RECOMMENDED block's
                // clipped edge read as an empty box. The footer still shows
                // the delivery state.
                // Delivered is already said by the orb status card above and
                // the footer, so only a failure (with its Retry) shows here.
                if detail.case.status == .waitingOnAgent, let status = model.deliveryStatusByCaseId[detail.case.id],
                   DeliveryBannerSlot.slot(for: status) == .paneTop {
                    deliveryOutcome(status: status)
                }
                // WAG-410: the failed reply went to a new session. A calm line, no failure.
                if liveCase.latestReplyState == .handedOver {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.uturn.forward.circle")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.Colors.ink3)
                        Text(ReplyApplyCopy.handedOver)
                            .knockTextStyle(Theme.Typography.caption11_5w400)
                            .foregroundColor(Theme.Colors.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let followsCaseId = detail.case.followsCaseId {
                    FollowUpHeaderView(
                        followsCaseId: followsCaseId, client: model.client,
                        onOpen: { id in Task { await model.open(caseId: id, source: .queue) } }
                    )
                }
                if let replacesCaseId = detail.case.replacesCaseId {
                    ReplacesHeaderView(replacesCaseId: replacesCaseId, client: model.client)
                }
                // A plan ask with no artifact stays on this page (HAIL-151): its stage track and the
                // folded answers sit above the title.
                if let plan = detail.case.plan {
                    PlanColumnHeaderView(plan: plan, rounds: detail.planRounds ?? [])
                }
                crumbsLine
                // A done note heads the page in full size; the old decision folds under it (WAG-333).
                if let note = DoneNote.message(for: detail.case) {
                    AskTitleView(heading: nil, title: note, width: headerWidth)
                    EarlierDecisionFold { pageDecision }
                } else if let note = detail.case.workingNoteText {
                    // A progress note heads the page; the round it follows folds (WAG-377).
                    WorkingNoteLine(note: note)
                    EarlierDecisionFold(title: "Earlier round") { pageDecision }
                } else if let update = detail.case.messageOnlyUpdate?.fullText(from: detail.messages, after: detail.case.latestReplyAtDate) {
                    LatestMessageNote(note: update, width: headerWidth)
                    if update.staysLive {
                        // A talk reply or a question keeps the round live: the message sits above it (WAG-393).
                        pageDecision
                    } else {
                        // A message-only update heads the page; the round it answers folds (WAG-337).
                        EarlierDecisionFold(title: "Earlier round") { pageDecision }
                    }
                } else {
                    pageDecision
                    // WAG-343: new options replaced the questions; the questions fold as the earlier round.
                    if detail.case.questionsReplacedByLaterRound {
                        EarlierDecisionFold(title: "Earlier round") { earlierQuestions }
                    }
                }
                // The team's comments come after the question and its page (WAG-389).
                SharedCommentsSection(model: sharing)
                // Options no longer sit here at the end of the scroll: they
                // live in `answerDock`, fixed above the composer (operator,
                // 29 Sep: "this part should be sticky visible at the bottom,
                // not at the end of the scroll"). A typed answer with no
                // options still shows here, where the options would be.
                if detail.case.options.isEmpty, isAnswerDisplayLocked,
                   !(detail.case.latestReplyMessage ?? "").isEmpty || !sentFiles.isEmpty {
                    answerMessageCard(detail.case.latestReplyMessage ?? "")
                }
            }
            .padding(isSideBySide
                ? EdgeInsets(top: 24, leading: 12, bottom: 20, trailing: 28)
                : EdgeInsets(top: 30, leading: 44, bottom: 24, trailing: 44))
            .frame(maxWidth: isSideBySide ? .infinity : Theme.AskDoc.Metrics.pageMaxWidth + 88, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: StickyHeader.space)
        // Explicit, not left to the ScrollView's own ideal size (docs/
        // stories/HAIL-36.md layout bug: the delivered banner + "If it needs
        // more from you..." line above this ScrollView, in the same VStack,
        // once overlapped the RECOMMENDED block at short window heights) -
        // without this the ScrollView can hug its own content height instead
        // of claiming exactly the space left after `toolbar`/`deliveryOutcome`/
        // `footer`, the standard ScrollView-in-VStack sizing gotcha.
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var pageDecision: some View {
        if let doc = askDoc.doc, doc.isStepped {
            steppedBody(doc)
        } else {
            documentBody
        }
    }

    /// The ask as one page: its title, the need and, for an ask with questions, a section per question.
    @ViewBuilder
    private var documentBody: some View {
        AskTitleView(heading: detail.case.roundHeading, title: detail.case.title, width: headerWidth)
            .coachMarkAnchor(.round)

        // The stage label sits in the track, so the honey box keeps its own label (WAG-290).
        NeedCalloutView(
            need: detail.case.displayNeed(planRounds: detail.planRounds),
            why: detail.case.currentWhy,
            labelAbove: detail.case.plan.map { PlanText.progressLabel($0.stage) })

        // The pick (or the recommendation) of a simple decision, under the need box (WAG-293).
        if askDoc.doc == nil, AskBarMode.forCase(detail.case) == .decide {
            DecisionPickBlockView(
                composer: sendFlow.composer, isLocked: isAnswerDisplayLocked,
                yourAnswerOptionId: detail.case.latestReplyChoice, columns: planLayout != .sideBySide)
        }

        // Between the recommended block and the option rows (WAG-356). A round with no sources adds nothing.
        SourcesButtonSlot()

        if let instruction = detail.case.roundHeading?.instruction {
            RoundInstructionView(text: instruction)
        }

        // An ask with questions: a section per question. The options of a simple ask sit in the
        // bottom bar only (`AskDocRules.optionsPlaces`), so no Decision card shows here.
        if let doc = askDoc.doc {
            questionSections(doc)
        }
        // A plan question or a simple ask: its answers are the calm cards in the dock below, shown once
        // (WAG-281). The artifact sits in the box above or beside the page (WAG-306).
    }

    /// A decision with several questions, one step at a time (WAG-287): the step bar, then the usual page
    /// of that question, or the summary on the last step.
    @ViewBuilder
    private func steppedBody(_ doc: QuestionsDocModel) -> some View {
        let binding = Binding(get: { askDoc.doc ?? doc }, set: { askDoc.doc = $0 })
        VStack(alignment: .leading, spacing: 14) {
            StepBarView(doc: binding)
            if let question = doc.currentQuestion {
                GroupHeadingView(title: question.groupTitle)
                SourcedText(
                    text: question.title, style: headerWidth.titleStyle, color: Theme.Colors.ink,
                    target: AskCommentTarget(.question, itemId: question.id), weight: .semibold)
                    .textSelection(.enabled)
                // Every step shows the need of the request with its own step label (WAG-334), so a later
                // step is never an empty page. Its pick or recommendation card follows in `questionStep`.
                NeedCalloutView(need: detail.case.need, why: detail.case.why, labelAbove: doc.sectionLabel(of: question))
                questionStep(question, doc: binding)
                SourcesButtonSlot()
            } else {
                Text("Send your \(doc.questions.count) decisions?")
                    .knockTextStyle(headerWidth.titleStyle)
                    .foregroundColor(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                ReviewStepView(doc: binding)
            }
        }
        .id(doc.step)
        .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(x: 6)))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: doc.step)
    }

    private func questionStep(_ question: Question, doc: Binding<QuestionsDocModel>) -> some View {
        let revision = detail.revisions.map(\.n).max() ?? 1
        return QuestionSectionView(
            question: question, doc: doc, cards: [],
            selectedCardId: askDoc.open.flatMap { $0.questionId == question.id ? $0.card.id : nil },
            lastTarget: askDoc.lastTarget,
            onOpen: { card, target in openArtifact(card, question: question.id, target: target) },
            showsHeader: false, showsPoints: !DecisionDock.optionsInDock(.step), showsPicks: true)
    }

    /// The ask's artifact on a stacked page: a bar above the answers that stays on screen (decision 2026-11-05).
    private var pinnedArtifactBar: some View {
        PinnedArtifactBar(
            model: liveArtifact, composer: sendFlow.composer, followsComposer: askDoc.doc?.isStepped != true,
            onOpen: { openReview(.artifactOpenedFull, revision: liveArtifact.selectedTab?.revision) })
            .coachMarkAnchor(.artifact)
    }

    private func recordPreviewInteraction() {
        model.recordPreviewInteraction(
            caseId: detail.case.id, artifactKind: model.artifactKindByCaseId[detail.case.id])
    }

    /// The title size follows the column: a side-by-side page is a narrow column (WAG-302).
    private var headerWidth: AskHeaderWidth { showsSideBySide ? .narrow : .wide }

    private var crumbsLine: some View {
        let earlier = EarlierAsksModel.make(
            item: detail.case, cases: model.needsYouCases + model.waitingOnAgentCases, now: model.now)
        return AskCrumbLine(
            crumb: AskCrumbs.screenLine(
                task: detail.task, sessionTitle: model.sessionTitle(for: detail.case), runtime: detail.case.runtimeLabel,
                askNumber: model.sessionContext(for: detail.case).askNumber, doc: askDoc.doc),
            help: AskCrumbs.folderHelp(detail.task),
            earlierAsks: earlier,
            onOpenCase: { id in Task { await model.open(caseId: id, source: .queue) } },
            onOpenHistory: openHistory)
    }

    /// "Open the history ›": shows the conversation column.
    private func openHistory() {
        guard !isConversationOpen else { return }
        toggleConversation()
    }

    /// The questions of round 0 after a later round replaced them: read-only, no answers bar.
    private var earlierQuestions: some View {
        let doc = QuestionsDocModel(request: detail.case, itemAnswers: [])
        return VStack(alignment: .leading, spacing: 34) {
            ForEach(doc.questions) { question in
                QuestionSectionView(
                    question: question, doc: .constant(doc), cards: [], selectedCardId: nil,
                    lastTarget: { askDoc.lastTarget(fullSize: $0) }, onOpen: { _, _ in })
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func questionSections(_ doc: QuestionsDocModel) -> some View {
        let revision = detail.revisions.map(\.n).max() ?? 1
        let binding = Binding(get: { askDoc.doc ?? doc }, set: { askDoc.doc = $0 })
        return VStack(alignment: .leading, spacing: 34) {
            ForEach(doc.questions) { question in
                QuestionSectionView(
                    question: question, doc: binding, cards: [],
                    selectedCardId: askDoc.open.flatMap { $0.questionId == question.id ? $0.card.id : nil },
                    lastTarget: { askDoc.lastTarget(fullSize: $0) },
                    onOpen: { card, target in openArtifact(card, question: question.id, target: target) })
                    .padding(.top, 8)
                    .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .top)
            }
        }
        .padding(.top, 6)
    }

    /// The side panel shows the question of the current step. The review step leaves it as it is.
    private func followStepInPanel() {
        guard let doc = askDoc.doc, let question = doc.currentQuestion, let open = askDoc.open, open.placement == .beside,
              open.questionId != question.id else { return }
        let revision = detail.revisions.map(\.n).max() ?? 1
        let card = ArtifactCardModel.cards(for: detail.case, revision: revision, question: question).first ?? open.card
        askDoc.retarget(card: card, questionId: question.id)
    }

    /// A card's Open: this page or its panel, or outside it (a window, the browser).
    private func openArtifact(_ card: ArtifactCardModel, question: String?, target: ArtifactOpenTarget) {
        guard let external = askDoc.choose(target, card: card, questionId: question) else {
            Task { await askDoc.ensureLoaded(detail: detail, revision: card.revision) }
            return
        }
        let fragment = askDoc.fragment(for: question)
        switch external {
        case .fullSize:
            openReview(.artifactOpenedFull)
        case .ownWindow:
            openWindow(id: ArtifactWindowRequest.sceneID, value: ArtifactWindowRequest(
                caseId: detail.case.id, fragment: fragment, title: "\(card.name) · \(detail.case.title)"))
        case .browser:
            Task { await openInBrowser(revision: card.revision, fragment: fragment) }
        }
    }

    /// The artifact box's Open menu (WAG-291): the tab on show opens in a window of its own.
    private func openTabInWindow(_ tab: ArtifactTab) {
        openWindow(id: ArtifactWindowRequest.sceneID, value: ArtifactWindowRequest(
            caseId: detail.case.id, fragment: nil, title: "\(tab.title) · \(detail.case.title)", revision: tab.revision))
    }

    private func openTabInBrowser(_ tab: ArtifactTab) {
        Task { await openInBrowser(revision: tab.revision, fragment: nil) }
    }

    /// "In the browser": the staged bundle behind a sandboxed page (`BrowserWrapper`), in the default browser.
    private func openInBrowser(revision: Int, fragment: String?) async {
        guard let found = try? await model.client.artifactPath(caseId: detail.case.id, revision: revision),
              found.kind == .htmlBundle else { return }
        let entry = URL(fileURLWithPath: found.entry).resolvingSymlinksInPath()
        guard let page = try? BrowserWrapper.write(
            entry: entry, root: URL(fileURLWithPath: found.root), fragment: fragment, title: detail.case.title, caseId: detail.case.id, name: "\(detail.case.id)-v\(revision)")
        else { return }
        NSWorkspace.shared.open(page)
    }

    /// The item answers of the newest Decide reply, for a sent request with items to show (WAG-315).
    static func sentItemAnswers(_ detail: CaseDetail) -> [ItemAnswer] {
        detail.replies.last { $0.itemAnswers?.isEmpty == false && $0.outcome != .talk }?.itemAnswers ?? []
    }

    /// The unified composer card (docs/stories/HAIL-54.md), fixed above the
    /// footer (Pen "Ask pane · sticky answer dock", approved 29 Sep): only
    /// the question, the why and the preview scroll; the choice is always in
    /// view. The card's own options section is capped at `maxOptionsHeight`,
    /// past which only the options scroll inside it and the reply field and
    /// toolbar stay put. Absent for an ask without options.
    private var answerDock: some View { answerDock(optionsCap: Self.maxOptionsHeight) }

    @ViewBuilder
    private func answerDock(optionsCap: CGFloat?) -> some View {
        switch AskBarMode.forCase(detail.case) {
        case .reply:
            EmptyView()
        case .answers:
            // Hidden once the answers are sent and settled; the footer then says where they are.
            if askDoc.doc != nil, !isAnswerDisplayLocked || sendFlow.deliveryState.state != .idle {
                AnswersBarView(
                    doc: Binding(get: { askDoc.doc ?? QuestionsDocModel(request: detail.case, itemAnswers: Self.sentItemAnswers(detail)) }, set: { askDoc.doc = $0 }),
                    sendFlow: sendFlow, deliveryState: sendFlow.deliveryState, isChanging: sendFlow.isEditingLockedAnswer,
                    maxPointsHeight: DecisionDock.cap(.step, windowHeight: decisionHeight) ?? DecisionDock.minCap)
            }
        case .decide where DoneNote.message(for: detail.case) != nil:
            // The done note heads the page; the closed decision's rows are not offered again (WAG-333).
            EmptyView()
        case .decide:
            ComposerCardView(
                composer: sendFlow.composer,
                sendFlow: sendFlow,
                deliveryState: sendFlow.deliveryState,
                recommendationId: detail.case.recommendation,
                commentCount: commentsStore.model.comments.count,
                placeholder: PromptBarLogic.placeholder(for: .decide, hasRevision: detail.revisionArrival != nil),
                isLocked: isAnswerDisplayLocked,
                yourAnswerOptionId: detail.case.latestReplyChoice,
                yourAnswerOptionIds: Set(detail.case.latestReplyChoices),
                lockedMessage: detail.case.latestReplyMessage,
                lockedAttachments: sentFiles,
                onOpenReview: detail.case.kind == .review ? { openReview() } : nil,
                maxOptionsHeight: optionsCap,
                showsFullOptions: true,
                fullLabelOnlyWhenSelected: detail.case.plan != nil,
                showsFailure: false
            )
            .coachMarkAnchor(.options)
        }
    }

    /// The open calm card plus two one-line rows; more scroll inside the dock.
    static let maxOptionsHeight: CGFloat = 420

    /// Whether this ask's options/answer read as locked (docs/stories/
    /// HAIL-34.md operator report 21:11): the ask has a reply for this round
    /// and "Change answer" has not put `sendFlow` back into edit mode.
    /// Shared by `optionsList` (dims every option but the one actually sent)
    /// and the "Your answer" message card below it.
    private var isAnswerDisplayLocked: Bool { lockState != .editable && !sendFlow.isEditingLockedAnswer }

    /// The locked answer's own "Your answer" card (docs/stories/HAIL-36.md):
    /// under the options, showing the typed message that went with the
    /// reply - alone when no option was chosen, alongside the chosen
    /// option's own "Your answer" tag when one was. Full text, wraps, never
    /// truncated - the same card recipe as the RECOMMENDED block above it.
    /// The files the person sent with the latest reply (WAG-345).
    private var sentFiles: [ReplyAttachment] {
        detail.replies.first { $0.id == detail.case.latestReplyId }?.attachments ?? []
    }

    private func answerMessageCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("YOUR ANSWER")
                .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                .foregroundColor(Theme.Colors.ink3)
            if !message.isEmpty {
                Text(message)
                    .knockTextStyle(Theme.Typography.value13_5w600)
                    .foregroundColor(Theme.Colors.ink)
            }
            SentAttachmentsView(files: sentFiles).padding(.top, message.isEmpty ? 2 : 4)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.recommendedBlock)
    }

    private func openReviewOnPriorRevision() {
        model.recordPreviewOpen(
            .reviewOpened, caseId: detail.case.id, artifactKind: model.artifactKindByCaseId[detail.case.id])
        sendFlow.composer.focusDraftOnOpen = true
        model.activateSelectionOnPriorRevision()
    }

    /// `event` says which control opened it: the preview card's "Open full
    /// size" (`artifactOpenedFull`) or "Open review" (`reviewOpened`, HAIL-83).
    private func openReview(_ event: UsageEvent = .reviewOpened, revision: Int? = nil) {
        model.recordPreviewOpen(
            event, caseId: detail.case.id, artifactKind: model.artifactKindByCaseId[detail.case.id])
        sendFlow.composer.focusDraftOnOpen = true
        // Comment in the case box leaves its page here (WAG-347); a plain Open full size leaves nothing.
        model.activateSelection(commentHandoff: liveArtifact.takeCommentHandoff(), revision: revision ?? liveArtifact.fullSizeRevision)
    }

    private var offlineBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 6) {
                chip("Review")
                chip("Blocking")
                chip(detail.case.runtimeLabel)
            }
            Text(detail.case.title)
                .knockTextStyle(Theme.Typography.panelTitle22w600)
                .foregroundColor(Theme.Colors.ink)
                .textSelection(.enabled)
            AgentMarkdownText(
                text: detail.case.need, style: Theme.Typography.body13_5w400, color: Theme.Colors.ink2)
        }
        .padding(EdgeInsets(top: 32, leading: 32, bottom: 0, trailing: 32))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(0.5)
    }

    private func chip(_ label: String) -> some View {
        Text(label)
            .knockTextStyle(Theme.Typography.chipLabel11_5w600)
            .foregroundColor(Theme.Colors.ink2)
            .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
            .background(Theme.Colors.side)
            .cornerRadius(Theme.Radius.chip)
    }

    /// "View review" once the reply has been delivered (docs/stories/
    /// HAIL-34.md operator report 21:37): there is nothing left to compose,
    /// only the read-only recap the review workspace's own locked column
    /// shows. Still "Open review" while queued - the workspace opens
    /// straight into the "Change answer" flow from there if wanted.
    private var openReviewLabel: String {
        lockState == .delivered ? "View review" : "Open review"
    }

    private var openReviewBar: some View {
        HStack(spacing: 8) {
            Text(openReviewLabel)
                .knockTextStyle(Theme.Typography.button13_5w600)
                .foregroundColor(Theme.Colors.win)
            Text("↵")
                .knockTextStyle(Theme.Typography.keyHint12_5w400)
                .foregroundColor(Theme.Colors.win.opacity(0.7))
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .background(Theme.Colors.ink)
        .cornerRadius(Theme.Radius.buttonPrimary)
        .contentShape(Rectangle())
        .onTapGesture { openReview() }.pointerCursor()
        .padding(EdgeInsets(top: 14, leading: 32, bottom: 18, trailing: 32))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            Rectangle().fill(Theme.Colors.line).frame(height: 1),
            alignment: .top
        )
    }
}
