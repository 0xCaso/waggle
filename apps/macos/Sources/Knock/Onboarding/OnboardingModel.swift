import AppKit
import Combine
import Foundation

/// Drives the short setup window (WAG-338): step 1 "Connect your agent" and step 2 "What are you working
/// on?". Everything after that happens in the main window: "Your agent is on it", the tour and the getting
/// started list (see `GettingStartedModel`). Nothing here gates the first ask except connecting one agent.
@MainActor
final class OnboardingModel: ObservableObject {
    // MARK: - Step 1 Connect (carried forward from KNOCK-20/HAIL-24)

    struct RuntimeRow: Equatable, Identifiable {
        enum Status: Equatable {
            case probing
            case notInstalled
            case couldNotCheck
            case notConnected
            case connecting
            case connected
        }

        let runtime: Runtime
        var status: Status
        /// HAIL-134: how Claude Code reaches Waggle, from the same doctor run.
        var plugin: PluginState = .none
        /// A short plain line when the last Connect failed; `nil` otherwise. The row also shows Connect again.
        var error: String?
        var id: Runtime { runtime }
    }

    /// HAIL-134: whether Waggle reaches a runtime as a Claude Code plugin.
    enum PluginState: Equatable {
        case none
        /// The plugin serves Waggle.
        case plugin
        /// The plugin and an older `waggle install` entry both run Waggle.
        case pluginWithOldEntry
    }

    /// The plugin state from `waggle doctor`'s lines (Claude Code and Codex, HAIL-137).
    static func pluginState(for runtime: Runtime, in checks: [DoctorCheckResult]) -> PluginState {
        let name = runtime.displayName
        if checks.contains(where: { $0.label.hasPrefix("\(name) runs Waggle twice") && $0.status == .fail }) {
            return .pluginWithOldEntry
        }
        if checks.contains(where: { $0.label == "\(name) installed as plugin" && $0.status == .ok }) {
            return .plugin
        }
        return .none
    }

    enum ConnectPhase: Equatable {
        case idle
        case checking
        case loaded(rows: [RuntimeRow])
    }

    // MARK: - Screens

    enum Screen: Equatable {
        case connect
        case firstJob
    }

    /// Which first job card is picked.
    enum JobSelection: Equatable {
        case findDecision
        case suggestion(Int)
        case own
    }

    enum StartPhase: Equatable {
        case idle
        case starting
        case failed(String)
        /// The prompt is on the clipboard.
        case copied
    }

    @Published private(set) var screen: Screen = .connect
    @Published private(set) var connectPhase: ConnectPhase = .idle
    /// True once a Connect click has actually run `waggle install <runtime>` against a development-build binary.
    @Published private(set) var didRegisterDevelopmentBuildPath = false

    // Step 2
    @Published private(set) var projects: [OnboardingProject] = []
    @Published private(set) var selectedProject: OnboardingProject?
    @Published private(set) var suggestions: [FirstJobSuggestion] = []
    @Published private(set) var jobSelection: JobSelection = .findDecision
    @Published var ownJobText = ""
    @Published private(set) var routing = FirstJobRouting(routes: [])
    @Published private(set) var startPhase: StartPhase = .idle

    /// The list, the working state and the tour. Shared with the main window.
    let gettingStarted: GettingStartedModel
    /// Shared with `MainWindowView` (the tour floats over the ask there).
    var coachMarkTour: CoachMarkTourModel { gettingStarted.tour }

    /// What agents bring you, how often, how rich: still a Settings page, with its defaults.
    let askPreferences: AskPreferencesModel

    /// At least one runtime is connected. The Claude app counts too (HAIL-175).
    var connectSucceeded: Bool { agentConnected || claudeApp.isConnected }

    private var agentConnected: Bool {
        guard case .loaded(let rows) = connectPhase else { return false }
        return rows.contains { $0.status == .connected }
    }

    /// The name of the agent that is connected, for the list line.
    var connectedAgentName: String? {
        if case .loaded(let rows) = connectPhase, let row = rows.first(where: { $0.status == .connected }) {
            return row.runtime.displayName
        }
        return claudeApp.isConnected ? "The Claude app" : nil
    }

    /// The Claude app place (HAIL-175): the same model Settings uses.
    let claudeApp: ClaudeAppModel
    private var claudeAppObservation: AnyCancellable?
    private var gettingStartedObservation: AnyCancellable?

    let runner: OnboardingCommandRunning
    private let loadSessions: () async -> [SessionInfo]
    private let loadCases: () async -> [Case]
    private let sendPrompt: (String, String) async throws -> SendPromptResult
    /// Starts Claude Code in Terminal: prompt, folder, topic. Returns the failure text, or nil on success.
    private let startInTerminal: @MainActor (String, URL, String) async -> String?
    private let copyToPasteboard: (String) -> Void
    private let pickFolder: @MainActor () -> URL?
    private let markOnboarded: () -> Void
    private let isOnboarded: () -> Bool
    private let onFirstJobStarted: () -> Void
    private let resolvedKnockBinaryPath: () -> String?
    private let now: () -> Date

    private var sessions: [SessionInfo] = []
    private var cases: [Case] = []
    private var recommendedReachApplied = false

    init(
        runner: OnboardingCommandRunning = ProcessCommandRunner(),
        askPreferences: AskPreferencesModel,
        gettingStarted: GettingStartedModel = GettingStartedModel(),
        loadSessions: @escaping () async -> [SessionInfo] = { [] },
        loadCases: @escaping () async -> [Case] = { [] },
        sendPrompt: @escaping (String, String) async throws -> SendPromptResult = { _, _ in
            SendPromptResult(sent: false, reason: .notSupported)
        },
        startInTerminal: (@MainActor (String, URL, String) async -> String?)? = nil,
        copyToPasteboard: @escaping (String) -> Void = { OnboardingModel.copyToGeneralPasteboard($0) },
        pickFolder: @escaping @MainActor () -> URL? = { NewIdeaModel.openFolderPanel(startingAt: FileManager.default.homeDirectoryForCurrentUser) },
        markOnboarded: @escaping () -> Void,
        isOnboarded: @escaping () -> Bool = { OnboardingState.isOnboarded() },
        onFirstJobStarted: @escaping () -> Void = {},
        resolvedKnockBinaryPath: @escaping () -> String? = { KnockBinaryLocator.resolve()?.path },
        claudeApp: ClaudeAppModel = ClaudeAppModel(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.claudeApp = claudeApp
        self.runner = runner
        self.askPreferences = askPreferences
        self.gettingStarted = gettingStarted
        self.loadSessions = loadSessions
        self.loadCases = loadCases
        self.sendPrompt = sendPrompt
        self.startInTerminal = startInTerminal ?? OnboardingModel.defaultTerminalStarter()
        self.copyToPasteboard = copyToPasteboard
        self.pickFolder = pickFolder
        self.markOnboarded = markOnboarded
        self.isOnboarded = isOnboarded
        self.onFirstJobStarted = onFirstJobStarted
        self.resolvedKnockBinaryPath = resolvedKnockBinaryPath
        self.now = now
        claudeAppObservation = claudeApp.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        gettingStartedObservation = gettingStarted.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// True when the `waggle` binary a Connect click would register lives in a build directory or a git
    /// worktree instead of the pilot install location.
    var developmentBuildWarning: Bool {
        guard let path = resolvedKnockBinaryPath() else { return false }
        return path.contains(".build/") || path.contains("/.fleet/wt/")
    }

    // MARK: - Lifecycle

    /// Called when the window appears: runs the install-free `waggle doctor` probe. A no-op past the first
    /// call, so a person reopening the window mid-flow does not have anything run again.
    func start() {
        guard connectPhase == .idle else { return }
        UsageReporter.current?.record(.onboardingStarted)
        connectPhase = .checking
        Task {
            applyConnectRows(await runDoctorRows())
            applyEvidenceScreenIfRequested()
        }
    }

    /// The row's "Retry" after "Couldn't check": probes again.
    func recheck() {
        guard case .loaded = connectPhase else { return }
        connectPhase = .checking
        Task {
            applyConnectRows(await runDoctorRows())
        }
    }

    /// "Set Up Waggle…" in the app menu: back to step 1 with a fresh probe.
    func reset() {
        screen = .connect
        connectPhase = .idle
        startPhase = .idle
        jobSelection = .findDecision
        ownJobText = ""
        start()
    }

    /// "Click to send another" on the list: the job picker is step 2 of this window.
    func showFirstJobPicker() {
        startPhase = .idle
        screen = .firstJob
        Task { await loadFirstJobData() }
    }

    /// Runs `waggle install <runtime>` then `waggle doctor`. Only ever runs on a click of that row's own
    /// "Connect" button.
    func connect(_ runtime: Runtime) {
        guard case .loaded(var rows) = connectPhase,
              let index = rows.firstIndex(where: { $0.runtime == runtime })
        else { return }
        UsageReporter.current?.record(.onboardingAgentConnected, variantName: runtime.rawValue)
        rows[index].status = .connecting
        connectPhase = .loaded(rows: rows)
        if developmentBuildWarning {
            didRegisterDevelopmentBuildPath = true
        }
        Task {
            let code = await runner.run(["install", runtime.rawValue], onLine: { _ in })
            var refreshed = await runDoctorRows()
            // A failed install says so on its row. If doctor still finds the agent connected, nothing failed for the person.
            if code != 0, let index = refreshed.firstIndex(where: { $0.runtime == runtime }), refreshed[index].status != .connected {
                refreshed[index].status = .notConnected
                refreshed[index].error = Self.installFailureMessage(runtime: runtime, exitCode: code)
            }
            applyConnectRows(refreshed)
        }
    }

    /// The error line under a row after `waggle install` fails. A negative code means the process did not start.
    static func installFailureMessage(runtime: Runtime, exitCode: Int32) -> String {
        exitCode < 0
            ? "Couldn't start the setup for \(runtime.displayName). Try again."
            : "Couldn't connect \(runtime.displayName). Try again."
    }

    /// Evidence only: `KNOCK_EVIDENCE_ONBOARDING_SCREEN=firstjob` opens step 2 without a connected agent.
    private func applyEvidenceScreenIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["KNOCK_EVIDENCE_ONBOARDING_SCREEN"] == "firstjob" else { return }
        showFirstJobPicker()
    }

    private func applyConnectRows(_ rows: [RuntimeRow]) {
        connectPhase = .loaded(rows: rows)
        if connectSucceeded, let name = connectedAgentName { gettingStarted.markConnected(agent: name) }
    }

    private func runDoctorRows() async -> [RuntimeRow] {
        var checks: [DoctorCheckResult] = []
        _ = await runner.run(["doctor"], onLine: { line in
            if let check = DoctorLineParser.parse(line) {
                checks.append(check)
            }
        })
        return Runtime.allCases.map {
            RuntimeRow(runtime: $0, status: Self.status(for: $0, in: checks), plugin: Self.pluginState(for: $0, in: checks))
        }
    }

    /// Not `private`: the Settings window's Agents page (HAIL-50) reuses this exact mapping for its own
    /// doctor probe, so the two surfaces can never disagree on what "connected" means.
    ///
    /// `liveRuntimes` is the safety net (HAIL-115): a runtime with a live session in the daemon is
    /// connected, whatever the probe said.
    static func status(
        for runtime: Runtime, in checks: [DoctorCheckResult], liveRuntimes: Set<Runtime> = []
    ) -> RuntimeRow.Status {
        if liveRuntimes.contains(runtime) { return .connected }
        guard let found = checks.first(where: { $0.label == "\(runtime.rawValue) found" }) else {
            return .notInstalled
        }
        if found.status == .skip, found.fix == "Could not check" {
            return .couldNotCheck
        }
        guard found.status == .ok else { return .notInstalled }
        let registeredLabel = "\(runtime.displayName) MCP server registered"
        guard let registered = checks.first(where: { $0.label == registeredLabel }), registered.status == .ok
        else { return .notConnected }
        return .connected
    }

    // MARK: - Step 1 -> Step 2

    /// "Next: your first job". A no-op until one agent is connected. From here the person counts as set up:
    /// closing the window later never brings setup back.
    func continueFromConnect() {
        guard case .connect = screen, connectSucceeded else { return }
        UsageReporter.current?.record(.onboardingContinued)
        let wasOnboarded = isOnboarded()
        markOnboarded()
        if let name = connectedAgentName { gettingStarted.markConnected(agent: name) }
        Task { await preselectRecommendedReach(isOnboarded: wasOnboarded) }
        screen = .firstJob
        Task { await loadFirstJobData() }
    }

    /// "Back" from step 2.
    func backToConnect() {
        guard case .firstJob = screen else { return }
        startPhase = .idle
        screen = .connect
    }

    /// A first setup starts on the recommended level, "Things to look at" (HAIL-193). The step that chose it
    /// left the path, so the choice is made here, once: a person who finished setup before keeps their pick.
    func preselectRecommendedReach(isOnboarded: Bool) async {
        guard !recommendedReachApplied, !isOnboarded else { return }
        await askPreferences.setReach(.visual)
        // A failed send puts the old pick back: try again the next time.
        recommendedReachApplied = askPreferences.reach == .visual
    }

    // MARK: - Step 2 First job

    /// Loads the sessions and asks Waggle holds and fills the project row, newest first. Reads Waggle's own
    /// data only.
    func loadFirstJobData() async {
        sessions = await loadSessions()
        cases = await loadCases()
        projects = OnboardingProjects.build(sessions: sessions, now: now())
        if selectedProject == nil || !projects.contains(where: { $0.id == selectedProject?.id }) {
            if let first = projects.first, !first.isSomethingElse { select(first) } else { selectedProject = nil; refreshJobs() }
        } else {
            refreshJobs()
        }
    }

    /// Picks a project. "Something else" opens the folder picker; a cancelled picker keeps the old pick.
    func select(_ project: OnboardingProject) {
        if project.isSomethingElse && project.folder == nil {
            guard let folder = pickFolder() else { return }
            adoptPicked(OnboardingProject.picked(folder: folder))
            return
        }
        selectedProject = project
        jobSelection = .findDecision
        ownJobText = ""
        startPhase = .idle
        refreshJobs()
    }

    private func adoptPicked(_ project: OnboardingProject) {
        projects = projects.filter { !$0.isSomethingElse } + [project]
        select(project)
    }

    func selectJob(_ selection: JobSelection) {
        jobSelection = selection
        if case .failed = startPhase { startPhase = .idle }
    }

    /// "Change": the next route (another open session, or a new session in Terminal).
    func changeRoute() {
        routing.change()
        startPhase = .idle
    }

    private func refreshJobs() {
        guard let project = selectedProject else {
            suggestions = []
            routing = FirstJobRouting(routes: [])
            return
        }
        suggestions = FirstJobSuggestions.build(project: project, sessions: sessions, cases: cases, now: now())
        routing = FirstJobRouting.make(project: project, sessions: sessions)
    }

    /// The job as picked, or nil while "Type your own" is empty.
    var firstJobKind: FirstJobKind? {
        switch jobSelection {
        case .findDecision: return .findDecision
        case .suggestion(let index): return suggestions.indices.contains(index) ? .suggestion(suggestions[index]) : .findDecision
        case .own:
            let text = ownJobText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .own(text)
        }
    }

    /// The prompt as it would be sent or copied.
    var firstJobPrompt: String? {
        guard let project = selectedProject, let kind = firstJobKind else { return nil }
        return FirstJobPrompt.build(kind, projectName: project.name)
    }

    var canStart: Bool { selectedProject?.folder != nil && firstJobKind != nil && startPhase != .starting }

    /// "Send to my session" or "Start in Terminal". Sends the job to the open session in the project, or
    /// starts Claude Code in the folder with the prompt. Both leave a plain failure line and change nothing.
    func startFirstJob() async {
        guard let project = selectedProject, let folder = project.folder, let kind = firstJobKind,
              let prompt = firstJobPrompt, startPhase != .starting
        else { return }
        UsageReporter.current?.record(.firstJobStarted)
        startPhase = .starting
        switch routing.current {
        case .session(let choice):
            do {
                let result = try await sendPrompt(choice.sessionId, prompt)
                if result.sent { finishFirstJob(project: project, kind: kind) } else { startPhase = .failed(NewIdeaModel.failureText(result.reason)) }
            } catch {
                startPhase = .failed(NewIdeaModel.failureText(nil))
            }
        case .terminal:
            if let failure = await startInTerminal(prompt, URL(fileURLWithPath: folder), FirstJobPrompt.topic(kind)) {
                startPhase = .failed(failure)
            } else {
                finishFirstJob(project: project, kind: kind)
            }
        }
    }

    /// "Copy prompt": the fallback for Codex and the Claude app. The window stays, so the person can paste;
    /// the list counts the job as sent.
    func copyPrompt() {
        guard let project = selectedProject, let prompt = firstJobPrompt, let kind = firstJobKind else { return }
        copyToPasteboard(prompt)
        UsageReporter.current?.record(.onboardingPromptCopied)
        startPhase = .copied
        gettingStarted.markJobSent(project: project.name, agent: "Your agent", summary: FirstJobPrompt.summary(kind), at: now())
    }

    private func finishFirstJob(project: OnboardingProject, kind: FirstJobKind) {
        UsageReporter.current?.record(.firstJobFinished)
        startPhase = .idle
        gettingStarted.markJobSent(project: project.name, agent: routing.agentName, summary: FirstJobPrompt.summary(kind), at: now())
        markOnboarded()
        onFirstJobStarted()
    }

    // MARK: - Pieces the app wires

    static func copyToGeneralPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The real Terminal start: Claude Code, in the folder, with the prompt. A fresh launcher, so the
    /// person's saved launch target is never changed.
    @MainActor
    static func defaultTerminalStarter(
        makeLauncher: @escaping @MainActor () -> SessionLauncher = { SessionLauncher() }
    ) -> @MainActor (String, URL, String) async -> String? {
        { prompt, folder, topic in
            let launcher = makeLauncher()
            launcher.chooseLaunchTarget(.claudeTerminal)
            if await launcher.start(prompt: prompt, folder: folder, topic: topic) { return nil }
            return launcher.errorText ?? "Waggle could not open Terminal. Copy the prompt instead."
        }
    }
}
