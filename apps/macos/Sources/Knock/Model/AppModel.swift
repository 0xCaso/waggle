import Foundation
import Combine

/// The Undo toast's own subject (HAIL-32): the dismissed case's id (for
/// `case.restore`) and title (for the toast's copy).
struct DismissUndo: Equatable, Sendable {
    let caseId: String
    let title: String
}

/// The "Sent" toast's subject (HAIL-79): the answered ask and what was sent.
/// `id` is new for every send, so the view restarts its timer for a second
/// toast that replaces the first.
struct SentToast: Equatable, Sendable {
    let id: UUID
    let answeredCaseId: String
    let title: String
    /// What the operator sent, as one line (choice label, or the typed text).
    let answer: String

    /// Where the reply is, for the toast's copy and buttons.
    enum Phase: Equatable, Sendable { case queued, delivered, failed }

    /// The phase from the newest delivery event, else from the case's own
    /// reply state (which survives a relaunch).
    static func phase(lockState: ReplyLockState, delivery: DeliveryState?) -> Phase {
        switch delivery {
        case .delivered?: return .delivered
        case .failed?: return .failed
        default: break
        }
        switch lockState {
        case .delivered: return .delivered
        case .failed: return .failed
        case .queued, .editable: return .queued
        }
    }
}

/// Owns the `KnockClient` connection, mirrors its state onto the main actor
/// for SwiftUI, and re-fetches the case list on every event or reconnect.
///
/// The lists held in `needsYouCases`/`waitingOnAgentCases` are the "cached
/// read-only list" M11 shows while the socket is unreachable: they are
/// simply whatever was last fetched while connected, kept in memory (not
/// written to disk) until a fresh fetch replaces them.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var needsYouCases: [Case] = [] {
        didSet { if oldValue != needsYouCases { regroupAnswered() } }
    }
    /// Every case the daemon has as `waiting_on_agent`, answered ones too.
    /// The queue shows it as two groups (`stillWaitingCases`, `answeredCases`).
    @Published private(set) var waitingOnAgentCases: [Case] = [] {
        didSet { if oldValue != waitingOnAgentCases { regroupAnswered() } }
    }
    /// Cases an "Ask less" rule decided today (WAG-412), newest first. Empty while the feature is off. They are never in
    /// `needsYouCases`, so they raise no badge and no notification.
    @Published private(set) var autoDecidedToday: [Case] = []
    /// The folded "Decided for you" row of the queue: open or folded. Folded by default.
    @Published var autoDecidedOpen = false
    /// True once the daemon said the feature is on, or a decided case exists. While false the app asks nothing about it.
    private var tracksAutoDecided = false

    /// The part of `waitingOnAgentCases` that is really waiting (HAIL-64,
    /// `AnswerGrouping.staysWaiting`), newest first. Recomputed when the
    /// lists or the clock change, not on every read: the rule parses dates.
    @Published private(set) var stillWaitingCases: [Case] = []
    /// The rest of `waitingOnAgentCases`: answered asks, newest answer first.
    @Published private(set) var answeredCases: [Case] = []
    /// `answeredCases` cut into day sections (`AnswerGrouping.daySections`), stored so the queue's
    /// body reads it instead of walking 300 cases on every evaluation.
    @Published private(set) var answeredDaySections: [AnswerGrouping.DaySection] = []
    /// The "All caught up" stats, stored for the same reason (see `CaughtUpStats`).
    @Published private(set) var caughtUpStats = CaughtUpStats.Values(
        answeredToday: 0, medianTimeToDecideTodaySeconds: nil, agentsRunning: 0)
    /// Home's "What your agents are doing" cards (HAIL-191).
    @Published private(set) var homeOverview: HomeCards.Overview = .empty
    private var sessionsObservation: AnyCancellable?
    /// WAG-375: counts the sends of this model while the layout log is on.
    private var layoutWatch: AnyCancellable?
    /// True while `refreshCases` assigns both lists: the regroup runs once, after the second one.
    private var regroupSuspended = false
    private var regroupPending = false
    /// How many times the regroup ran, for the test that pins "once per refresh".
    private(set) var regroupCount = 0
    /// Whether the queue's "Answered" group is open. Remembered in
    /// UserDefaults (`AnsweredGroupSettings`).
    @Published var answeredOpen: Bool {
        didSet { AnsweredGroupSettings.setOpen(answeredOpen, defaults: defaults) }
    }
    /// Artifact kind keyed by case id, for the row's Prototype/Screenshot
    /// indicator. Read from each `cases.list` row's `artifact_kind` (PERF-4), written once per
    /// refresh. `artifact.path` is only the fallback for a case opened without a kind on its row.
    @Published private(set) var artifactKindByCaseId: [String: ArtifactKind] = [:]
    /// The confirmed delivery outcome of a case's most recent reply, keyed
    /// by case id, once it is known - only `.delivered`/`.failed`, and only
    /// once a `reply.state_changed` event names this case (Amendment 2,
    /// KNOCK-13 fold). Shown in `CasePaneView` and `QueueRowView` for a
    /// `waiting_on_agent` case: by the time this arrives the review
    /// workspace has usually already closed, so `DeliveryStateViewModel`
    /// (composer-scoped, discarded with it) cannot be where this lives.
    /// Cleared when the case cycles back to `needsYouCases` (a new
    /// revision), since a stale outcome would describe a reply that is no
    /// longer the case's open question.
    @Published private(set) var deliveryStatusByCaseId: [String: DeliveryState] = [:]
    /// The most recently dismissed case, while its Undo toast is still shown
    /// (HAIL-32): `nil` once the toast's 5 s expire or `undoDismiss()` fires.
    @Published private(set) var dismissUndo: DismissUndo?
    @Published private(set) var connectionState: KnockClient.ConnectionState = .connecting
    @Published private(set) var selectedCaseId: String?
    @Published private(set) var selectedCaseDetail: CaseDetail?
    @Published private(set) var lastErrorMessage: String?
    /// Ticks once a minute so idle-time labels stay current without a
    /// per-row timer (AC: "idle 18m, updating every minute").
    @Published private(set) var now: Date = Date() {
        didSet { regroupAnswered() }
    }
    /// Live agent sessions, reported by the queue sidebar's `ConnectionModel`
    /// poll (the footer's "Connected · N sessions").
    @Published var liveSessionCount: Int = 0 {
        didSet { if oldValue != liveSessionCount { recomputeCaughtUp() } }
    }
    /// The live sessions' parent pids by task id (HAIL-76), from the same poll,
    /// so "Show the terminal" can find a session's terminal app.
    @Published var sessionPidByTaskId: [String: Int] = [:]
    /// Live sessions that can be nudged, by task id (HAIL-76), from the same poll.
    @Published var canNudgeByTaskId: [String: Bool] = [:]
    /// The title each task's row shows (`SessionTitle.forTask`), from the same poll. The rows read this, not
    /// the session list, so a heartbeat that only moves `lastSeenAt` does not re-render the queue.
    @Published var sessionTitleByTaskId: [String: String] = [:]
    /// The sessions by task id (HAIL-102), for the session line above an ask. Live ones win.
    /// Refreshed when an ask opens and once a minute.
    @Published private(set) var sessionByTaskId: [String: SessionInfo] = [:]
    /// The nudges the app sent, by case id (HAIL-76).
    @Published private(set) var nudgeRecords: [String: NudgeRecord] = [:]
    /// Set when the human activates a review case (click or Return on
    /// "Open review ↵"). Non-nil while the review workspace (KNOCK-10) is
    /// open for this case; `MainWindowView` swaps the queue/case-pane split
    /// for `ReviewWorkspaceView` while this is set.
    @Published private(set) var reviewRequestCaseId: String?
    /// True when the review window was opened from the conversation's
    /// "v<N> · see in review" link (HAIL-71): it opens on the older version.
    @Published private(set) var reviewOpensOnPriorRevision = false
    /// WAG-397: the review opens on the Comments tab (an unread mark or a comment notification opened the case).
    @Published private(set) var reviewOpensOnComments = false
    /// WAG-352: the revision full size opens on, when the case box was following the decisions. `nil`: the newest.
    @Published private(set) var reviewOpensOnRevision: Int?
    /// Set when Comment in the case box opened the review (WAG-347): it starts in Comment mode on this page.
    @Published private(set) var reviewCommentHandoff: CommentHandoff?
    /// The "Sent" toast's subject, while it is showing (HAIL-79). One at a
    /// time: a new send replaces it.
    @Published private(set) var sentToast: SentToast?
    /// Set by the toast's "Change answer": the answered case's pane starts
    /// the Change answer flow once it shows that case, then clears this.
    @Published private(set) var changeAnswerRequestCaseId: String?

    /// One `NotificationContent` per `case.created` event for a case that
    /// landed in `needs_you` (KNOCK-09 contract: "On `case.created` for a
    /// `needs_you` case: one notification"). Not `case.updated` or
    /// `revision.added` - those can also return a case to `needs_you` (a
    /// `knock_update` does notify since HAIL-67, see `notifyIfUpdated`)
    /// (docs/protocol-mvp.md "Case and reply states"), but the contract
    /// notifies only on creation. `KnockAppDelegate` is this stream's one
    /// consumer.
    let caseNotifications: AsyncStream<NotificationContent>
    /// Unseen team comments by case id (WAG-394). The queue row shows a mark for a case in this map.
    @Published private(set) var unreadByCaseId: [String: Int] = [:]
    private(set) var teamComments: TeamCommentsFeed!
    private let caseNotificationsContinuation: AsyncStream<NotificationContent>.Continuation

    /// Cases ordered exactly as the queue renders them: `needsYouCases`
    /// then `waitingOnAgentCases`, both newest first (docs/stories/HAIL-34.md
    /// operator amendment, 2026-09-28: "the most recent ask on top"). Keyboard
    /// up/down (and j/k) move through this order.
    var orderedCases: [Case] { needsYouCases + waitingOnAgentCases }

    /// The queue's session filter (HAIL-59): set by a session's "Show its
    /// asks in the list", cleared by the chip's Clear. Never persisted.
    @Published var sessionFilter: SessionFilter?

    /// The queue as shown: `needsYouCases`/`waitingOnAgentCases` narrowed to
    /// the filtered session's task, or all of them with no filter.
    /// Whether the queue has anything to fold (HAIL-91): Needs you or Answered is not empty.
    var hasQueueContent: Bool {
        QueueFold.hasContent(needsYouCount: needsYouCases.count, answeredCount: answeredCases.count)
    }

    var visibleNeedsYouCases: [Case] { sessionFilter?.apply(needsYouCases) ?? needsYouCases }
    var visibleWaitingCases: [Case] { sessionFilter?.apply(stillWaitingCases) ?? stillWaitingCases }
    var visibleAnsweredCases: [Case] { sessionFilter?.apply(answeredCases) ?? answeredCases }

    /// The asks that count for session-level counts and statuses (HAIL-81):
    /// needs-you plus the really-waiting ones. Answered asks are left out.
    var activeCases: [Case] { needsYouCases + stillWaitingCases.filter { !$0.isDone } }

    private func regroupAnswered() {
        guard !regroupSuspended else {
            regroupPending = true
            return
        }
        regroupCount += 1
        let split = AnswerGrouping.split(waiting: waitingOnAgentCases, allCases: needsYouCases + waitingOnAgentCases, now: now)
        // Skip the assignment when nothing moved: a `@Published` write
        // re-renders the whole queue, and the clock ticks every minute.
        if split.waiting != stillWaitingCases { stillWaitingCases = split.waiting }
        if split.answered != answeredCases { answeredCases = split.answered }
        let sections = AnswerGrouping.daySections(answeredCases, now: now)
        if sections != answeredDaySections { answeredDaySections = sections }
        recomputeCaughtUp()
        recomputeHomeOverview()
    }

    private func recomputeCaughtUp() {
        let stats = CaughtUpStats.compute(waitingOnAgentCases: waitingOnAgentCases, liveSessionCount: liveSessionCount, now: now)
        if stats != caughtUpStats { caughtUpStats = stats }
    }

    private func recomputeHomeOverview() {
        let overview = HomeCards.build(
            allCases: orderedCases, activeCases: activeCases, sessions: sessionsModel.sessions, now: now)
        if overview != homeOverview { homeOverview = overview }
    }

    /// The Answered group's day sections for what the queue shows: the stored ones, or a fresh cut
    /// of the filtered list while a session filter is on.
    var visibleAnsweredDaySections: [AnswerGrouping.DaySection] {
        sessionFilter == nil ? answeredDaySections : AnswerGrouping.daySections(visibleAnsweredCases, now: now)
    }

    let client: KnockClient
    /// What agents bring the person (HAIL-193). One model for Settings › Requests, the menu bar switch
    /// and setup, so a pick in one place shows in the others.
    let askPreferences: AskPreferencesModel
    /// The one session list behind the footer count, its grid and the Sessions
    /// panel. Owned here, not by a view: the queue column is rebuilt when the
    /// layout changes, and a model built with it started empty (HAIL-105).
    let sessionsModel: ConnectionModel
    /// Where every "what people click" record goes (HAIL-83).
    let usage: UsageReporter
    /// Unsent answers of the asks with questions, kept while you look at another ask (WAG-287).
    let askDocMemory = AskDocMemory()
    private let defaults: UserDefaults
    /// Shared across every case's review workspace (docs/protocol-mvp.md:
    /// "On reconnect it re-submits with the same key") so a reconnect can
    /// resubmit a reply saved locally even for a case whose workspace is not
    /// currently open.
    let sendCoordinator: SendCoordinator

    /// WAG-280: one comment store per case. The case page, its side panel, the full page, an own window
    /// and the review workspace all read and write this one, so a pin placed on one surface shows on
    /// the others and goes out with the one reply.
    private let commentStores = CaseCommentStores()

    func commentsStore(forCase id: String) -> CommentsSessionStore { commentStores.store(forCase: id, usage: usage) }
    private var backgroundTasks: [Task<Void, Never>] = []
    /// The in-flight background resubmission batch, if any - see
    /// `startResubmission`. Not part of `backgroundTasks`: those are the
    /// long-lived loops `stop()` cancels; this one is short-lived and
    /// self-clears via its own completion, but `stop()` still cancels it so
    /// a resubmit does not outlive a stopped `AppModel`.
    private var resubmissionTask: Task<Void, Never>?
    /// Clears `dismissUndo` 5 s after a dismiss, unless `undoDismiss()` fires
    /// first. Cancelled and replaced by a later dismiss, and cancelled by
    /// `stop()` so it never outlives a stopped `AppModel`.
    private var dismissUndoTask: Task<Void, Never>?
    /// Revision count of the artifact-kind cache entry, so a later
    /// revision (which might restage a different kind) invalidates it. Used by the
    /// `artifact.path` fallback only.
    private var artifactRevisionCountByCaseId: [String: Int] = [:]
    /// The last full `CaseDetail` of the most recently opened cases (HAIL-47, bounded by PERF-4):
    /// `open(caseId:)` draws the pane from this the instant a row is clicked, before its own
    /// revalidating `cases.get` returns. Holds at most `caseDetailCacheLimit` cases, least
    /// recently used out first, so memory no longer grows with the queue. `open(caseId:)`
    /// revalidates unless the entry is fresh (PERF-5: no event named the case since its read).
    /// Write through `cacheDetail`.
    private var caseDetailCache: [String: CaseDetail] = [:]
    private var caseDetailCacheOrder: [String] = []
    var caseDetailCacheLimit = 8

    private func cacheDetail(_ detail: CaseDetail) {
        let id = detail.case.id
        caseDetailCache[id] = detail
        caseDetailCacheOrder.removeAll { $0 == id }
        caseDetailCacheOrder.append(id)
        while caseDetailCacheOrder.count > caseDetailCacheLimit {
            caseDetailCache.removeValue(forKey: caseDetailCacheOrder.removeFirst())
        }
    }

    private func dropCachedDetail(_ id: String) {
        caseDetailCache.removeValue(forKey: id)
        caseDetailCacheOrder.removeAll { $0 == id }
    }

    /// Number of cases whose detail the app holds (tests).
    var cachedDetailCount: Int { caseDetailCache.count }
    /// `KNOCK_OPEN_CASE`, opened once the first `cases.list` has loaded, then
    /// cleared so a later reconnect never reopens it. This is the evidence
    /// hook for launch-time deep links; KNOCK-09 notifications will call
    /// `open(caseId:)` the same way once a case is already selectable.
    private var pendingOpenCaseId: String?
    /// `KNOCK_OPEN_REVIEW=1` alongside `KNOCK_OPEN_CASE` (Amendments): opens
    /// that case straight into the review workspace at launch, since the
    /// orchestrator cannot send the click/Return that normally activates it.
    private let pendingOpenReview: Bool
    /// Forwarded to `NotificationBuilder.content` for the "[test] " title
    /// prefix (docs/stories/HAIL-34.md operator report 21:51). Same
    /// injectable-`ProcessInfo`/`Bundle.main` pattern as `TestCopyEnvironment.
    /// isActive`: a unit test runs inside the test runner's own bundle, never
    /// the app's, so it must be able to say "pretend this is the release
    /// bundle" without touching `Bundle.main` itself.
    private let notificationEnvironment: [String: String]
    private let notificationBundleIdentifier: String?
    /// "Remind me if an ask waits" (Contract): `AskReminderScheduler`'s own
    /// state, reconciled on every case-list refresh and once a minute off
    /// `runClock` so a reminder still fires 15 minutes into a quiet case
    /// with no new event to trigger a reconcile.
    private var reminderPending: [String: Date] = [:]
    private var remindedCaseIds: Set<String> = []

    init(
        client: KnockClient, environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard,
        usage: UsageReporter? = nil
    ) {
        self.client = client
        self.askPreferences = AskPreferencesModel(client: client)
        self.sessionsModel = ConnectionModel(client: client)
        self.usage = usage ?? UsageReporter(client: client)
        self.defaults = defaults
        // `KNOCK_EVIDENCE_ANSWERED_OPEN=1` (HAIL-144 evidence): open the Answered group for one run
        // without writing the setting (an init assignment skips `didSet`).
        self.answeredOpen = AnsweredGroupSettings.isOpen(defaults: defaults)
            || environment["KNOCK_EVIDENCE_ANSWERED_OPEN"] == "1"
        // `KNOCK_EVIDENCE_DECIDED_OPEN=1` (WAG-412 evidence): the "Decided for you" list starts open.
        self.autoDecidedOpen = environment["KNOCK_EVIDENCE_DECIDED_OPEN"] == "1"
        self.sendCoordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: environment))
        self.pendingOpenCaseId = environment["KNOCK_OPEN_CASE"]
        // WAG-358: comments of a sent reply never stay pending for a later round.
        sendCoordinator.onDelivered = { [commentStores] reply in
            commentStores.store(forCase: reply.caseId).dropSent(commentIds: Set(reply.comments.map(\.id)))
        }
        (self.caseNotifications, self.caseNotificationsContinuation) = AsyncStream.makeStream()
        self.pendingOpenReview = environment["KNOCK_OPEN_REVIEW"] == "1"
        self.notificationEnvironment = environment
        self.notificationBundleIdentifier = bundleIdentifier
        let continuation = self.caseNotificationsContinuation
        self.teamComments = TeamCommentsFeed(
            unread: { try await client.sharingUnread() },
            markSeen: { try await client.sharingMarkSeen(caseId: $0) },
            take: { try await client.sharingTakeNotifications() },
            gate: { NotificationQuestionSettings.isShown() },
            notify: { continuation.yield($0) },
            onUnread: { [weak self] in if self?.unreadByCaseId != $0 { self?.unreadByCaseId = $0 } },
            environment: environment, bundleIdentifier: bundleIdentifier
        )
        layoutWatch = EvidenceLayoutLog.watch(self, as: "send.appModel")
        sessionsObservation = sessionsModel.$sessions.sink { [weak self] _ in
            // `@Published` fires in willSet: read the new list on the next turn.
            Task { @MainActor in
                guard let self else { return }
                self.mirrorSessions(self.sessionsModel.sessions)
                self.recomputeHomeOverview()
            }
        }
    }

    /// Copies what the queue needs from the live sessions: their count, parent pids and nudge flags (HAIL-76).
    /// It lives here, not in a view's `onChange`, and writes only a value that changed. A `@Published` write
    /// sends even when the value is equal, and every send re-renders each view that reads this model (WAG-363).
    func mirrorSessions(_ sessions: [SessionInfo]) {
        let live = ConnectionModel.live(sessions)
        let pids = Dictionary(live.compactMap { s in s.pid.map { (s.taskId, $0) } }, uniquingKeysWith: { first, _ in first })
        let nudges = Dictionary(live.map { ($0.taskId, $0.canNudge) }, uniquingKeysWith: { first, _ in first })
        if liveSessionCount != live.count { liveSessionCount = live.count }
        if sessionPidByTaskId != pids { sessionPidByTaskId = pids }
        if canNudgeByTaskId != nudges { canNudgeByTaskId = nudges }
        var titles: [String: String] = [:]
        for taskId in Set(sessions.map(\.taskId)) {
            if let title = SessionTitle.forTask(taskId, in: sessions) { titles[taskId] = title }
        }
        if sessionTitleByTaskId != titles { sessionTitleByTaskId = titles }
    }

    /// The person opened an ask's preview full size (`artifactOpenedFull`) or
    /// its review (`reviewOpened`) from the case pane (HAIL-83). Once per ask
    /// opening; an ask with no artifact reports nothing.
    func recordPreviewOpen(_ event: UsageEvent, caseId: String, artifactKind: ArtifactKind?) {
        guard let artifactKind else { return }
        usage.recordOnce(event, caseId: caseId, artifactKind: artifactKind, timed: true)
    }

    /// The person clicked in the inline preview card without opening it (HAIL-83).
    func recordPreviewInteraction(caseId: String, artifactKind: ArtifactKind?) {
        guard let artifactKind else { return }
        usage.recordOnce(.previewInteracted, caseId: caseId, artifactKind: artifactKind)
    }

    /// "Copy prompt" was clicked in a pickup fallback (HAIL-83).
    func copiedPrompt() { usage.record(.copyPromptClicked) }

    /// Asks the daemon to nudge the session that owns `caseId` (HAIL-76). Only
    /// reachable from the nudge control, which shows only for a session that can
    /// be nudged.
    func nudge(caseId: String) {
        guard nudgeRecords[caseId]?.sending != true else { return }
        usage.record(.nudgeClicked)
        nudgeRecords[caseId, default: NudgeRecord()].sending = true
        Task { [weak self, client] in
            let result: NudgeResult
            do {
                result = try await client.sessionNudge(caseId: caseId)
            } catch {
                result = NudgeResult(sent: false, reason: .postFailed)
            }
            await MainActor.run {
                guard let self else { return }
                self.nudgeRecords[caseId] = (self.nudgeRecords[caseId] ?? NudgeRecord())
                    .applying(result, at: Date())
            }
        }
    }

    func start() {
        guard backgroundTasks.isEmpty else { return }

        backgroundTasks.append(Task { [client] in
            await client.start()
        })

        backgroundTasks.append(Task { [sessionsModel] in
            await sessionsModel.start()
        })

        // HAIL-138: the plugin checklist learns from the sessions and asks the app already holds.
        backgroundTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                PluginOfferModel.shared.observe(sessions: self.sessionsModel.sessions, cases: self.orderedCases)
                try? await Task.sleep(for: .seconds(2))
            }
        })

        backgroundTasks.append(Task { [weak self, client] in
            for await state in client.connectionStates {
                guard let self else { return }
                self.connectionState = state
                if state == .connected {
                    await self.onConnected()
                }
            }
        })

        backgroundTasks.append(Task { [weak self, client] in
            for await event in client.events {
                guard let self else { return }
                self.enqueue(event)
            }
        })

        backgroundTasks.append(Task { [weak self] in
            await self?.runClock()
        })

        // WAG-412: the Ask less page turned the master on or off.
        backgroundTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .knockAskLessChanged) {
                guard let self else { return }
                await self.askLessChanged(enabled: (note.object as? Bool) ?? false)
            }
        })

        // Evidence-only (HAIL-76): `KNOCK_EVIDENCE_NUDGE=<seconds>:<case id>` does
        // what a click on "Nudge" does, since a capture run cannot click. It goes
        // through the real `session.nudge` call.
        if let spec = notificationEnvironment["KNOCK_EVIDENCE_NUDGE"],
           let colon = spec.firstIndex(of: ":"), let delay = Double(spec[..<colon]) {
            let caseId = String(spec[spec.index(after: colon)...])
            backgroundTasks.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.nudge(caseId: caseId)
            })
        }
    }

    #if DEBUG
    /// Lets a view test show the connected pane without a socket (WAG-257).
    func setConnectionStateForTests(_ state: KnockClient.ConnectionState) { connectionState = state }
    #endif

    func stop() {
        for task in backgroundTasks { task.cancel() }
        backgroundTasks.removeAll()
        resubmissionTask?.cancel()
        resubmissionTask = nil
        refreshRetryTask?.cancel()
        refreshRetryTask = nil
        eventProcessor?.cancel()
        eventProcessor = nil
        eventBatch.removeAll()
        dismissUndoTask?.cancel()
        dismissUndoTask = nil
        reminderPending.removeAll()
        remindedCaseIds.removeAll()
        caseNotificationsContinuation.finish()
        Task { [client] in await client.stop() }
    }

    private func runClock() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            now = Date()
            reconcileReminders(now: now)
            await refreshSessions()
            // A missed or failed refresh must not leave the queue stale until the next
            // event: the daemon is the truth, so ask it again once a minute (HAIL-120).
            await reconcileCases()
        }
    }

    /// Loads the sessions with their context (HAIL-102). A failure keeps the last list.
    func refreshSessions() async {
        guard let list = try? await client.sessionsList() else { return }
        let live = list.filter { $0.state == .live }
        let byTask = Dictionary(
            (live + list.filter { $0.state != .live }).filter { !$0.taskId.isEmpty }.map { ($0.taskId, $0) },
            uniquingKeysWith: { first, _ in first })
        if byTask != sessionByTaskId { sessionByTaskId = byTask }
    }

    /// The session title for an ask's crumb (WAG-290), or nil when the folder name is all there is.
    func sessionTitle(for item: Case) -> String? {
        sessionByTaskId[item.taskId].flatMap(SessionTitle.pick)
    }

    /// The session line and the earlier asks for an ask (HAIL-102).
    func sessionContext(for item: Case) -> SessionContextBlock {
        SessionContextBlock.make(
            item: item, session: sessionByTaskId[item.taskId],
            cases: needsYouCases + waitingOnAgentCases, now: now)
    }

    /// Order on connect (AC): subscribe and load the case list first, every
    /// time - a relaunch with a pending reply on disk must never show "No
    /// cases yet" while the daemon holds real cases (the operator report
    /// this fixes). Pending-reply resubmission runs after, as its own
    /// detached background task (`startResubmission`): it never gates
    /// `subscribeEvents`/`refreshCases`/`open(caseId:)`, so a resubmit that
    /// times out or hangs cannot block them the way it used to.
    private func onConnected() async {
        // The session list first: the daemon may be new (restart, update), and
        // the footer must not wait for the poll tick to show it (HAIL-105).
        await sessionsModel.refresh()
        // Replace a daemon that is not this app's own version and binary
        // FIRST: an older daemon can fail the calls below (0.1.1 truncated
        // large responses), and a throw there must not skip the upgrade away
        // from it (operator report, 0.1.1 -> 0.1.2). A restart reconnects and
        // runs this again against the new daemon.
        await enforceOwnDaemon()
        // The event stream has no catch-up: events sent while disconnected are lost, so every cached detail may be old.
        for id in caseDetailCache.keys { invalidateDetail(id) }
        do {
            try await client.subscribeEvents()
            await probeAskLess()
            try await refreshCases()
            // WAG-394: comments that came in while the app was closed.
            Task { [teamComments] in
                await teamComments?.announce()
                await teamComments?.refreshUnread()
            }
            startResubmission()
            if let caseId = pendingOpenCaseId {
                pendingOpenCaseId = nil
                await open(caseId: caseId)
                if pendingOpenReview, let selected = selectedCaseDetail?.case,
                   Self.canOpenReview(kind: selected.kind, hasArtifact: selected.hasArtifact) {
                    reviewRequestCaseId = caseId
                }
            }
        } catch {
            lastErrorMessage = "\(error)"
            QueueLog.write("onConnected failed: \(error)", environment: notificationEnvironment)
            retryRefreshSoon()
        }
    }

    /// Fires `sendCoordinator.resubmitPending()` without awaiting it, so
    /// `onConnected` continues immediately regardless of how long it takes
    /// (each individual resubmit is itself bounded to 15s, but the whole
    /// batch is otherwise unawaited here). `knownCases` is this connect's own
    /// just-fetched list, so `resubmitPending` can drop an already-answered
    /// pending reply without a further round trip. Skips starting a second
    /// batch while one is still running (a flappy reconnect), rather than
    /// piling up concurrent resubmit attempts for the same files.
    private func startResubmission() {
        guard resubmissionTask == nil else { return }
        let cases = needsYouCases + waitingOnAgentCases
        resubmissionTask = Task { [weak self, sendCoordinator] in
            await sendCoordinator.resubmitPending(knownCases: cases)
            self?.resubmissionTask = nil
        }
    }

    /// HAIL-134: what to do when a Claude Code mod asks for a case (`case.open_requested`).
    /// The app wires it to opening the case and bringing the window forward.
    /// A nil case means "show the queue".
    var onOpenRequested: (String?) -> Void = { _ in }

    private var eventBatch: [Event] = []
    private var eventProcessor: Task<Void, Never>?

    /// Events that arrive while a batch is handled wait for the next one, and one refresh serves the
    /// whole batch (HAIL-153). Before, each event ran its own refresh in turn: a burst of events (session
    /// heartbeats, a busy agent) delayed a new ask's `case.created` by seconds.
    private func enqueue(_ event: Event) {
        eventBatch.append(event)
        guard eventProcessor == nil else { return }
        eventProcessor = Task { [weak self] in
            while let self, !self.eventBatch.isEmpty, !Task.isCancelled {
                let batch = self.eventBatch
                self.eventBatch = []
                await self.handle(batch)
            }
            self?.eventProcessor = nil
        }
    }

    /// Applies a batch of events (PERF-5). A session event touches no case data and is skipped. The
    /// case lists are re-read once, and only when an event can change them. Each case a batch names
    /// loses its fresh mark, and is re-read at most once, and only when the pane or a reply needs it.
    /// One step that throws never skips the steps after it.
    private func handle(_ events: [Event]) async {
        for event in events where event.type == .caseOpenRequested {
            onOpenRequested(event.caseId)
        }
        let events = events.filter { $0.type != .caseOpenRequested }
        guard !events.isEmpty else { return }
        await handleTeamComments(events)
        for event in events { logLateEvent(event) }
        let caseEvents = events.filter { $0.type != .sessionStateChanged && $0.type != .sessionNudged }
        // WAG-258: a session that ended or came back changes the "Session closed" mark of its cases. The
        // batch is one list read, never a read per case.
        let sessionChanged = events.contains { $0.type == .sessionStateChanged }
        guard !caseEvents.isEmpty else {
            if sessionChanged { await reconcileCases() }
            return
        }

        for event in caseEvents { if let caseId = event.caseId { invalidateDetail(caseId) } }
        let needsListRefresh = caseEvents.contains {
            $0.type == .caseCreated || $0.type == .caseUpdated || $0.type == .revisionAdded
        } || sessionChanged
        var failures = 0
        var listFailed = false
        let casesBefore = needsYouCases + waitingOnAgentCases
        if needsListRefresh {
            do { try await refreshCases() } catch {
                failures += 1
                listFailed = true
                lastErrorMessage = "\(error)"
            }
        }

        var created: Set<String> = []
        var updated: Set<String> = []
        var replies: [(caseId: String, replyId: String)] = []
        var reread: Set<String> = []
        for event in caseEvents {
            guard let caseId = event.caseId else { continue }
            if event.type == .caseUpdated, updated.insert(caseId).inserted, !listFailed {
                notifyIfUpdated(caseId: caseId, before: casesBefore)
            }
            if event.type == .caseCreated, created.insert(caseId).inserted, !listFailed {
                logMissingArrival(caseId: caseId)
                notifyIfNeedsYou(caseId: caseId)
            }
            if event.type == .replyStateChanged, let replyId = event.replyId {
                replies.append((caseId, replyId))
            } else if caseId == selectedCaseId {
                reread.insert(caseId)
            }
        }
        // One read per case, even when it has several events or is the selected one too.
        var read: Set<String> = []
        for (caseId, replyId) in replies {
            do {
                if read.insert(caseId).inserted, !freshDetailIds.contains(caseId) { _ = try await reloadDetail(caseId: caseId) }
                applyReplyOutcome(caseId: caseId, replyId: replyId)
            } catch {
                failures += 1
                lastErrorMessage = "\(error)"
                read.remove(caseId)
            }
        }
        for caseId in reread where caseId == selectedCaseId && !freshDetailIds.contains(caseId) {
            do { _ = try await reloadDetail(caseId: caseId) } catch {
                failures += 1
                lastErrorMessage = "\(error)"
            }
        }
        if failures > 0 {
            QueueLog.write("event batch of \(events.count): \(failures) step(s) failed", environment: notificationEnvironment)
        }
        if listFailed { retryRefreshSoon() }
    }

    /// WAG-394: a comment, reply or resolve on a shared case reloads that case's sharing model at once, so an
    /// open case shows it without reopening. A new team comment posts its notification. Unread marks follow.
    private func handleTeamComments(_ events: [Event]) async {
        var touched: Set<String> = []
        var announce = false
        for event in events where event.type == .caseUpdated || event.type == .commentAdded {
            if let caseId = event.caseId { touched.insert(caseId) }
            if event.type == .commentAdded { announce = true }
        }
        guard !touched.isEmpty else { return }
        for caseId in touched { await SharingModels.reload(caseId: caseId) }
        if announce { await teamComments.announce() }
        // A case that is open on screen has its comments seen as they arrive.
        for caseId in touched where caseId == selectedCaseId || caseId == reviewRequestCaseId {
            await teamComments.markSeen(caseId: caseId)
        }
        await teamComments.refreshUnread()
    }

    /// Evidence for the next "I see nothing" report (HAIL-153): an event the app handled late.
    private func logLateEvent(_ event: Event) {
        guard let at = KnockDateFormat.date(from: event.at) else { return }
        let lag = Date().timeIntervalSince(at)
        if let line = QueueLog.lateEventLine(type: event.type.rawValue, caseId: event.caseId, lagSeconds: lag) {
            QueueLog.write(line, environment: notificationEnvironment)
        }
    }

    /// A `case.created` ask that is in neither list after the refresh. It may be answered already; the line is evidence only.
    private func logMissingArrival(caseId: String) {
        let held = (needsYouCases + waitingOnAgentCases).contains { $0.id == caseId }
        if let line = QueueLog.missingArrivalLine(caseId: caseId, held: held) {
            QueueLog.write(line, environment: notificationEnvironment)
        }
    }

    /// Re-reads the case lists, and on a failure retries soon (HAIL-120). A failed read after
    /// a case event (a timeout, a reconnect in flight) used to leave the queue as it was, with
    /// the new ask missing, until some later event arrived.
    private func reconcileCases() async {
        do {
            try await refreshCases()
        } catch {
            QueueLog.write("refresh failed: \(error)", environment: notificationEnvironment)
            retryRefreshSoon()
        }
    }

    private var refreshRetryTask: Task<Void, Never>?
    /// Waits between retries of a failed read; a test shortens them.
    var refreshRetryDelays: [Double] = [2, 5, 15, 30]

    /// One retry loop at a time: waits `refreshRetryDelays` (2 s, 5 s, 15 s, 30 s) between tries, until a read works.
    private func retryRefreshSoon() {
        guard refreshRetryTask == nil else { return }
        let delays = refreshRetryDelays
        refreshRetryTask = Task { [weak self] in
            for delay in delays {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                if (try? await self.refreshCases()) != nil { break }
            }
            self?.refreshRetryTask = nil
        }
    }

    /// `reply.state_changed`'s outcome for the case pane and queue row
    /// (Amendment 2, KNOCK-13 fold): the event itself only names which reply
    /// changed, not to what - `cases.get` is the re-read the protocol
    /// prescribes ("The app re-reads with cases.get"). A `queued` reply
    /// (e.g. requeued by a retry started elsewhere) clears no existing
    /// entry and sets none - AC 8 never shows that as delivered.
    private func applyReplyOutcome(caseId: String, replyId: String) {
        guard let detail = caseDetailCache[caseId] else { return }
        guard let reply = detail.replies.first(where: { $0.id == replyId }) else { return }
        switch reply.state {
        case .delivered:
            deliveryStatusByCaseId[caseId] = .delivered(at: Date())
        case .failed:
            deliveryStatusByCaseId[caseId] = .failed(replyId: reply.id)
        // `.superseded` (HAIL-44) never reaches here: a superseded reply's
        // case is withdrawn (resolved) in the same write, so it has already
        // left needsYouCases/waitingOnAgentCases by the time this runs.
        case .queued, .superseded:
            break
        case .handedOver:
            deliveryStatusByCaseId.removeValue(forKey: caseId)
        }
    }

    /// WAG-410: after "Continue in a new session" started a session, the failed reply is handed over.
    /// The failure banner goes away at once; the list row follows the `reply.state_changed` event.
    func handOverFailedReply(caseId: String, failedReplyId: String? = nil) async {
        let replyId: String
        if case .failed(let id)? = deliveryStatusByCaseId[caseId] {
            replyId = id
        } else if let id = failedReplyId {
            replyId = id
        } else {
            return
        }
        do {
            _ = try await client.replyHandOver(replyId: replyId)
            deliveryStatusByCaseId.removeValue(forKey: caseId)
            try? await refreshCases()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// The case pane/queue row's Retry once a delivery is confirmed failed
    /// (docs/design/mvp-values.md §M8 panel 4): always `reply.retry`, never
    /// a second `reply.submit` - the reply already reached the daemon once,
    /// unlike the composer's offline Retry (`SendFlowController`), which
    /// never got that far.
    func retryDelivery(caseId: String) async {
        guard case .failed(let replyId)? = deliveryStatusByCaseId[caseId] else { return }
        do {
            let result = try await client.replyRetry(replyId: replyId)
            switch result.state {
            case .failed:
                deliveryStatusByCaseId[caseId] = .failed(replyId: result.id)
            // `.superseded` (HAIL-44) never reaches here: reply.retry only
            // ever moves a failed reply back to queued, never to superseded.
            case .queued, .delivered, .superseded, .handedOver:
                deliveryStatusByCaseId.removeValue(forKey: caseId)
            }
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// Dismisses a case (HAIL-32 "the row leaves the queue at once"): calls
    /// `case.dismiss`, then removes it from both lists immediately rather
    /// than waiting for the `case.updated` event this RPC also emits - the
    /// row's own Dismiss action should never wait on a round trip it already
    /// knows the outcome of. Clears the selection if this was the selected
    /// case, and starts (or restarts) the 5 s Undo toast.
    func dismiss(caseId: String) async {
        guard let item = orderedCases.first(where: { $0.id == caseId }) else { return }
        do {
            _ = try await client.caseDismiss(caseId: caseId)
            // HAIL-130: the daemon also closes the case this one replaced, so drop it here too.
            let closedIds = [caseId] + (item.replacesCaseId.map { [$0] } ?? [])
            needsYouCases.removeAll { closedIds.contains($0.id) }
            waitingOnAgentCases.removeAll { closedIds.contains($0.id) }
            for id in closedIds {
                deliveryStatusByCaseId.removeValue(forKey: id)
                dropCachedDetail(id)
                invalidateDetail(id)
            }
            reconcileReminders()
            if selectedCaseId == caseId {
                selectedCaseId = nil
                selectedCaseDetail = nil
            }
            dismissUndoTask?.cancel()
            dismissUndo = DismissUndo(caseId: caseId, title: item.title)
            dismissUndoTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.dismissUndo = nil
            }
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// The Undo toast's own action (HAIL-32): restores the case and lets the
    /// next `refreshCases()` (this triggers no event of its own to react to
    /// here, so the call is explicit) put it back in the right list.
    func undoDismiss() async {
        guard let undo = dismissUndo else { return }
        dismissUndo = nil
        dismissUndoTask?.cancel()
        dismissUndoTask = nil
        do {
            _ = try await client.caseRestore(caseId: undo.caseId)
            try await refreshCases()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// "Next ask" (Contract): after a reply is sent successfully - never for
    /// "Ask for more detail" (stays on the same ask) or a reply that only
    /// queued offline (also stays put) - selects the next `needsYouCases`
    /// case in the list's current order: the one below the answered ask,
    /// else the one above, else none. `SendFlowController.onAnswerSent`'s
    /// call sites are what keep those two cases from ever reaching here; see
    /// its own doc comment. A no-op when `answeredCaseId` is not itself in
    /// `needsYouCases` right now - true for "Change answer" on an
    /// already-queued reply, which left `needsYouCases` the moment it was
    /// first answered, long before this later edit; that case's pane stays
    /// exactly as it was (Preservation: "review window flows"). When
    /// `answeredCaseId` WAS the only `needsYouCases` case, there is no next
    /// ask to switch to - the selection clears instead, so the pane falls
    /// through to "All caught up" (Contract) rather than lingering on the
    /// case that just left `needsYouCases`.
    func advanceAfterSend(answeredCaseId: String, answer: String = "") {
        guard let answered = needsYouCases.first(where: { $0.id == answeredCaseId }) else { return }
        sentToast = SentToast(id: UUID(), answeredCaseId: answeredCaseId, title: answered.title, answer: answer)
        guard let nextId = Self.nextCaseId(afterAnswering: answeredCaseId, in: needsYouCases) else {
            selectedCaseId = nil
            selectedCaseDetail = nil
            return
        }
        Task { await open(caseId: nextId, source: .autoAdvance) }
    }

    /// Evidence only (HAIL-79): `KNOCK_EVIDENCE_SENT_TOAST=<answer>` waits for
    /// the oldest ask in the queue, then runs the same step a real send runs
    /// (`advanceAfterSend`), so the toast can be captured without clicking.
    /// The harness sends the real reply to the daemon afterwards, so the
    /// toast's phase still follows the real delivery.
    func presentEvidenceSentToastIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard let answer = environment["KNOCK_EVIDENCE_SENT_TOAST"], !answer.isEmpty else { return }
        for _ in 0..<100 {
            if let first = needsYouCases.last {
                advanceAfterSend(answeredCaseId: first.id, answer: answer)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Evidence only (HAIL-119): `KNOCK_EVIDENCE_GO_HOME=<seconds>` presses "← Home" after that delay.
    func presentEvidenceHomeIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) async {
        if let raw = environment["KNOCK_EVIDENCE_GO_HOME"], let seconds = Double(raw) {
            try? await Task.sleep(for: .seconds(seconds))
            goHome()
        }
    }

    /// Evidence only (WAG-345): `KNOCK_EVIDENCE_OPEN_ANSWERED=<seconds>` opens the newest answered ask after that
    /// delay, so a capture shows the person's reply with its files.
    func presentEvidenceOpenAnsweredIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard let raw = environment["KNOCK_EVIDENCE_OPEN_ANSWERED"], let seconds = Double(raw) else { return }
        try? await Task.sleep(for: .seconds(seconds))
        if let target = answeredCases.first ?? waitingOnAgentCases.first { await open(caseId: target.id, source: .queue) }
    }

    /// Pure next-case selection rule (Contract "Next ask"): the case below
    /// `caseId` in `cases`' own order, else the one above, else `nil` - when
    /// `caseId` has no neighbour on either side, or is not in `cases` at all.
    static func nextCaseId(afterAnswering caseId: String, in cases: [Case]) -> String? {
        guard let index = cases.firstIndex(where: { $0.id == caseId }) else { return nil }
        if index + 1 < cases.count { return cases[index + 1].id }
        if index > 0 { return cases[index - 1].id }
        return nil
    }

    /// The toast's phase now (HAIL-79), read from the live case and the
    /// newest delivery event. `.queued` when the case is in no list.
    var sentToastPhase: SentToast.Phase {
        guard let toast = sentToast else { return .queued }
        let id = toast.answeredCaseId
        let knockCase = waitingOnAgentCases.first { $0.id == id } ?? needsYouCases.first { $0.id == id }
            ?? (selectedCaseDetail?.case.id == id ? selectedCaseDetail?.case : nil)
        return SentToast.phase(lockState: knockCase?.replyLockState ?? .queued, delivery: deliveryStatusByCaseId[id])
    }

    /// The case as the lists hold it, with the session fields a session event changes (WAG-258): the
    /// open pane reads these instead of its cached detail, which no session event refreshes.
    func listedCase(id: String) -> Case? {
        needsYouCases.first { $0.id == id } ?? waitingOnAgentCases.first { $0.id == id }
    }

    /// Removes the toast, only if it is still the one the caller timed.
    func dismissSentToast(id: UUID) {
        guard sentToast?.id == id else { return }
        sentToast = nil
    }

    /// The toast's "Go back": reselects the case just answered and clears the
    /// toast at once, since it describes a switch the operator is undoing.
    func goBackFromSentToast() {
        guard let toast = sentToast else { return }
        sentToast = nil
        usage.record(.goBackClicked)
        Task { await open(caseId: toast.answeredCaseId) }
    }

    /// The toast's "Change answer" (queued only): goes back, then asks that
    /// case's pane to start the Change answer flow.
    func changeAnswerFromSentToast() {
        guard let toast = sentToast, sentToastPhase == .queued else { return }
        sentToast = nil
        changeAnswerRequestCaseId = toast.answeredCaseId
        Task { await open(caseId: toast.answeredCaseId) }
    }

    /// The pane calls this once it has acted on, or can no longer act on, the
    /// request.
    func clearChangeAnswerRequest() { changeAnswerRequestCaseId = nil }

    /// Feeds `caseNotifications` when `caseId` is (still, as of the
    /// `refreshCases()` that just ran) a `needs_you` case with a known task.
    /// Both lists come from the same fetch this event triggered, so no
    /// extra round trip is needed here.
    private func notifyIfNeedsYou(caseId: String) {
        guard let newCase = needsYouCases.first(where: { $0.id == caseId }),
              case let task = newCase.knockTask else { return }
        caseNotificationsContinuation.yield(NotificationBuilder.content(
            for: newCase, task: task, showsQuestion: NotificationQuestionSettings.isShown(),
            environment: notificationEnvironment, bundleIdentifier: notificationBundleIdentifier
        ))
    }

    /// Whether `after` is a new update on a case that `before` knew: it has an
    /// update to show, and `before` had none or an older one. A dismiss or a
    /// restore also sends `case.updated`, but leaves `latest_update_at` alone,
    /// so it never notifies. A case `before` did not have is a new ask.
    static func isNewUpdate(_ after: Case, before: [Case]) -> Bool {
        guard let update = after.pendingUpdate,
              let previous = before.first(where: { $0.id == after.id }) else { return false }
        guard let oldAt = previous.latestUpdateAt.flatMap(KnockDateFormat.date(from:)) else { return true }
        return update.at > oldAt
    }

    /// "Updated: <title>" for an ask an agent sent an update on (HAIL-67).
    /// Same stream, settings and test-copy prefix as a new ask's notification.
    private func notifyIfUpdated(caseId: String, before: [Case]) {
        guard let updated = needsYouCases.first(where: { $0.id == caseId }),
              Self.isNewUpdate(updated, before: before),
              let content = NotificationBuilder.updateContent(
                for: updated, showsQuestion: NotificationQuestionSettings.isShown(),
                environment: notificationEnvironment, bundleIdentifier: notificationBundleIdentifier
              ) else { return }
        caseNotificationsContinuation.yield(content)
    }

    /// Reconciles `AskReminderScheduler`'s pure state against the current
    /// `needsYouCases` and fires (yields onto the same `caseNotifications`
    /// stream `notifyIfNeedsYou` uses) whatever it says is due. Called after
    /// every `refreshCases()` (an event may have just answered or dismissed
    /// a case out of `needs_you`, which should cancel its reminder at once)
    /// and once a minute from `runClock` (so a reminder still fires with no
    /// new event to trigger a reconcile).
    private func reconcileReminders(now: Date = Date()) {
        let outcome = AskReminderScheduler.reconcile(
            needsYouCaseIds: Set(needsYouCases.map(\.id)),
            pending: reminderPending,
            reminded: remindedCaseIds,
            enabled: NotificationReminderSettings.isEnabled(),
            now: now
        )
        reminderPending = outcome.pending
        remindedCaseIds = outcome.reminded
        for caseId in outcome.due {
            remindIfNeedsYou(caseId: caseId)
        }
    }

    /// A reminder's content is the same `NotificationBuilder.content` a
    /// fresh ask gets (same hide-question rule), under a distinct identifier
    /// so it lands as its own item in Notification Center rather than
    /// replacing the original.
    private func remindIfNeedsYou(caseId: String) {
        guard let newCase = needsYouCases.first(where: { $0.id == caseId }),
              case let task = newCase.knockTask else { return }
        let base = NotificationBuilder.content(
            for: newCase, task: task, showsQuestion: NotificationQuestionSettings.isShown(),
            environment: notificationEnvironment, bundleIdentifier: notificationBundleIdentifier
        )
        caseNotificationsContinuation.yield(NotificationContent(
            identifier: "\(base.identifier).reminder",
            caseId: base.caseId,
            title: base.title,
            subtitle: base.subtitle,
            body: base.body
        ))
    }

    /// Sets both lists. One regroup for the pair, and none when neither list changed.
    func applyLists(needsYouRaw: [Case], waitingRaw: [Case]) {
        regroupSuspended = true
        needsYouCases = Self.newestFirst(needsYouRaw)
        waitingOnAgentCases = Self.newestFirst(waitingRaw.filter { !AnswerGrouping.isClosed($0) })
        regroupSuspended = false
        if regroupPending {
            regroupPending = false
            regroupAnswered()
        }
    }

    /// Fetches `needs_you` and `waiting_on_agent` separately (rather than
    /// the full list) so the two AC groups are exactly the daemon's own
    /// status partition: a case cannot land in both, so it can never show
    /// twice (AC 2).
    func refreshCases() async throws {
        async let needsYouFetch = client.casesList(status: .needsYou)
        async let waitingFetch = client.casesList(status: .waitingOnAgent)
        let (needsYouRaw, waitingRaw) = try await (needsYouFetch, waitingFetch)

        applyLists(needsYouRaw: needsYouRaw, waitingRaw: waitingRaw)
        checkQueueShowsEveryNeedsYou(daemonCount: needsYouRaw.count)
        for item in needsYouCases {
            deliveryStatusByCaseId.removeValue(forKey: item.id)
        }
        for item in waitingOnAgentCases {
            applyPersistedDeliveryStatus(for: item)
        }

        // PERF-4: the row carries its task name and artifact kind, so no per-case `cases.get`.
        // One publish for the whole batch.
        publishArtifactKinds(needsYouCases + waitingOnAgentCases)
        reconcileReminders()
        if tracksAutoDecided { await refreshAutoDecided() }
        let currentIds = Set(needsYouCases.map(\.id))
        // First refresh has no earlier set, so nothing counts as an arrival then.
        let hasNewArrival = lastNeedsYouIds.map { !currentIds.subtracting($0).isEmpty } ?? false
        lastNeedsYouIds = currentIds
        autoSelectIfEmpty(hasNewArrival: hasNewArrival)
        await openEvidencePlanIfRequested()
    }

    private var evidencePlanOpened = false

    // MARK: Ask less (WAG-412)

    /// Reads the master switch once per connection. An older daemon has no such key: that reads as off.
    func probeAskLess() async {
        let on = (try? await client.askLess())?.enabled ?? false
        setTracksAutoDecided(on)
    }

    /// The Settings page turned the master on or off.
    func askLessChanged(enabled: Bool) async {
        setTracksAutoDecided(enabled)
        if enabled { await refreshAutoDecided() }
    }

    private func setTracksAutoDecided(_ on: Bool) {
        tracksAutoDecided = on || !autoDecidedToday.isEmpty
        if !on && autoDecidedToday.isEmpty { autoDecidedOpen = false }
    }

    /// The start of today on this Mac, the "today" of "Decided for you · N today".
    static func startOfToday(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }

    func refreshAutoDecided() async {
        guard let list = try? await client.casesAutoDecided(since: Self.startOfToday(now: now)) else { return }
        if list != autoDecidedToday { autoDecidedToday = list }
        if !list.isEmpty { tracksAutoDecided = true }
    }

    /// "Change my mind": the case is an open ask again. It leaves the folded list, joins "Needs you" and opens, so the
    /// person picks another option in the usual pane. The pick goes to the agent as a normal reply.
    func changeMind(caseId: String) async {
        do {
            _ = try await client.caseChangeMind(caseId: caseId)
            autoDecidedToday.removeAll { $0.id == caseId }
            invalidateDetail(caseId)
            try await refreshCases()
            await open(caseId: caseId, source: .queue)
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// `KNOCK_EVIDENCE_OPEN_PLAN=<stage>` (HAIL-151 evidence only): opens the plan ask once it reaches that
    /// stage (question 3 for "questions"), since a capture run cannot know the case id before the
    /// harness creates it.
    private func openEvidencePlanIfRequested() async {
        guard !evidencePlanOpened, let want = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_OPEN_PLAN"],
              // `KNOCK_EVIDENCE_OPEN_PLAN_STEP=<n>` (HAIL-156) picks another question number than 3.
              case let wantStep = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_OPEN_PLAN_STEP"].flatMap(Int.init) ?? 3,
              let plan = needsYouCases.first(where: { $0.plan?.stage.name.rawValue == want && ($0.plan?.stage.step ?? wantStep) == (want == "questions" ? wantStep : ($0.plan?.stage.step ?? wantStep)) })
        else { return }
        evidencePlanOpened = true
        await open(caseId: plan.id)
    }

    /// Copies each row's `artifact_kind` into `artifactKindByCaseId` with one assignment, and only
    /// when something changed, so the queue body is not invalidated for an unchanged list.
    private func publishArtifactKinds(_ cases: [Case]) {
        var next = artifactKindByCaseId
        for item in cases {
            guard let kind = item.artifactKind else { continue }
            next[item.id] = kind
        }
        if next != artifactKindByCaseId { artifactKindByCaseId = next }
    }

    /// Self-check (HAIL-120): the daemon said `daemonCount` asks need the operator. If the lists
    /// or the queue's rows hold fewer, log it, so the next "I see nothing" leaves evidence.
    private func checkQueueShowsEveryNeedsYou(daemonCount: Int) {
        let rendered = sessionFilter == nil ? QueueListView.grouped(needsYouCases).count : daemonCount
        let held = needsYouCases.count
        if let line = QueueLog.mismatchLine(daemon: daemonCount, rendered: min(rendered, held)) {
            QueueLog.write(line, environment: notificationEnvironment)
        }
    }

    /// Needs you ids at the previous refresh, to spot a new arrival or a return (HAIL-118).
    private var lastNeedsYouIds: Set<String>?

    /// Live "operator has unsent work" checks, one per open composer (HAIL-118).
    /// Each returns true while its composer holds a note, a "Something else" detail,
    /// a comment being written, or an open Change answer edit.
    private var unsentWorkProbes: [UUID: () -> Bool] = [:]

    func registerUnsentWorkProbe(id: UUID, _ probe: @escaping () -> Bool) {
        unsentWorkProbes[id] = probe
    }

    func unregisterUnsentWorkProbe(id: UUID) {
        unsentWorkProbes[id] = nil
    }

    var holdsUnsentWork: Bool { unsentWorkProbes.values.contains { $0() } }

    // MARK: Home (HAIL-119)

    /// The project whose page is open (WAG-260), by the daemon's project tag; nil for no page.
    @Published var openProject: String?

    func openProjectPage(_ project: String) { openProject = project }
    func closeProjectPage() { openProject = nil }

    /// "← Home": clears the selection so the pane shows the home screen. Counts as an operator
    /// move, so an auto-select that was about to open an ask drops its result (HAIL-116).
    func goHome() {
        operatorOpenCount += 1
        selectedCaseId = nil
        selectedCaseDetail = nil
    }

    /// HAIL-113: an empty pane never sits beside a Needs you ask. HAIL-118: neither does
    /// a stale or answered ask when a new one arrives. Runs after every case refresh
    /// (new ask, ask back to needs_you, launch, reconnect).
    private func autoSelectIfEmpty(hasNewArrival: Bool = false) {
        // A launch deep link (KNOCK_OPEN_CASE) opens its own case right after this refresh.
        guard pendingOpenCaseId == nil else { return }
        let known = (needsYouCases + waitingOnAgentCases + answeredCases).map(\.id)
        guard let id = Self.autoSelectTarget(
            selectedCaseId: selectedCaseId, paneShowsCase: selectedCaseDetail != nil,
            knownCaseIds: known, needsYou: needsYouCases,
            hasNewArrival: hasNewArrival, holdsUnsentWork: holdsUnsentWork) else { return }
        // The open runs in a task, so the operator can act before it starts. It re-checks
        // then, and abandons if any operator open began meanwhile (HAIL-116).
        let generation = operatorOpenCount
        Task {
            guard operatorOpenCount == generation, pendingOpenCaseId == nil, !holdsUnsentWork else { return }
            let onScreenIsNeedsYou = selectedCaseId.map { sel in needsYouCases.contains { $0.id == sel } } ?? false
            guard selectedCaseDetail == nil || !onScreenIsNeedsYou else { return }
            await performOpen(caseId: id, source: nil, autoSelectGeneration: generation)
        }
    }

    /// Counts operator-initiated opens (click, keyboard, notification, deep link,
    /// auto-advance). Auto-select never starts, and never lands, after this moves.
    private var operatorOpenCount = 0

    /// Pure rule (HAIL-113, HAIL-118): the top Needs you case when
    /// - nothing is selected, or the selected case is gone and the pane fell back to empty; or
    /// - the case on screen is not in Needs you (answered, waiting, closed) and a Needs you
    ///   ask arrived or returned since the last refresh, with no unsent work.
    /// `nil` (change nothing) while a Needs you case is on screen, or a selection is still
    /// loading for a case that exists. Waiting and answered cases are never picked.
    nonisolated static func autoSelectTarget(
        selectedCaseId: String?, paneShowsCase: Bool, knownCaseIds: [String], needsYou: [Case],
        hasNewArrival: Bool = false, holdsUnsentWork: Bool = false
    ) -> String? {
        guard let top = needsYou.first else { return nil }
        if paneShowsCase {
            guard hasNewArrival, !holdsUnsentWork else { return nil }
            if let selectedCaseId, needsYou.contains(where: { $0.id == selectedCaseId }) { return nil }
            return top.id
        }
        if let selectedCaseId, knownCaseIds.contains(selectedCaseId) { return nil }
        return top.id
    }

    /// Sets/clears `deliveryStatusByCaseId` from a `waiting_on_agent` case's
    /// own denormalized `latest_reply_*` fields (docs/protocol-mvp.md "Case
    /// fields", KNOCK-13 fold Contract amendment 1): unlike `applyReplyOutcome`
    /// (a `reply.state_changed` event's follow-up `cases.get`), this needs no
    /// extra round trip - `cases.list` already carries it - so it is safe to
    /// call on every load and reconnect, not only on an event. This is what
    /// makes a failed or delivered reply survive an app relaunch (a status
    /// the app only ever saw over the wire, never fabricated): before this,
    /// `deliveryStatusByCaseId` was populated only by a live event, so it
    /// went blank - and a failed reply's Retry with it - the moment the app
    /// restarted.
    private func applyPersistedDeliveryStatus(for item: Case) {
        switch item.latestReplyState {
        case .delivered:
            deliveryStatusByCaseId[item.id] = .delivered(at: item.latestReplyAtDate ?? item.updatedAtDate ?? Date())
        case .failed:
            if let replyId = item.latestReplyId {
                deliveryStatusByCaseId[item.id] = .failed(replyId: replyId)
            }
        // `.superseded` (HAIL-44) never reaches here: this only ever runs
        // over `waitingOnAgentCases`, and a superseded reply's case is
        // withdrawn (resolved) in the same write, so it is never in that
        // list.
        case .queued, .superseded, .handedOver, nil:
            deliveryStatusByCaseId.removeValue(forKey: item.id)
        }
    }

    /// Newest arrival on top (docs/stories/HAIL-34.md operator amendment,
    /// 2026-09-28: "the most recent ask on top, the oldest at the bottom"),
    /// with `id` as a stable tie-break so two cases created in the same
    /// instant (a fixture, or a burst of `knock_ask` calls) still sort the
    /// same way on every refresh.
    static func newestFirst(_ cases: [Case]) -> [Case] {
        cases.sorted {
            // A plan ask sorts by its latest round (HAIL-151), any other ask by its arrival.
            let lhs = $0.sortDate
            let rhs = $1.sortDate
            if lhs != rhs { return lhs > rhs }
            return $0.id < $1.id
        }
    }

    /// The kind of the opened case's artifact. Taken from the detail's own `artifact_kind`;
    /// `artifact.path` only answers when a daemon sent none.
    private func resolveArtifactKind(for detail: CaseDetail) async {
        if let kind = detail.case.artifactKind {
            if artifactKindByCaseId[detail.case.id] != kind { artifactKindByCaseId[detail.case.id] = kind }
            return
        }
        guard detail.case.hasArtifact, let latest = detail.revisions.max(by: { $0.n < $1.n }),
              artifactRevisionCountByCaseId[detail.case.id] != detail.revisions.count else { return }
        guard let path = try? await client.artifactPath(caseId: detail.case.id, revision: latest.n) else { return }
        artifactKindByCaseId[detail.case.id] = path.kind
        artifactRevisionCountByCaseId[detail.case.id] = detail.revisions.count
    }

    /// Cases whose cached detail is known to match the daemon: read after the last event that named
    /// them, and since the last connect. `open` skips the read for these (PERF-5).
    private var freshDetailIds: Set<String> = []
    private var detailEpoch: [String: Int] = [:]

    /// An event named this case, or the connection dropped: the cached detail may be old.
    private func invalidateDetail(_ caseId: String) {
        freshDetailIds.remove(caseId)
        detailEpoch[caseId, default: 0] += 1
    }

    /// The one place a case detail is read. The result is cached. It counts as fresh only when no
    /// event named the case while the read was in flight.
    private func fetchDetail(caseId: String) async throws -> CaseDetail {
        let epoch = detailEpoch[caseId, default: 0]
        let detail = try await client.casesGet(id: caseId)
        cacheDetail(detail)
        if detailEpoch[caseId, default: 0] == epoch { freshDetailIds.insert(caseId) }
        return detail
    }

    /// Reads a case and puts the result on the pane when it is the selected one.
    private func reloadDetail(caseId: String) async throws -> CaseDetail {
        let detail = try await fetchDetail(caseId: caseId)
        if selectedCaseId == caseId {
            selectedCaseDetail = detail
        }
        return detail
    }

    /// Opens a case by id: selects it and loads its detail. This is the one
    /// entry point later stories (notifications, onboarding) call to jump
    /// straight to a case. When `source` is given the open is reported as a
    /// `case_opened` usage event (KNOCK-19); a nil source (the launch-time
    /// KNOCK_OPEN_CASE deep link) reports nothing.
    ///
    /// Waits for the connection first (HAIL-24): the setup window's Open can
    /// call this at the exact moment `AppActivation.showMainWindow()` creates
    /// the main window for the first time, which is also the first moment
    /// `MainWindowView`'s own `.task { model.start() }` runs - `casesGet`
    /// fired immediately would race that connection and fail with
    /// `notConnected` before it ever has a chance to open, exactly the
    /// operator report this story fixes ("Open on the created test case did
    /// nothing"). A genuinely unreachable daemon still fails the same way as
    /// before, just after this wait's timeout instead of instantly.
    func open(caseId: String, source: CaseOpenSource? = nil) async {
        // WAG-397: a case with unread team comments opens on the Comments tab when the operator picks it.
        let hadUnread = unreadByCaseId[caseId] != nil && (source == .queue || source == .notification)
        operatorOpenCount += 1
        openProject = nil
        await performOpen(caseId: caseId, source: source, autoSelectGeneration: nil)
        if hadUnread { openReviewOnComments(caseId: caseId) }
    }

    /// WAG-397: the click on a comment notification. The case opens on its Comments tab.
    func openComments(caseId: String, source: CaseOpenSource? = .notification) async {
        await open(caseId: caseId, source: source)
        openReviewOnComments(caseId: caseId)
    }

    /// Puts the review workspace on screen at the Comments tab, for a case that has a review to open.
    func openReviewOnComments(caseId: String) {
        guard selectedCaseId == caseId,
              let selected = orderedCases.first(where: { $0.id == caseId }),
              Self.canOpenReview(kind: selected.kind, hasArtifact: selected.hasArtifact) else { return }
        reviewOpensOnPriorRevision = false
        reviewCommentHandoff = nil
        reviewOpensOnRevision = nil
        reviewOpensOnComments = true
        reviewRequestCaseId = caseId
    }

    /// `autoSelectGeneration` is set only by auto-select (HAIL-113): its result is
    /// dropped once an operator open has begun since it was decided (HAIL-116).
    private func performOpen(caseId: String, source: CaseOpenSource?, autoSelectGeneration: Int?) async {
        // A different ask than the one on screen is a new opening: its clock
        // for the "after" bucket starts now (HAIL-83).
        if selectedCaseId != caseId || source != nil { usage.askOpened(caseId: caseId) }
        selectedCaseId = caseId
        // WAG-394: opening a case clears its unread mark for team comments.
        if unreadByCaseId[caseId] != nil { Task { [teamComments] in await teamComments?.markSeen(caseId: caseId) } }
        // A newer open replaces this one: it stops before its next read and drops its result (PERF-5).
        openSerial += 1
        let serial = openSerial
        Task { await refreshSessions() }
        // Draw from the last known detail at once (HAIL-47): every field
        // `CasePaneDetailView` needs - title, options, task breadcrumb,
        // revisions, replies - comes from this cached `CaseDetail`, not a
        // partial stand-in, so the pane is fully correct and fully
        // interactive the instant a warm row is clicked.
        let cached = caseDetailCache[caseId]
        if let cached {
            selectedCaseDetail = cached
        }
        do {
            // PERF-5: no event named this case since its last read, so the cached detail is the last word.
            let detail: CaseDetail
            if let cached, freshDetailIds.contains(caseId) {
                detail = cached
            } else {
                await waitUntilConnected()
                guard serial == openSerial else { return recordOpen(source) }
                detail = try await fetchDetail(caseId: caseId)
            }
            guard serial == openSerial else { return recordOpen(source) }
            // The layout needs the artifact's kind before the first frame (HAIL-84): without it
            // a prototype ask would flash the text page. Already known for a warm case.
            await resolveArtifactKind(for: detail)
            // The selection may have moved on again while this awaited
            // (a fast second click, or arrow-key navigation outrunning the
            // round trip): a slow fetch for the case the operator already
            // left must never clobber whatever they moved to next.
            if serial == openSerial, selectedCaseId == caseId, autoSelectGeneration.map({ $0 == operatorOpenCount }) ?? true {
                selectedCaseDetail = detail
            }
            recordOpen(source)
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    private var openSerial = 0

    private func recordOpen(_ source: CaseOpenSource?) {
        if let source {
            usage.record(.caseOpened, source: source.rawValue)
        }
    }

    /// Polls the already-mirrored `connectionState` rather than
    /// re-subscribing to `client.connectionStates`: that stream already has
    /// exactly one consumer (`start()`'s own loop, which is what keeps
    /// `connectionState` current), and a second `for await` over the same
    /// `AsyncStream` would compete with it for elements instead of observing
    /// them independently. Bounded to the same ~3s window `KnockClient`
    /// itself gives an on-demand daemon start, plus a small margin.
    private func waitUntilConnected(timeout: Duration = .seconds(4)) async {
        guard connectionState != .connected else { return }
        let deadline = ContinuousClock.now + timeout
        while connectionState != .connected {
            guard ContinuousClock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Daemon enforcement (HAIL-27): the app owns its daemon, so when the
    /// running daemon's version or binary path differs from the app's own, ask
    /// the daemon to exit and let the app's own reconnect start the bundled
    /// binary. Runs on launch and every reconnect. Best effort: a missing
    /// status or a failed restart never blocks the queue.
    private func enforceOwnDaemon() async {
        guard let status = try? await client.serviceStatus() else { return }
        let appPath = ServiceControl.resolvedBinaryPath()
        guard DaemonEnforcement.needsRestart(
            appVersion: Updater.appVersion,
            appBinaryPath: appPath,
            status: status
        ) else { return }
        try? await client.serviceRestart()
    }

    // MARK: - Keyboard navigation (AC: up/down, j/k move; return opens)

    /// The rows up/down walk, top to bottom. The Answered group is skipped
    /// while it is collapsed (HAIL-64) and included while it is open.
    nonisolated static func navigationIds(needsYou: [Case], waiting: [Case], answered: [Case], answeredOpen: Bool) -> [String] {
        (needsYou + waiting + (answeredOpen ? answered : [])).map(\.id)
    }

    /// Moves the selection by `delta` rows through `orderedCases`, clamped
    /// to the list's ends (no wraparound). A negative delta moves up/toward
    /// index 0; positive moves down. No-op on an empty list.
    func moveSelection(by delta: Int) {
        let ids = Self.navigationIds(
            needsYou: visibleNeedsYouCases, waiting: visibleWaitingCases,
            answered: visibleAnsweredCases, answeredOpen: answeredOpen
        )
        guard !ids.isEmpty else { return }
        let nextIndex: Int
        if let currentId = selectedCaseId, let currentIndex = ids.firstIndex(of: currentId) {
            nextIndex = min(max(currentIndex + delta, 0), ids.count - 1)
        } else {
            nextIndex = delta >= 0 ? 0 : ids.count - 1
        }
        let nextId = ids[nextIndex]
        guard nextId != selectedCaseId else { return }
        Task { await open(caseId: nextId, source: .keyboard) }
    }

    /// Whether an ask has a review workspace to open (docs/stories/
    /// HAIL-36.md amendment 3, operator, 16:23: "why i cannot click this?"):
    /// every review ask does (KNOCK-10), and so does a question ask that
    /// carries an artifact - an HTML plan, markdown, or a screenshot -
    /// otherwise `ArtifactPreviewCard`'s tap and Return/"Open review ↵" both
    /// did nothing for it, showing only the 280pt preview. A question ask
    /// with no artifact still has nothing to open here (KNOCK-08 does not
    /// define a composer action for questions - see Choices). Pure and
    /// unit-testable without hosting a view, the same pattern
    /// `CasePaneDetailView.footerKind` uses.
    static func canOpenReview(kind: Case.Kind, hasArtifact: Bool) -> Bool {
        kind == .review || hasArtifact
    }

    /// Return's action on the selected row: the same activation as clicking
    /// "Open review ↵" or the artifact preview card.
    func activateSelection(commentHandoff: CommentHandoff? = nil, revision: Int? = nil) {
        guard let id = selectedCaseId,
              let selected = orderedCases.first(where: { $0.id == id }),
              Self.canOpenReview(kind: selected.kind, hasArtifact: selected.hasArtifact) else { return }
        reviewOpensOnPriorRevision = false
        reviewCommentHandoff = commentHandoff
        reviewOpensOnRevision = revision
        reviewOpensOnComments = false
        reviewRequestCaseId = id
    }

    /// The conversation's "v<N> · see in review" link (HAIL-71).
    func activateSelectionOnPriorRevision() {
        activateSelection()
        if reviewRequestCaseId != nil { reviewOpensOnPriorRevision = true }
    }

    /// Esc's action in the review workspace: returns to the queue/case-pane
    /// split. `MainWindowView` wires this to the escape key.
    func closeReview() {
        reviewRequestCaseId = nil
        reviewOpensOnComments = false
        reviewOpensOnPriorRevision = false
        reviewOpensOnRevision = nil
        reviewCommentHandoff = nil
    }
}
