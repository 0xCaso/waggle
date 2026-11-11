import SwiftUI

/// The Inbox list column (docs/design/mvp-values.md §M3 `aWM03` → `tHixN`,
/// and the disconnected §M11 `SyfHH` → `hv5k3` variant).
struct QueueListView: View {
    @ObservedObject var model: AppModel
    /// The footer's own session-count poller (HAIL-50 contract: "status dot
    /// + 'Connected · N sessions'"): `AppModel`'s one `ConnectionModel`, shared
    /// with the Sessions panel, so the footer and the panel never disagree.
    /// Not observed here: only `QueueFooterSessionStatus` and the Sessions panel re-render on its poll.
    private let connection: ConnectionModel
    /// The getting started list and "Your agent is on it" (WAG-338).
    @ObservedObject private var firstRun: GettingStartedModel
    @FocusState private var isFocused: Bool
    /// The case pending a Dismiss confirmation (HAIL-32: "asks for
    /// confirmation only when the case is needs_you and the agent is live").
    /// Non-nil only while that dialog is on screen.
    @State private var pendingDismissConfirmation: Case?
    /// The right edge of the window's traffic lights, nil without them (HAIL-180).
    @State private var trafficLightsMaxX: CGFloat? = QueueHeaderLayout.defaultTrafficLightsMaxX
    @Environment(\.openSettings) private var openSettings
    /// The sessions panel above the footer (HAIL-59).
    @State private var sessionsOpen = false
    @State private var sessionsPanelFrame: CGRect = .zero
    @State private var sessionsButtonFrame: CGRect = .zero
    @State private var dismissMonitor = SessionsPopoverDismissMonitor()

    /// Non-nil on the one page (HAIL-88): the chevron in the header folds the queue.
    let onFold: (() -> Void)?
    /// The sidebar's width: 300 pt, or the width its border was dragged to (task 13a).
    let width: CGFloat

    init(
        model: AppModel, onFold: (() -> Void)? = nil, firstRun: GettingStartedModel = .inert,
        width: CGFloat = Theme.Spacing.listColumnWidth
    ) {
        self.model = model
        self.onFold = onFold
        self.width = width
        _firstRun = ObservedObject(wrappedValue: firstRun)
        connection = model.sessionsModel
    }

    private var isOffline: Bool { model.connectionState != .connected }

    /// `KNOCK_EVIDENCE_GOT_IT=<seconds>` (evidence-only, HAIL-152): taps Got it on the first done
    /// row after that delay, through the same `model.dismiss` the button calls.
    private func scheduleEvidenceGotIt() {
        guard let raw = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_GOT_IT"], let seconds = Double(raw) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if let item = model.waitingOnAgentCases.first(where: \.isDone) { await model.dismiss(caseId: item.id) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let filter = model.sessionFilter {
                SessionFilterChip(filter: filter, onClear: { model.sessionFilter = nil })
            }
            if isOffline {
                OfflineBannerView(
                    onStartService: { ServiceControl.startDaemon() },
                    onViewLog: {}
                )
                cachedLabel
            }
            let isQueueEmpty = model.visibleNeedsYouCases.isEmpty && model.visibleWaitingCases.isEmpty
                && model.visibleAnsweredCases.isEmpty && model.homeOverview.cards.isEmpty && model.autoDecidedToday.isEmpty
            let working = isOffline ? nil : firstRun.sidebarAgentOnIt
            let showsList = !isOffline && firstRun.isListVisible
            if isQueueEmpty && working == nil && !showsList {
                emptyState
            } else {
                let groupedNeedsYou = Self.grouped(model.visibleNeedsYouCases)
                // WAG-343: an ask a Working or In planning row opens is not listed again in Answered.
                let held = isOffline
                    ? model.visibleWaitingCases
                    : SidebarSections.heldAsks(model.visibleWaitingCases, overview: model.homeOverview, activeCases: model.activeCases)
                let groupedWaiting = Self.grouped(held.filter { !$0.isDone })
                let doneCases = held.filter(\.isDone)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isQueueEmpty && working == nil { QueueEmptyStateView(embedded: true) }
                        if !groupedNeedsYou.isEmpty {
                            SidebarSectionTitle(text: SidebarSections.sectionTitle("Needs you", count: groupedNeedsYou.count))
                        }
                        ForEach(Array(groupedNeedsYou.enumerated()), id: \.element.item.id) { index, entry in
                            row(for: entry.item, isUrgent: index == 0, isDimmed: false, isFollowUp: entry.isFollowUp)
                        }
                        // WAG-255: Working, In planning and the folded Quiet projects.
                        if !isOffline { SidebarWorkSections(model: model, firstJob: working) }
                        // WAG-412: asks a rule of yours answered. Folded, and never counted as "Needs you".
                        if !model.autoDecidedToday.isEmpty {
                            DecidedForYouHeader(count: model.autoDecidedToday.count, isOpen: model.autoDecidedOpen) {
                                model.autoDecidedOpen.toggle()
                            }
                            if model.autoDecidedOpen {
                                ForEach(model.autoDecidedToday, id: \.id) { item in
                                    DecidedForYouRow(
                                        item: item,
                                        isSelected: item.id == model.selectedCaseId,
                                        onOpen: { Task { await model.open(caseId: item.id, source: .queue) } },
                                        onChangeMind: { Task { await model.changeMind(caseId: item.id) } }
                                    )
                                }
                            }
                        }
                        // WAG-272: asks an agent still holds sit first in Answered; Working opens them too.
                        if !doneCases.isEmpty || !groupedWaiting.isEmpty || !model.visibleAnsweredCases.isEmpty {
                            answeredHeader(count: doneCases.count + groupedWaiting.count + model.visibleAnsweredCases.count)
                            if model.answeredOpen {
                                ForEach(doneCases, id: \.id) { item in
                                    row(for: item, isUrgent: false, isDimmed: false)
                                }
                                ForEach(groupedWaiting, id: \.item.id) { entry in
                                    row(for: entry.item, isUrgent: false, isDimmed: true, isFollowUp: entry.isFollowUp)
                                }
                                ForEach(answeredSections, id: \.title) { section in
                                    daySectionHeader(section)
                                    ForEach(section.cases, id: \.id) { item in
                                        answeredRow(for: item)
                                    }
                                }
                            }
                        }
                        if showsList {
                            GettingStartedView(model: firstRun)
                                .padding(EdgeInsets(top: 14, leading: 12, bottom: 12, trailing: 12))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if let undo = model.dismissUndo {
                DismissUndoToastView(undo: undo, onUndo: { Task { await model.undoDismiss() } })
            }
            footer
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.AskDoc.Chrome.sidebarFill)
        .overlay(alignment: .bottomLeading) { sessionsPanel }
        .overlay(
            Rectangle()
                .fill(Theme.Colors.line)
                .frame(width: 1),
            alignment: .trailing
        )
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            scheduleEvidenceGotIt()
        }
        .onKeyPress { press in
            switch press.key {
            case .upArrow:
                model.moveSelection(by: -1)
                return .handled
            case .downArrow:
                model.moveSelection(by: 1)
                return .handled
            case .return:
                model.activateSelection()
                return .handled
            case .delete where press.modifiers.contains(.command):
                requestDismissSelected()
                return .handled
            default:
                switch press.characters {
                case "j":
                    model.moveSelection(by: 1)
                    return .handled
                case "k":
                    model.moveSelection(by: -1)
                    return .handled
                default:
                    return .ignored
                }
            }
        }
        .confirmationDialog(
            "Dismiss this decision?",
            isPresented: Binding(
                get: { pendingDismissConfirmation != nil },
                set: { if !$0 { pendingDismissConfirmation = nil } }
            ),
            presenting: pendingDismissConfirmation
        ) { item in
            Button("Dismiss", role: .destructive) { Task { await model.dismiss(caseId: item.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("The agent is waiting on \"\(item.title)\". Dismissing it now sends back \"The human dismissed this ask without answering.\"")
        }
    }

    /// Routes a Dismiss request (⌘⌫, the row's context menu, the pane's `…`
    /// menu) through the confirmation gate (docs/stories/HAIL-32.md) before
    /// calling `model.dismiss`.
    private func requestDismiss(_ item: Case) {
        if item.needsDismissConfirmation {
            pendingDismissConfirmation = item
        } else {
            Task { await model.dismiss(caseId: item.id) }
        }
    }

    private func requestDismissSelected() {
        guard let id = model.selectedCaseId,
              let item = model.orderedCases.first(where: { $0.id == id }) else { return }
        requestDismiss(item)
    }

    /// The row header's time (operator, 29 Sep: "how long ago that message
    /// arrived there, or how long ago it was solved"): a pending row
    /// (`needsYouCases`) shows how long ago the ask arrived ("5m ago"); an
    /// answered row (`waitingOnAgentCases`) shows how long ago you answered
    /// it ("answered 2h ago"). Both tooltips give the full date and time.
    /// "took" stays in the opened ask's header. `isDimmed` already
    /// distinguishes the two call sites below (only the waiting-on-agent
    /// `ForEach` passes `true`), so it doubles as that switch here.
    private func timeLabel(for item: Case, isDimmed: Bool) -> (label: String, tooltip: String?) {
        if item.isDone, let doneAt = item.doneAtDate ?? item.updatedAtDate {
            return ("done \(CaseTimes.agoLabel(since: doneAt, now: model.now))",
                    "Done \(CaseTimes.arrivalTooltip(for: doneAt))")
        }
        if isDimmed, let answeredAt = item.firstReplySubmittedAtDate {
            return ("answered \(CaseTimes.agoLabel(since: answeredAt, now: model.now))",
                    "Answered \(CaseTimes.arrivalTooltip(for: answeredAt))")
        }
        // An ask that came back after your reply shows when it was updated,
        // not when it first arrived (HAIL-67).
        if !isDimmed, let update = item.pendingUpdate {
            return ("updated \(CaseTimes.agoLabel(since: update.at, now: model.now))",
                    "Updated \(CaseTimes.arrivalTooltip(for: update.at))")
        }
        let createdAt = item.createdAtDate ?? model.now
        return (CaseTimes.agoLabel(since: createdAt, now: model.now), "Arrived \(CaseTimes.arrivalTooltip(for: createdAt))")
    }

    /// Groups a follow-up case directly under the earlier ask it follows
    /// (HAIL-33 amendment: "a follow-up sits directly under its earlier
    /// ask ... when both are visible") - both must be in the same list, so
    /// a follow-up whose earlier ask has moved to the other queue section
    /// (or is no longer open) stays in its own newest-first position,
    /// ungrouped. `cases` is already sorted newest-first; that relative
    /// order is preserved both for top-level asks and for the follow-ups
    /// nested under each one.
    static func grouped(_ cases: [Case]) -> [(item: Case, isFollowUp: Bool)] {
        let idsInList = Set(cases.map(\.id))
        var childrenByParent: [String: [Case]] = [:]
        var topLevel: [Case] = []
        for item in cases {
            if let followsId = item.followsCaseId, followsId != item.id, idsInList.contains(followsId) {
                childrenByParent[followsId, default: []].append(item)
            } else {
                topLevel.append(item)
            }
        }
        var result: [(item: Case, isFollowUp: Bool)] = []
        var placed: Set<String> = []
        for item in topLevel {
            result.append((item, false))
            placed.insert(item.id)
            appendChildren(of: item.id, childrenByParent, into: &result, placed: &placed)
        }
        // Every ask shows exactly once (HAIL-120). A follow-up of a follow-up, or a follow-up
        // cycle, has no top-level parent to hang under: it stays in the list, ungrouped.
        for item in cases where !placed.contains(item.id) {
            result.append((item, false))
        }
        return result
    }

    private static func appendChildren(
        of parentId: String, _ childrenByParent: [String: [Case]],
        into result: inout [(item: Case, isFollowUp: Bool)], placed: inout Set<String>
    ) {
        for child in childrenByParent[parentId] ?? [] where !placed.contains(child.id) {
            result.append((child, true))
            placed.insert(child.id)
            appendChildren(of: child.id, childrenByParent, into: &result, placed: &placed)
        }
    }

    private func row(for item: Case, isUrgent: Bool, isDimmed: Bool, isFollowUp: Bool = false) -> some View {
        let time = timeLabel(for: item, isDimmed: isDimmed)
        let deliveryStatus = model.deliveryStatusByCaseId[item.id]
        return Button { Task { await model.open(caseId: item.id, source: .queue) } } label: { QueueRowView(
            item: item,
            now: model.now,
            sessionLabel: item.sessionLabel,
            sessionTitle: item.taskId.isEmpty ? nil : model.sessionTitleByTaskId[item.taskId],
            timeLabel: time.label,
            timeTooltip: time.tooltip,
            isSelected: item.id == model.selectedCaseId,
            isUrgent: isUrgent,
            isOfflineCached: isOffline,
            isDimmed: isDimmed,
            artifactKind: model.artifactKindByCaseId[item.id],
            deliveryStatus: deliveryStatus,
            isFollowUp: isFollowUp,
            unreadComments: model.unreadByCaseId[item.id] ?? 0,
            onRetryDelivery: { Task { await model.retryDelivery(caseId: item.id) } },
            onDismiss: { requestDismiss(item) },
            onGotIt: { Task { await model.dismiss(caseId: item.id) } }
        ) }
        .buttonStyle(.hoverRow)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.id == model.selectedCaseId ? .isSelected : [])
        // `LazyVStack` keeps this row's identity as it moves from
        // `needsYouCases` into this `waitingOnAgentCases` `ForEach` (same
        // `item.id`); without a discriminator here it can go on reusing the
        // pre-delivery layout it first appeared with, silently dropping the
        // compact Delivered/Failed badge that `reply.state_changed` adds a
        // moment later (confirmed live against a real daemon, KNOCK-13 fold
        // Amendment 2 evidence run). Folding the badge kind into `.id` forces
        // a fresh row the instant that status appears or changes.
        .id(Self.rowIdentity(caseId: item.id, status: item.status, deliveryStatus: deliveryStatus))
    }

    /// The row's own `.id()` (see `row(for:)`): `status` folded in alongside
    /// the delivery-status kind (docs/stories/HAIL-36.md, amendment 2 -
    /// operator report, an answered row still showing the pending arrival
    /// clock, no "you -> ..." line, no "Waiting for pickup" spinner). A
    /// case's first transition from `needsYouCases` into `waitingOnAgentCases`
    /// - the moment its first reply is sent - carries the SAME
    /// `badgeIdentity` on both sides (`nil` deliveryStatus, "none", both
    /// before and right after: a fresh queued reply is not itself a
    /// delivered/failed outcome). Without `status` here too, that leaves the
    /// `.id()` string unchanged across the transition, and `LazyVStack` can
    /// go on reusing the pre-reply row it first appeared with - the same
    /// staleness class `badgeIdentity` already fixes for a LATER
    /// delivered/failed transition, just one step earlier. Not `private`:
    /// `QueueListViewTests` reaches it via `@testable import`, the same
    /// pattern `grouped` uses.
    static func rowIdentity(caseId: String, status: CaseStatus, deliveryStatus: DeliveryState?) -> String {
        "\(caseId)#\(status.rawValue)#\(badgeIdentity(deliveryStatus))"
    }

    /// A stable discriminator for the row's `.id()` - just the enum case, not
    /// its associated value (a `Date`/`replyId` would force an identity
    /// change on every unrelated re-render).
    private static func badgeIdentity(_ status: DeliveryState?) -> String {
        switch status {
        case .none: "none"
        case .delivered: "delivered"
        case .failed: "failed"
        case .idle, .sending, .sent, .offline, .refused: "other"
        }
    }

    private var header: some View {
        Group {
            if isOffline {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Theme.Colors.daemonOfflineDot)
                        .frame(width: 6, height: 6)
                    Text("daemon offline")
                        .knockTextStyle(Theme.Typography.daemonStatus11_5w500)
                        .foregroundColor(Theme.Colors.ink2)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    // `.brand`: the mark 16, 7 to the wordmark (500 15, −0.03 em).
                    HStack(spacing: Theme.AskDoc.Chrome.brandGap) {
                        KnockMarkView().frame(width: Theme.AskDoc.Chrome.markSize, height: Theme.AskDoc.Chrome.markSize)
                        Text("waggle")
                            .knockTextStyle(Theme.AskDoc.Chrome.brand)
                            .foregroundColor(Theme.Colors.ink)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("waggle")
                    Spacer(minLength: 0)
                    // Case map `.needs` and `.count`.
                    Text("Needs you")
                        .knockTextStyle(Theme.AskDoc.Chrome.needsLabel)
                        .foregroundColor(Theme.Colors.ink)
                    // The red count pill (WAG-257).
                    Text("\(model.visibleNeedsYouCases.count)")
                        .knockTextStyle(Theme.AskDoc.Chrome.countPill)
                        .foregroundColor(model.visibleNeedsYouCases.isEmpty ? Theme.Colors.ink3 : Theme.Colors.onFill)
                        .padding(Theme.AskDoc.Chrome.countPillInset)
                        // Nothing needs you: the pill goes grey, not red.
                        .background(Capsule().fill(model.visibleNeedsYouCases.isEmpty ? Theme.Colors.side : Theme.Colors.accent))
                        .accessibilityLabel(model.visibleNeedsYouCases.count == 1 ? "1 request needs you" : "\(model.visibleNeedsYouCases.count) requests need you")
                    foldButton
                }
            }
        }
        .padding(EdgeInsets(
            // HAIL-180: the lockup starts at the left edge, on a row under the traffic lights.
            // The offline row keeps its old place.
            top: isOffline ? 16 : QueueHeaderLayout.topInset(trafficLightsMaxX: trafficLightsMaxX),
            leading: isOffline
                ? Theme.Spacing.listHeaderLeadingReserve
                : QueueHeaderLayout.leadingInset(trafficLightsMaxX: trafficLightsMaxX),
            bottom: Theme.AskDoc.Chrome.headBottom, trailing: Theme.AskDoc.Chrome.sideInset))
        .background(TrafficLightsEdgeReader { trafficLightsMaxX = $0 })
    }

    @ViewBuilder
    private var foldButton: some View {
        if let onFold {
            PanelFoldButton(edge: .leading, pointsRight: false, help: "Hide the queue (⌘[)", action: onFold)
        }
    }

    private var answeredSections: [AnswerGrouping.DaySection] {
        model.visibleAnsweredDaySections
    }

    /// "› ANSWERED · 73 ... SHOW" collapsed, "⌄ ANSWERED · 73 ... HIDE" open. Same caps style as the other headers.
    private func answeredHeader(count: Int) -> some View {
        SidebarFoldHeader(label: "Answered", count: count, isOpen: model.answeredOpen) { model.answeredOpen.toggle() }
    }

    private func daySectionHeader(_ section: AnswerGrouping.DaySection) -> some View {
        // B "ANSWERED TODAY · 6": the day sections inside Answered take the `.sec` look.
        ChromeSectionLabel(text: section.header)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.AskDoc.Chrome.sectionInset)
    }

    private func answeredRow(for item: Case) -> some View {
        let answeredAt = AnswerGrouping.answeredAt(item)
        return Button { Task { await model.open(caseId: item.id, source: .queue) } } label: { AnsweredRowView(
            item: item,
            ageLabel: answeredAt.map { CaseTimes.agoLabel(since: $0, now: model.now) } ?? "",
            ageTooltip: answeredAt.map { "Answered \(CaseTimes.arrivalTooltip(for: $0))" },
            isSelected: item.id == model.selectedCaseId,
            onDismiss: { requestDismiss(item) }
        ) }
        .buttonStyle(.hoverRow)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.id == model.selectedCaseId ? .isSelected : [])
    }

    private var cachedLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "cloud.slash")
                .font(.system(size: 10))
                .foregroundColor(Theme.Colors.ink3)
            Text("CACHED · READ-ONLY")
                .knockTextStyle(Theme.Typography.cachedLabel11w600)
                .foregroundColor(Theme.Colors.ink3)
        }
        .padding(Theme.AskDoc.Chrome.sectionInset)
    }

    /// The eight examples while there is nothing yet (WAG-338). A filtered or offline queue keeps its one line.
    @ViewBuilder private var emptyState: some View {
        if model.sessionFilter == nil && !isOffline {
            QueueEmptyStateView()
        } else {
            Text(model.sessionFilter != nil ? "No decisions from this session." : "No cached cases.")
                .knockTextStyle(Theme.Typography.body13w400)
                .foregroundColor(Theme.Colors.ink2)
                .padding(EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18))
        }
    }

    /// The sidebar's footer row (HAIL-50 contract: "a footer row (top
    /// hairline): status dot + 'Connected · N sessions' (or the offline
    /// state it already knows), and a 28 pt gear button ... opening the
    /// Settings window"). `⌘,` and the Knock menu keep reaching the same
    /// `Settings` scene through SwiftUI's own command, unaffected by this
    /// button.
    private var footer: some View {
        HStack(spacing: Theme.AskDoc.Chrome.footerGap) {
            QueueFooterSessionStatus(
                connection: connection, activeCases: model.activeCases, isOffline: isOffline,
                onToggle: { toggleSessions() },
                buttonBackground: frameReader { sessionsButtonFrame = $0 })
            Spacer(minLength: 8)
            Button(action: { openSettings() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Colors.ink3)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help("Settings  ⌘,")
        }
        // `.side-foot`: padding 12 16; the gear keeps 22 pt, so the row pads 2 less above and below.
        .padding(EdgeInsets(top: 10, leading: Theme.AskDoc.Chrome.sideInset, bottom: 10, trailing: 10))
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .top)
        .task {
            await connection.start()
            // Evidence hook: `KNOCK_SESSIONS_PANEL=list` or `detail:<n>` opens the
            // panel at launch, since a capture run cannot click the footer.
            if Self.evidencePanelRequested, !sessionsOpen { openSessions() }
        }
    }

    private static var evidencePanelRequested: Bool {
        ProcessInfo.processInfo.environment["KNOCK_SESSIONS_PANEL"] != nil
    }

    private static var evidenceDetailIndex: Int? {
        guard let raw = ProcessInfo.processInfo.environment["KNOCK_SESSIONS_PANEL"], raw.hasPrefix("detail:") else { return nil }
        return Int(raw.dropFirst("detail:".count))
    }

    // MARK: - Sessions panel (HAIL-59)

    private func toggleSessions() {
        if sessionsOpen {
            closeSessions()
        } else {
            model.usage.record(.sessionsPanelOpened)
            openSessions()
        }
    }

    private func openSessions() {
        sessionsOpen = true
        dismissMonitor.start(
            insideFrames: { [sessionsPanelFrame, sessionsButtonFrame] in [sessionsPanelFrame, sessionsButtonFrame] },
            onClose: { closeSessions() }
        )
    }

    private func closeSessions() {
        sessionsOpen = false
        dismissMonitor.stop()
    }

    @ViewBuilder
    private var sessionsPanel: some View {
        if sessionsOpen {
            GeometryReader { proxy in
                SessionsPopoverView(
                    model: model,
                    connection: connection,
                    onClose: { closeSessions() },
                    onOpenSettings: {
                        closeSessions()
                        NotificationCenter.default.post(name: .knockShowAgentsSettings, object: nil)
                        openSettings()
                    },
                    windowHeight: proxy.size.height,
                    initialDetailIndex: Self.evidenceDetailIndex
                )
                .background(frameReader { sessionsPanelFrame = $0 })
                .padding(EdgeInsets(top: 0, leading: 14, bottom: SessionsPanelLayout.footerReserve, trailing: 0))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    /// Reports a view's frame in the window content's coordinates.
    private func frameReader(_ onChange: @escaping (CGRect) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.frame(in: .global)) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in onChange(frame) }
        }
    }
}

/// The footer's status dot or grid, "Connected · N sessions" and "N working" (HAIL-50, HAIL-66). Its own view
/// so the sessions poll re-renders these few views, not the whole queue.
private struct QueueFooterSessionStatus<ButtonBackground: View>: View {
    @ObservedObject var connection: ConnectionModel
    let activeCases: [Case]
    let isOffline: Bool
    let onToggle: () -> Void
    let buttonBackground: ButtonBackground

    private var statuses: [AgentStatus] {
        connection.liveSessions.map { AgentStatus.forSession($0, cases: activeCases) }
    }

    var body: some View {
        let workingCount = AgentStatus.workingCount(statuses)
        if isOffline || connection.liveSessions.isEmpty {
            Circle()
                .fill(isOffline ? Theme.Colors.daemonOfflineDot : Theme.Colors.ok)
                .frame(width: Theme.AskDoc.Chrome.dotSize, height: Theme.AskDoc.Chrome.dotSize)
        } else {
            // One grid for the busiest live session (HAIL-66).
            let busiest = AgentStatus.busiest(statuses)
            PixelStatusGrid(pattern: busiest.pattern, color: busiest.color, cell: 3)
                .help(busiest.label)
        }
        Button(action: onToggle) {
            Text(QueueFooterStatus.label(isOffline: isOffline, sessionCount: QueueFooterStatus.liveCount(connection.sessions)))
                .knockTextStyle(Theme.AskDoc.Chrome.footer)
                .foregroundColor(Theme.Colors.ink3)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .disabled(isOffline)
        .background(buttonBackground)
        if !isOffline, workingCount > 0 {
            Text("· \(workingCount) working")
                .knockTextStyle(Theme.AskDoc.Chrome.footer)
                .foregroundColor(Theme.Colors.ink3)
                .lineLimit(1)
        }
    }
}
