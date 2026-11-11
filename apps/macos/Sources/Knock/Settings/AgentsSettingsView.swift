import AppKit
import SwiftUI

/// The Agents page's own doctor probe (HAIL-50 contract: "Claude Code and
/// Codex rows with Connected / Not connected / Not installed, from the same
/// `knock doctor` run onboarding uses"). A separate, page-scoped model
/// rather than sharing `OnboardingModel` itself - this page re-probes every
/// time it appears, with none of onboarding's screen/step state - but it
/// reuses `OnboardingModel.status(for:in:)` for the actual status mapping so
/// the two surfaces can never disagree on what "connected" means.
@MainActor
final class AgentsSettingsModel: ObservableObject {
    @Published private(set) var rows: [OnboardingModel.RuntimeRow] = Runtime.allCases.map {
        OnboardingModel.RuntimeRow(runtime: $0, status: .probing)
    }

    private let runner: OnboardingCommandRunning
    /// HAIL-136: gets the same doctor run, for the plugin rows.
    private let pluginOffer: PluginOfferModel?
    private var lastLive: Set<Runtime> = []
    /// The runtimes with a live session in the daemon. A live session proves
    /// the runtime is installed and connected, so it overrides the probe (HAIL-115).
    private let liveRuntimes: () async -> Set<Runtime>

    init(
        runner: OnboardingCommandRunning = ProcessCommandRunner(),
        liveRuntimes: @escaping () async -> Set<Runtime> = { [] },
        pluginOffer: PluginOfferModel? = nil
    ) {
        self.runner = runner
        self.pluginOffer = pluginOffer
        self.liveRuntimes = liveRuntimes
    }

    /// "Retry" after "Couldn't check".
    func retry() {
        for index in rows.indices where rows[index].status == .couldNotCheck { rows[index].status = .probing }
        Task { await refresh() }
    }

    func start() async {
        await refresh()
    }

    /// The row's own "Connect" button (contract: "runs `knock install
    /// <runtime>` like onboarding's Connect").
    func connect(_ runtime: Runtime) {
        guard let index = rows.firstIndex(where: { $0.runtime == runtime }) else { return }
        rows[index].status = .connecting
        Task {
            _ = await runner.run(["install", runtime.rawValue], onLine: { _ in })
            await refresh()
        }
    }

    /// "Remove old entry" (HAIL-134): with the plugin installed, `knock install claude`
    /// adds no MCP entry and removes the older one, so Claude Code runs one Knock server.
    func removeOldEntry(_ runtime: Runtime) {
        guard let index = rows.firstIndex(where: { $0.runtime == runtime }) else { return }
        rows[index].status = .connecting
        Task {
            _ = await runner.run(["install", runtime.rawValue], onLine: { _ in })
            await refresh()
        }
    }

    private func refresh() async {
        var checks: [DoctorCheckResult] = []
        _ = await runner.run(["doctor"], onLine: { line in
            if let check = DoctorLineParser.parse(line) {
                checks.append(check)
            }
        })
        pluginOffer?.apply(checks: checks)
        lastLive = await liveRuntimes()
        applyRows(checks)
    }

    /// The plugin switch ran its own doctor: show its result on the rows too, so the
    /// "Installed as Claude Code plugin" label and the buttons stay truthful (HAIL-136).
    func applyPluginChecks(_ checks: [DoctorCheckResult]) {
        guard !checks.isEmpty, rows.allSatisfy({ $0.status != .probing && $0.status != .connecting }) else { return }
        applyRows(checks)
    }

    private func applyRows(_ checks: [DoctorCheckResult]) {
        let live = lastLive
        rows = Runtime.allCases.map {
            OnboardingModel.RuntimeRow(
                runtime: $0,
                status: OnboardingModel.status(for: $0, in: checks, liveRuntimes: live),
                plugin: OnboardingModel.pluginState(for: $0, in: checks))
        }
    }
}

/// The Agents page: one list of agents, then the "Asking in Waggle" card. Each row has one
/// action. The download links, the Claude app place and T3 Code live in the rows, so nothing
/// repeats below. The example prompts and the sharing note are on the Help page.
struct AgentsSettingsView: View {
    let client: KnockClient

    @StateObject private var agentsModel: AgentsSettingsModel
    @StateObject private var claudeApp: ClaudeAppModel
    @StateObject private var t3Connection: T3ConnectionModel
    private let ruleModel: AgentRuleModel

    init(
        client: KnockClient,
        agentsModel: AgentsSettingsModel? = nil,
        claudeApp: ClaudeAppModel = ClaudeAppModel(),
        t3: T3ConnectionModel = T3ConnectionModel(),
        ruleModel: AgentRuleModel = AgentRuleModel()
    ) {
        self.client = client
        self.ruleModel = ruleModel
        _agentsModel = StateObject(wrappedValue: agentsModel ?? AgentsSettingsModel(liveRuntimes: {
            let sessions = (try? await client.sessionsList()) ?? []
            return Set(ConnectionModel.live(sessions).map(\.runtime))
        }, pluginOffer: PluginOfferModel.shared))
        _claudeApp = StateObject(wrappedValue: claudeApp)
        _t3Connection = StateObject(wrappedValue: t3)
    }

    var body: some View {
        SettingsPageChrome(title: SettingsPage.agents.title, subtitle: SettingsPage.agents.subtitle) {
            AgentsPageContent(
                client: client, agentsModel: agentsModel, claudeApp: claudeApp, t3: t3Connection, ruleModel: ruleModel)
        }
    }
}

/// The page body without the scroll chrome, so a test can measure it.
struct AgentsPageContent: View {
    let client: KnockClient
    @ObservedObject var agentsModel: AgentsSettingsModel
    @ObservedObject var claudeApp: ClaudeAppModel
    @ObservedObject var t3: T3ConnectionModel
    let ruleModel: AgentRuleModel
    @ObservedObject private var pluginOffer = PluginOfferModel.shared
    @ObservedObject private var migration = LaunchMigrationStatus.shared

    var body: some View {
        Group {
            AgentsList(
                agentsModel: agentsModel, claudeApp: claudeApp, pluginOffer: pluginOffer,
                t3: t3, migrationFailure: migration.pluginFailure)
            AgentQuestionsSection(client: client, ruleModel: ruleModel)
        }
        .task { await agentsModel.start() }
        .task { await t3.refresh() }
        .onChange(of: pluginOffer.checks) { _, checks in agentsModel.applyPluginChecks(checks) }
    }
}

/// The one action a Claude Code or Codex row shows. One value per state, so a row never has two.
enum AgentRowAction: Equatable {
    case connect
    case reconnect
    case installPlugin
    case removeOldEntry
    case retry
    case download

    static func forRow(
        _ row: OnboardingModel.RuntimeRow, pluginOfferApplies: Bool = false, downloadWhenMissing: Bool = false
    ) -> AgentRowAction? {
        switch row.status {
        case .notConnected: return .connect
        case .couldNotCheck: return .retry
        case .notInstalled: return downloadWhenMissing ? .download : nil
        case .probing, .connecting: return nil
        case .connected:
            switch row.plugin {
            case .pluginWithOldEntry: return .removeOldEntry
            case .plugin: return nil
            case .none: return pluginOfferApplies ? .installPlugin : .reconnect
            }
        }
    }
}

/// One row: the agent's name, a chip for its state, an optional one-line note, one action.
private struct AgentListRow<Trailing: View>: View {
    let title: String
    var chip: (text: String, ok: Bool)?
    var note: String?
    var showsDivider = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                            .foregroundColor(Theme.Colors.ink)
                        if let chip { SettingsStatusChip(text: chip.text, ok: chip.ok) }
                    }
                    if let note {
                        Text(note)
                            .knockTextStyle(Theme.Typography.body12_5w400)
                            .foregroundColor(Theme.Colors.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing().fixedSize().layoutPriority(1)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
            if showsDivider { Rectangle().fill(Theme.Colors.line).frame(height: 1) }
        }
    }
}

private func openInBrowser(_ url: URL) { NSWorkspace.shared.open(url) }

private struct DownloadButton: View {
    let url: URL
    var body: some View {
        SettingsSecondaryButton(icon: "arrow.up.right", title: AgentPlaceCopy.download) { openInBrowser(url) }
    }
}

private struct AgentsList: View {
    @ObservedObject var agentsModel: AgentsSettingsModel
    @ObservedObject var claudeApp: ClaudeAppModel
    @ObservedObject var pluginOffer: PluginOfferModel
    @ObservedObject var t3: T3ConnectionModel
    let migrationFailure: String?

    private func row(_ runtime: Runtime) -> OnboardingModel.RuntimeRow {
        agentsModel.rows.first { $0.runtime == runtime } ?? .init(runtime: runtime, status: .probing)
    }

    var body: some View {
        SettingsCard {
            claudeCodeRow.id(AgentPlaceCard.runtimes)
            setupChecklist
            claudeAppRow.id(AgentPlaceCard.claudeApp)
            if claudeApp.justAdded && claudeApp.isConnected { ClaudeAppAfterNote().padding(.horizontal, 14).padding(.bottom, 8) }
            if let message = claudeApp.errorMessage { claudeAppProblem(message) }
            codexRow.id(AgentPlaceCard.codexApp)
            t3Rows.id(AgentPlaceCard.t3)
            AgentListRow(title: "Superset", note: AgentPlaceCopy.superset) {
                DownloadButton(url: PlaceInstallLinks.superset)
            }
            .id(AgentPlaceCard.superset)
            AgentListRow(title: "Conductor", note: AgentPlaceCopy.conductor, showsDivider: false) {
                DownloadButton(url: PlaceInstallLinks.conductor)
            }
            .id(AgentPlaceCard.conductor)
            problems
        }
    }

    // MARK: Claude Code

    @ViewBuilder private var claudeCodeRow: some View {
        let row = row(.claude)
        AgentListRow(title: "Claude Code", chip: statusChip(row), note: claudeCodeNote(row)) {
            claudeCodeAction(row)
        }
    }

    private func claudeCodeNote(_ row: OnboardingModel.RuntimeRow) -> String? {
        row.status == .connected && row.plugin != .none ? "Installed as Claude Code plugin" : nil
    }

    @ViewBuilder private func claudeCodeAction(_ row: OnboardingModel.RuntimeRow) -> some View {
        if pluginOffer.isWorking {
            LoadingStatus(label: "Working")
        } else if row.status == .connecting {
            LoadingStatus(label: "Connecting")
        } else {
            actionButton(AgentRowAction.forRow(row, pluginOfferApplies: pluginOffer.status.offerApplies), runtime: .claude)
        }
    }

    @ViewBuilder private func actionButton(_ action: AgentRowAction?, runtime: Runtime) -> some View {
        switch action {
        case .connect: SettingsPrimaryButton(title: "Connect") { agentsModel.connect(runtime) }
        case .reconnect: SettingsSecondaryButton(title: "Reconnect") { agentsModel.connect(runtime) }
        case .installPlugin: SettingsPrimaryButton(title: PluginOfferCopy.install) { Task { await pluginOffer.setPlugin(on: true) } }
        case .removeOldEntry: SettingsSecondaryButton(title: "Remove old entry") { agentsModel.removeOldEntry(runtime) }
        case .retry: SettingsSecondaryButton(icon: "arrow.clockwise", title: "Retry") { agentsModel.retry() }
        case .download: DownloadButton(url: PlaceInstallLinks.codexApp)
        case nil: EmptyView()
        }
    }

    @ViewBuilder private var setupChecklist: some View {
        if pluginOffer.showsSetupCard, let setup = pluginOffer.setup {
            TimelineView(.periodic(from: .now, by: 20)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    PluginSetupChecklist(setup: setup, now: context.date)
                    if setup.step == .waiting { PluginSetupWaitingButtons(offer: pluginOffer) }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.Colors.line).frame(height: 1)
        }
    }

    // MARK: Claude app

    private var claudeAppRow: some View {
        AgentListRow(
            title: "Claude app and Cowork",
            chip: claudeApp.isConnected ? ("Connected", true) : ClaudeAppModel.isInstalled(config: claudeApp.config) ? nil : ("Not installed", false),
            note: claudeApp.isConnected ? AgentPlaceCopy.claudeAppConnected : AgentPlaceCopy.claudeApp
        ) {
            if claudeApp.isConnected {
                SettingsSecondaryButton(title: "Disconnect", action: claudeApp.remove)
            } else if ClaudeAppModel.isInstalled(config: claudeApp.config) {
                SettingsPrimaryButton(title: "Connect", action: claudeApp.connectTapped)
            } else {
                DownloadButton(url: PlaceInstallLinks.claudeApp)
            }
        }
        .sheet(isPresented: $claudeApp.showsConfirm) {
            ClaudeAppConfirmSheet(onCancel: claudeApp.cancelConfirm, onAdd: claudeApp.confirmAdd)
        }
    }

    private func claudeAppProblem(_ message: String) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if claudeApp.canShowFile { SettingsSecondaryButton(title: "Show file", action: claudeApp.showFile) }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: Codex

    @ViewBuilder private var codexRow: some View {
        let row = row(.codex)
        AgentListRow(title: "Codex", chip: statusChip(row), note: codexNote(row)) {
            if row.status == .connecting {
                LoadingStatus(label: "Connecting")
            } else {
                actionButton(AgentRowAction.forRow(row, downloadWhenMissing: true), runtime: .codex)
            }
        }
    }

    private func codexNote(_ row: OnboardingModel.RuntimeRow) -> String? {
        row.status == .connected && row.plugin != .none ? AgentPlaceCopy.codexPlugin : nil
    }

    // MARK: T3 Code

    @ViewBuilder private var t3Rows: some View {
        AgentListRow(
            title: "T3 Code", chip: t3Chip, note: t3Note,
            showsDivider: t3.state == .installCLI || t3.failure != nil
        ) {
            HStack(spacing: 10) {
                if t3.busy { LoadingStatus(label: "Working…") }
                t3Action
            }
        }
        if t3.state == .installCLI {
            AgentListRow(title: "Install line", note: T3Command.installLine, showsDivider: t3.failure != nil) {
                SettingsCopyButton(text: T3Command.installLine)
            }
        }
        if let failure = t3.failure {
            Text(failure)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.accent)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Theme.Colors.line).frame(height: 1)
        }
    }

    private var t3Chip: (text: String, ok: Bool)? {
        switch t3.state {
        case .notOnMac: return ("Not installed", false)
        case .installCLI: return ("Needs the t3 command", false)
        case .scopeUnsupported: return ("Update needed", false)
        case .notConnected: return ("Not connected", false)
        case .connected: return ("Connected", true)
        case .expired: return ("Expired", false)
        }
    }

    private var t3Note: String? {
        switch t3.state {
        case .connected(let days): return "Renews in \(days) \(days == 1 ? "day" : "days")"
        case .installCLI: return "Run the line below in Terminal, then check again."
        case .scopeUnsupported: return "Your T3 Code cannot limit access yet. Update it, then check again."
        default: return nil
        }
    }

    @ViewBuilder private var t3Action: some View {
        switch t3.state {
        case .notOnMac:
            DownloadButton(url: PlaceInstallLinks.t3)
        case .installCLI, .scopeUnsupported:
            SettingsSecondaryButton(title: "Check again") { Task { await t3.refresh() } }.disabled(t3.busy)
        case .notConnected:
            SettingsPrimaryButton(title: "Connect") { Task { await t3.connect() } }.disabled(t3.busy)
        case .connected:
            SettingsSecondaryButton(title: "Disconnect") { Task { await t3.disconnect() } }.disabled(t3.busy)
        case .expired:
            SettingsPrimaryButton(title: "Renew") { Task { await t3.connect() } }.disabled(t3.busy)
        }
    }

    // MARK: Shared

    private func statusChip(_ row: OnboardingModel.RuntimeRow) -> (text: String, ok: Bool)? {
        switch row.status {
        case .connected: return ("Connected", true)
        case .probing, .connecting: return ("Checking…", false)
        case .couldNotCheck: return ("Couldn't check", false)
        case .notInstalled: return ("Not installed", false)
        case .notConnected: return ("Not connected", false)
        }
    }

    /// A failed move of the old entry, and the result of the plugin install.
    @ViewBuilder private var problems: some View {
        if let failure = migrationFailure { line(failure, color: Theme.Colors.ink2) }
        switch pluginOffer.phase {
        case .failed(let message): line(message, color: Theme.Colors.accent)
        case .done(let message): line(message, color: Theme.Colors.ok)
        case .idle, .working: EmptyView()
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .knockTextStyle(Theme.Typography.body12_5w400)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Copy affordance used by the Agents page's "Use it on your real work"
/// rows: outlined, reads "Copied" for a moment after a click - the same
/// timing `OnboardingCopySnippet` already uses, just the compact button
/// shape a table row needs instead of a whole card.
struct SettingsCopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        SettingsSecondaryButton(icon: copied ? "checkmark" : "doc.on.doc", title: copied ? "Copied" : label, action: copy)
    }

    static func write(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func copy() {
        Self.write(text)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// The note on Settings › Agents for people who share a setup (HAIL-193). If a team shares Claude
/// Code plugins or MCP config, Waggle replies "not set up" for anyone whose Mac has no finished
/// Waggle setup, so a colleague needs the install page, not a change to the shared config.
enum AgentsSharingNote {
    static let label = "SHARING YOUR AGENT SETUP"
    static let title = "Invite a colleague"
    static let subtitle = "If your team shares Claude Code plugins or MCP config, Waggle stays off for anyone who has not installed it. Send them the install page."
    static let installLink = "https://waggle.so/install"
    static let buttonTitle = "Copy waggle.so/install"
}
