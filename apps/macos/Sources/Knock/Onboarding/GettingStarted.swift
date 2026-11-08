import Combine
import Foundation

/// What the new onboarding remembers (WAG-338): the getting started list, the "Your agent is on it" state
/// and the tour. One small JSON file in the `KNOCK_HOME`-scoped data root, next to the old `onboarded`
/// marker, so a test or an evidence run with a temp `KNOCK_HOME` never touches the real profile.
struct GettingStartedState: Codable, Equatable {
    /// When first-run began. Asks older than this are history: they never tick a line or start the tour.
    var startedAt: Date
    var connected = false
    /// "Claude Code", "Codex", "the Claude app": the line says which one.
    var connectedAgent: String?
    var jobSentAt: Date?
    var jobProject: String?
    /// Who took the job ("Claude Code", or "Your agent" after Copy prompt) and what it is, for the working card.
    var jobAgent: String?
    var jobSummary: String?
    var decided = false
    var talked = false
    var notifications = false
    var designKit = false
    /// The person pressed Hide. The Help menu brings the list back.
    var hidden = false
    /// The first ask (or the sample) has arrived: "Your agent is on it" is over.
    var workingOver = false
    var tourStarted = false
    var tourSkipped = false
    var tourFirstDone = false
    var tourRoundDone = false
    var tourCaseId: String?

    init(startedAt: Date) { self.startedAt = startedAt }

    private enum CodingKeys: String, CodingKey {
        case startedAt, connected, connectedAgent, jobSentAt, jobProject, jobAgent, jobSummary, decided, talked, notifications
        case designKit, hidden, workingOver, tourStarted, tourSkipped, tourFirstDone, tourRoundDone, tourCaseId
    }

    /// Tolerant: a missing key keeps its default, so a later build can add a field without
    /// resetting what this one saved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        connectedAgent = try c.decodeIfPresent(String.self, forKey: .connectedAgent)
        jobSentAt = try c.decodeIfPresent(Date.self, forKey: .jobSentAt)
        jobProject = try c.decodeIfPresent(String.self, forKey: .jobProject)
        jobAgent = try c.decodeIfPresent(String.self, forKey: .jobAgent)
        jobSummary = try c.decodeIfPresent(String.self, forKey: .jobSummary)
        decided = try c.decodeIfPresent(Bool.self, forKey: .decided) ?? false
        talked = try c.decodeIfPresent(Bool.self, forKey: .talked) ?? false
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? false
        designKit = try c.decodeIfPresent(Bool.self, forKey: .designKit) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        workingOver = try c.decodeIfPresent(Bool.self, forKey: .workingOver) ?? false
        tourStarted = try c.decodeIfPresent(Bool.self, forKey: .tourStarted) ?? false
        tourSkipped = try c.decodeIfPresent(Bool.self, forKey: .tourSkipped) ?? false
        tourFirstDone = try c.decodeIfPresent(Bool.self, forKey: .tourFirstDone) ?? false
        tourRoundDone = try c.decodeIfPresent(Bool.self, forKey: .tourRoundDone) ?? false
        tourCaseId = try c.decodeIfPresent(String.self, forKey: .tourCaseId)
    }

    /// The state of a person who finished the old onboarding before this build: no list, no tour, nothing
    /// to wait for. "An onboarded person never sees onboarding again."
    static func migrated(at date: Date) -> GettingStartedState {
        var state = GettingStartedState(startedAt: date)
        state.hidden = true
        state.workingOver = true
        state.tourStarted = true
        state.tourSkipped = true
        return state
    }
}

/// Reads and writes the state file. Decides, once, whether a missing file means a fresh install or a
/// person who finished the old onboarding.
struct GettingStartedStore {
    let url: URL
    let isOnboarded: () -> Bool
    let now: () -> Date

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isOnboarded: (() -> Bool)? = nil, now: @escaping () -> Date = { Date() }
    ) {
        self.url = OnboardingState.gettingStartedURL(environment: environment)
        self.isOnboarded = isOnboarded ?? { OnboardingState.isOnboarded(environment: environment) }
        self.now = now
    }

    /// The saved state. A missing file is decided now and written at once: an old `onboarded` marker means
    /// a migrated person, none means a fresh start. Writing at once keeps a fresh install from reading as
    /// migrated after step 1 creates the marker.
    func load() -> GettingStartedState {
        if let data = try? Data(contentsOf: url), let state = try? Self.decoder.decode(GettingStartedState.self, from: data) {
            return state
        }
        let state = isOnboarded() ? GettingStartedState.migrated(at: now()) : GettingStartedState(startedAt: now())
        save(state)
        return state
    }

    func save(_ state: GettingStartedState) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The six lines of the getting started list.
enum GettingStartedLine: CaseIterable, Equatable {
    case connect, job, decision, talk, notifications, designKit

    /// The closed word the usage log takes for this line (WAG-366).
    var usageName: String {
        switch self {
        case .connect: "connect"
        case .job: "job"
        case .decision: "decision"
        case .talk: "talk"
        case .notifications: "notifications"
        case .designKit: "design_kit"
        }
    }

    var title: String {
        switch self {
        case .connect: "Connect an agent"
        case .job: "Send your agent a first job"
        case .decision: "Get your first decision"
        case .talk: "Keep talking once"
        case .notifications: "Allow notifications"
        case .designKit: "Add a design kit"
        }
    }

    /// The button on the right of a line that has a place of its own. Nil for the other lines.
    var actionLabel: String? {
        switch self {
        case .notifications: "Allow"
        case .designKit: "Add"
        default: nil
        }
    }
}

struct GettingStartedItem: Equatable, Identifiable {
    let line: GettingStartedLine
    let isDone: Bool
    /// The line under the title: it explains itself, and says what is true once done.
    let hint: String
    var id: GettingStartedLine { line }
    var title: String { line.title }
    /// The button shows only while the line is open.
    var actionLabel: String? { isDone ? nil : line.actionLabel }
}

/// "Your agent is on it": shown from the first job until the first ask arrives.
struct AgentOnIt: Equatable {
    let projectName: String
    let since: Date
    /// "Claude Code", "Your agent".
    let agent: String
    /// "finding a real decision", or the job in the person's words.
    let summary: String

    /// The sample button appears after this long with no ask.
    static let sampleAfter: TimeInterval = 180

    func sampleOffered(now: Date) -> Bool { now.timeIntervalSince(since) >= Self.sampleAfter }

    /// "2 min" in the queue row.
    func minutes(now: Date) -> Int { max(0, Int(now.timeIntervalSince(since) / 60)) }

    /// The line under "Your agent is on it" in the queue: "Acme support · finding a real decision · 2 min".
    func queueLine(now: Date) -> String { "\(projectName) · \(summary) · \(minutes(now: now)) min" }

    /// The working card's text.
    var cardText: String {
        let what = summary == AgentOnIt.defaultSummary
            ? "is looking at \(projectName) for one real open decision."
            : "is working on \"\(summary)\" in \(projectName)."
        return "\(agent) \(what) It will bring options with a prototype or a write-up each. The ask opens here."
    }

    static let defaultSummary = "finding a real decision"
    /// The agent name when the job was copied, not sent: any agent may take it.
    static let unknownAgent = "Your agent"
}

/// The getting started list, the working state and the tour triggers (WAG-338). The pure rules are here;
/// the views only draw them. Lines tick themselves: the app tells this model what happened (agent
/// connected, job sent, asks changed, notification permission, design kit) and it saves the result.
@MainActor
final class GettingStartedModel: ObservableObject {
    @Published private(set) var state: GettingStartedState
    /// The sample ask is being made, or could not be.
    @Published private(set) var sample: SamplePhase = .idle
    /// True after the Help menu asked for the list, so it shows even when every line is done.
    @Published private(set) var forcedVisible = false

    enum SamplePhase: Equatable {
        case idle
        case running
        case failed(String)
    }

    /// The tour of the first ask (once, skippable). Shared with `MainWindowView`.
    let tour: CoachMarkTourModel
    private let store: GettingStartedStore?
    /// Subscriptions to the app (see `observe(_:)`).
    var observations: [AnyCancellable] = []

    /// Opens the case in the main window when the tour starts on it.
    var onOpenCase: (String) -> Void = { _ in }
    /// "Click to send another": opens the job picker (step 2 of the short window).
    var onOpenJobPicker: () -> Void = {}
    /// The Allow line: asks macOS for the permission. Only a press reaches it.
    var onRequestNotifications: () -> Void = {}
    /// The Add line: opens Settings on the design kit.
    var onOpenDesignKit: () -> Void = {}
    /// The Connect line: opens Settings on Agents.
    var onOpenAgents: () -> Void = {}

    init(store: GettingStartedStore = GettingStartedStore(), tour: CoachMarkTourModel = CoachMarkTourModel()) {
        self.store = store
        self.tour = tour
        self.state = store.load()
        tour.onEnd = { [weak self] reason in self?.tourEnded(reason) }
    }

    /// A model that shows nothing and saves nothing: the default for a view built without a first run
    /// (tests, previews). Its list is hidden and nothing is working.
    static let inert = GettingStartedModel(state: .migrated(at: .distantPast))

    private init(state: GettingStartedState) {
        self.store = nil
        self.tour = CoachMarkTourModel()
        self.state = state
    }

    // MARK: List

    var items: [GettingStartedItem] {
        GettingStartedLine.allCases.map { line in
            let done = isDone(line)
            return GettingStartedItem(line: line, isDone: done, hint: hint(for: line, done: done))
        }
    }

    var doneCount: Int { GettingStartedLine.allCases.filter(isDone).count }
    var total: Int { GettingStartedLine.allCases.count }
    var fraction: Double { Double(doneCount) / Double(total) }

    /// The list hides itself when every line is done, or after Hide. The Help menu brings it back.
    var isListVisible: Bool { forcedVisible || (!state.hidden && doneCount < total) }

    /// After the first decision the notifications line is highlighted with the tip from screen 7.
    var highlightsNotifications: Bool { isListVisible && state.decided && !state.notifications }

    static let notificationsTipTitle = "Next: hear when an agent needs you"
    static let notificationsTipBody = "Allow notifications from the list. macOS asks for permission only when you press Allow."

    func isDone(_ line: GettingStartedLine) -> Bool {
        switch line {
        case .connect: state.connected
        case .job: state.jobSentAt != nil
        case .decision: state.decided
        case .talk: state.talked
        case .notifications: state.notifications
        case .designKit: state.designKit
        }
    }

    private func hint(for line: GettingStartedLine, done: Bool) -> String {
        switch line {
        case .connect:
            if done { return "\(state.connectedAgent ?? "Your agent") is connected." }
            return "Connect Claude Code, Codex or the Claude app."
        case .job:
            if done {
                let project = state.jobProject.map { "Sent to \($0)." } ?? "Sent."
                return "\(project) Click to send another."
            }
            return "Pick a project and a job."
        case .decision: return "Pick an option and press Decide."
        case .talk: return "Lean, rule out or ask: the agent answers in a new round."
        case .notifications: return "Hear when an agent needs you."
        case .designKit: return "Prototypes use your colours and type."
        }
    }

    /// A click on a line opens the place where it is done.
    func open(_ line: GettingStartedLine) {
        UsageReporter.current?.record(.gettingStartedLineOpened, variantName: line.usageName)
        switch line {
        case .connect: onOpenAgents()
        case .job: onOpenJobPicker()
        case .decision, .talk: if let id = state.tourCaseId { onOpenCase(id) }
        case .notifications: allowNotifications()
        case .designKit: onOpenDesignKit()
        }
    }

    /// The Allow button. macOS asks only now.
    func allowNotifications() { onRequestNotifications() }

    func hide() {
        UsageReporter.current?.record(.gettingStartedHidden)
        forcedVisible = false
        update { $0.hidden = true }
    }

    /// The Help menu: the list comes back, with its ticks.
    func show() {
        forcedVisible = true
        update { $0.hidden = false }
    }

    // MARK: Ticks

    func markConnected(agent: String) {
        guard !state.connected || state.connectedAgent != agent else { return }
        update { $0.connected = true; $0.connectedAgent = agent }
    }

    /// The first job left (or its prompt was copied): "Your agent is on it" starts. Another job sent later
    /// restarts the wait and keeps the ticks.
    func markJobSent(project: String, agent: String, summary: String, at date: Date) {
        update {
            $0.jobSentAt = date
            $0.jobProject = project
            $0.jobAgent = agent
            $0.jobSummary = summary
            $0.workingOver = false
        }
    }

    func updateNotifications(_ permission: NotificationPermissionState) {
        guard permission == .on, !state.notifications else { return }
        update { $0.notifications = true }
    }

    func updateDesignKit(isSet: Bool) {
        guard isSet, !state.designKit else { return }
        update { $0.designKit = true }
    }

    // MARK: Asks

    /// Reads the asks the app holds: ticks "decision" and "keep talking", ends "Your agent is on it" when the
    /// first ask arrives, and starts the tour (mark 1 on the first ask, mark 3 when the agent comes back
    /// with a new round after Keep talking). Asks from before first-run began are history and are ignored.
    func apply(cases: [Case]) {
        let fresh = cases.filter { ($0.createdAtDate ?? .distantPast) >= state.startedAt }
        var next = state
        if fresh.contains(where: { $0.latestReplyId != nil && Self.isDecision($0.latestReplyIntent) }) { next.decided = true }
        if fresh.contains(where: { $0.latestReplyId != nil && Self.isTalk($0.latestReplyIntent) }) { next.talked = true }
        let first = fresh
            .filter { $0.status == .needsYou }
            .min { ($0.createdAtDate ?? .distantFuture) < ($1.createdAtDate ?? .distantFuture) }
        // An ask that arrived after the job left ends "Your agent is on it". Without a job, any ask does.
        let boundary = state.jobSentAt ?? state.startedAt
        if fresh.contains(where: { ($0.createdAtDate ?? .distantPast) >= boundary }) { next.workingOver = true }
        var toOpen: String?
        if !next.tourStarted, let first {
            next.tourStarted = true
            next.tourCaseId = first.id
            toOpen = first.id
        }
        let roundCase = next.tourStarted && !next.tourSkipped && !next.tourRoundDone
            ? fresh.first { $0.id == next.tourCaseId && $0.status == .needsYou && $0.roundHeading != nil } : nil
        if next != state { commit(next) }
        if let toOpen {
            tour.start(caseId: toOpen)
            Self.advanceTourForEvidence(tour)
            onOpenCase(toOpen)
        } else if let roundCase, next.talked, !tour.isShowingRound(for: roundCase.id) {
            tour.startRound(caseId: roundCase.id)
            onOpenCase(roundCase.id)
        }
    }

    /// Evidence only: `KNOCK_EVIDENCE_TOUR_ADVANCE=<n>` presses Next n times as soon as the tour starts, so a
    /// capture run can reach mark 2 (n = 1) or finish marks 1 and 2 (n = 2) without a click.
    static func advanceTourForEvidence(_ tour: CoachMarkTourModel, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let raw = environment["KNOCK_EVIDENCE_TOUR_ADVANCE"], let count = Int(raw), count > 0 else { return }
        for _ in 0..<count { tour.next() }
    }

    static func isDecision(_ intent: ReplyIntent?) -> Bool { intent == nil || intent == .decision }
    static func isTalk(_ intent: ReplyIntent?) -> Bool { intent == .discuss || intent == .moreDetail }

    private func tourEnded(_ reason: CoachMarkTourModel.EndReason) {
        update {
            switch reason {
            case .skipped: $0.tourSkipped = true
            case .completed(let last): if last == .round { $0.tourRoundDone = true } else { $0.tourFirstDone = true }
            }
        }
    }

    // MARK: Working

    /// "Your agent is on it", or nil. Over once the first ask arrives.
    var agentOnIt: AgentOnIt? {
        guard let sent = state.jobSentAt, !state.workingOver else { return nil }
        return AgentOnIt(
            projectName: state.jobProject ?? "your project", since: sent, agent: state.jobAgent ?? AgentOnIt.unknownAgent,
            summary: state.jobSummary ?? AgentOnIt.defaultSummary)
    }

    /// What the sidebar shows (WAG-344): the same, but gone when the person hid getting started.
    var sidebarAgentOnIt: AgentOnIt? { state.hidden ? nil : agentOnIt }

    func sampleStarted() { sample = .running }
    func sampleFailed(_ message: String) { sample = .failed(message) }
    func sampleFinished() { sample = .idle }

    // MARK: Storage

    private func update(_ change: (inout GettingStartedState) -> Void) {
        var next = state
        change(&next)
        if next != state { commit(next) }
    }

    private func commit(_ next: GettingStartedState) {
        state = next
        store?.save(next)
    }
}
