import SwiftUI

/// Main window: a 392pt list column and a flexible detail column
/// (docs/design/mvp-values.md §M3 `aWM03`).
struct MainWindowView: View {
    @ObservedObject var model: AppModel
    /// O4's coach-mark tour (docs/stories/HAIL-29.md), shared from
    /// `OnboardingModel` via `KnockApp` - `nil` in previews/tests that have
    /// no onboarding flow in play.
    var coachMarkTour: CoachMarkTourModel?
    /// The getting started list and "Your agent is on it" (WAG-338).
    @ObservedObject var firstRun: GettingStartedModel = .inert
    /// "Try a sample instead".
    var onTrySample: () -> Void = {}

    @ObservedObject private var updateReady = UpdateReadyModel.shared
    @ObservedObject private var updatePrompt = UpdatePromptModel.shared
    /// The one-page layout's folds (HAIL-84), remembered across launches.
    @StateObject private var fold = SplitFoldState()
    /// The sidebar's dragged width (task 13a), remembered across launches.
    @ObservedObject private var paneWidths = PaneWidthStore.shared
    /// A document is dragged over the window (HAIL-169, WAG-248).

    var body: some View {
        mainContent
            .environment(\.sessionPidByTaskId, model.sessionPidByTaskId)
            .environment(
                \.nudge,
                NudgeContext(
                    canNudgeByTaskId: model.canNudgeByTaskId,
                    records: model.nudgeRecords, send: { model.nudge(caseId: $0) },
                    copiedPrompt: { model.copiedPrompt() }))
    }

    /// The queue's saved fold, applied only while the queue has content (HAIL-91).
    private var queueFolded: Bool {
        QueueFold.isFolded(saved: fold.isQueueFolded, hasContent: model.hasQueueContent)
    }

    /// The queue header's fold icon: none while there is nothing to fold (HAIL-91).
    private func queueFoldAction(_ toggle: @escaping () -> Void) -> (() -> Void)? {
        model.hasQueueContent ? toggle : nil
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            TestCopyStripView()
            Group {
                if let project = model.openProject {
                    ProjectPageView(
                        project: project, client: model.client, now: model.now,
                        onBack: model.closeProjectPage,
                        onOpenCase: { id in Task { await model.open(caseId: id, source: .queue) } }
                    )
                    .id(project)
                } else if let detail = model.selectedCaseDetail, model.reviewRequestCaseId == detail.case.id {
                    // The review workspace, where comments work: opened from "Comment" or Open review.
                    reviewWorkspace(detail: detail)
                } else {
                    // The decision doc and the empty states (HAIL-89): the same queue fold.
                    HStack(spacing: 0) {
                        if !queueFolded {
                            QueueListView(
                                model: model, onFold: queueFoldAction(fold.toggleQueueFold), firstRun: firstRun,
                                width: paneWidths.sidebarWidth)
                                // Task 13a: the sidebar's 1 pt right line moves by drag; the hit area is centred on
                                // it and sits over the case pane's edge, so it stays above the pane.
                                .overlay(alignment: .trailing) {
                                    PaneBorderHandle(border: .sidebar, store: paneWidths)
                                        .offset(x: PaneBorderHandle.hitWidth / 2 - 0.5)
                                }
                                .zIndex(1)
                        } else {
                            QueueFoldedRailView(count: model.visibleNeedsYouCases.count, onUnfold: fold.toggleQueueFold)
                        }
                        CasePaneView(
                            model: model,
                            isBothFolded: fold.isBothFolded, onToggleBothFolded: fold.toggleBothFolded,
                            firstRun: firstRun, onTrySample: onTrySample)
                    }
                    .overlayPreferenceValue(CoachMarkAnchorKey.self) { anchors in
                        if let tour = coachMarkTour, let id = tour.activeCaseId, id == model.selectedCaseDetail?.case.id {
                            CoachMarkOverlayView(tour: tour, anchors: anchors, queueWidth: queueFolded ? 0 : paneWidths.sidebarWidth)
                        }
                    }
                    .overlayPreferenceValue(NotificationsLineAnchorKey.self) { anchor in
                        GeometryReader { proxy in
                            if let anchor, firstRun.highlightsNotifications {
                                let rect = proxy[anchor]
                                NotificationsTip().offset(x: rect.maxX + 12, y: max(8, rect.minY - 8))
                            }
                        }
                    }
                    .background(
                        Button("Toggle queue", action: fold.toggleQueueFold)
                            .keyboardShortcut(SplitFoldShortcuts.queue)
                            .disabled(!model.hasQueueContent)
                            .opacity(0)
                    )
                    .background(
                        Group {
                            Button("Fold both sides", action: fold.toggleBothFolded)
                                .keyboardShortcut(SplitFoldShortcuts.bothFolded)
                            Button("Show both sides", action: fold.exitBothFolded)
                                .keyboardShortcut(SplitFoldShortcuts.leaveBothFolded)
                                .disabled(!fold.isBothFolded)
                        }
                        .opacity(0)
                    )
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            // The "Sent" toast (HAIL-79) lives in the list column, above its footer. With the list folded
            // (or no list on screen) it has no column, so it sits at the window's bottom left instead.
            if queueFolded || model.openProject != nil || model.reviewRequestCaseId != nil {
                SentToastView(model: model).padding(.leading, 2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Bottom-right corner (operator, 29 Sep: "bottom right corner,
            // not middle right").
            UpdateToastView(model: updateReady, waitingAgents: Set(model.needsYouCases.map(\.taskId)).count)
                .padding(16)
                .opacity(updatePrompt.offer == nil ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: updateReady.isVisible)
        }
        .overlay {
            // WAG-318: the update prompt on start.
            UpdatePromptView(model: updatePrompt)
                .animation(.easeOut(duration: 0.2), value: updatePrompt.offer != nil)
        }
        .background(Theme.Colors.win)
        .fixedWindowMinimum(width: 900, height: 600)
        .layoutLogWindowProbe()
        .task {
            model.start()
            // Evidence only: the folded layouts have no composer to schedule the snapshot.
            EvidenceWindowSnapshot.scheduleIfRequested(delay: 7)
            updateReady.presentEvidenceIfRequested()
            updatePrompt.presentEvidenceIfRequested()
            await model.presentEvidenceSentToastIfRequested()
            await model.presentEvidenceHomeIfRequested()
            await model.presentEvidenceOpenAnsweredIfRequested()
        }
    }

    @ViewBuilder
    private func reviewWorkspace(detail: CaseDetail, embedded: Bool = false) -> some View {
        ReviewWorkspaceView(
            detail: detail, now: model.now, client: model.client, sendCoordinator: model.sendCoordinator,
            onBack: { model.closeReview() },
            onRetryDelivery: { Task { await model.retryDelivery(caseId: detail.case.id) } },
            onOpenCase: { id in
                if !embedded { model.closeReview() }
                Task { await model.open(caseId: id, source: .queue) }
            },
            onAnswerSent: { model.advanceAfterSend(answeredCaseId: detail.case.id, answer: $0) },
            opensOnPriorRevision: embedded ? false : model.reviewOpensOnPriorRevision,
            commentHandoff: model.reviewCommentHandoff,
            opensOnRevision: embedded ? nil : model.reviewOpensOnRevision,
            opensOnComments: embedded ? false : model.reviewOpensOnComments,
            usage: model.usage,
            unsentWorkRegistry: model,
            fold: embedded ? fold : nil,
            onHome: embedded && HomeLink.isVisible(caseId: detail.case.id, needsYou: model.needsYouCases)
                ? { model.goHome() } : nil,
            deliveryStatus: model.deliveryStatusByCaseId[detail.case.id],
            sessionContext: model.sessionContext(for: detail.case),
            settled: AnswerGrouping.settled(
                detail.case, allCases: model.needsYouCases + model.waitingOnAgentCases,
                deliveredAt: { if case .delivered(let at)? = model.deliveryStatusByCaseId[detail.case.id] { return at }; return nil }(),
                now: model.now),
            sessionTitle: model.sessionTitle(for: detail.case),
            earlierAsks: EarlierAsksModel.make(
                item: detail.case, cases: model.needsYouCases + model.waitingOnAgentCases, now: model.now),
            commentsStore: model.commentsStore(forCase: detail.case.id),
            askDocMemory: model.askDocMemory
        )
    }
}
