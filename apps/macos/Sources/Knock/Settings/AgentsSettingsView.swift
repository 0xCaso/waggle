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

/// The Agents page (HAIL-50 contract). Reuses `OnboardingRuntimeRowView` for
/// the two runtime rows (the exact same Connect mechanics as onboarding
/// O1) and `OnboardingCopy` for "Use it on your real work" -
/// the same words a tester already saw once, in onboarding's own payoff
/// screen.
struct AgentsSettingsView: View {
    let client: KnockClient
    let onboardingModel: OnboardingModel

    @StateObject private var agentsModel: AgentsSettingsModel
    @StateObject private var claudeApp = ClaudeAppModel()
    @ObservedObject private var pluginOffer = PluginOfferModel.shared
    @StateObject private var designHelpers = DesignHelpersModel()
    @StateObject private var t3Connection = T3ConnectionModel()
    @ObservedObject private var migration = LaunchMigrationStatus.shared
    @State private var showsFullInstructions = false
    @Environment(\.openWindow) private var openWindow

    init(client: KnockClient, onboardingModel: OnboardingModel) {
        self.client = client
        self.onboardingModel = onboardingModel
        _agentsModel = StateObject(wrappedValue: AgentsSettingsModel(liveRuntimes: {
            let sessions = (try? await client.sessionsList()) ?? []
            return Set(ConnectionModel.live(sessions).map(\.runtime))
        }, pluginOffer: PluginOfferModel.shared))
    }

    var body: some View {
        SettingsPageChrome(title: SettingsPage.agents.title, subtitle: SettingsPage.agents.subtitle) {
            runtimeCard.id(AgentPlaceCard.runtimes)
            Text("Waggle changes the Claude app's settings only after you press Connect and confirm.")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
            if claudeApp.justAdded && claudeApp.isConnected { ClaudeAppAfterNote() }
            if let failure = migration.pluginFailure {
                Text(failure)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PluginSettingsRows(offer: pluginOffer)
            DesignHelpersCard(model: designHelpers)
            AgentQuestionsSection(client: client)
            T3CodeCard(model: t3Connection).id(AgentPlaceCard.t3)
            AgentPlaceCards()
            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionLabel("USE IT ON YOUR REAL WORK")
                SettingsCard {
                    SettingsCardRow(
                        title: "Prompt for a running session",
                        subtitle: OnboardingCopy.sessionPrompt,
                        subtitleLineLimit: 1
                    ) {
                        copyButton(OnboardingCopy.sessionPrompt)
                    }
                    SettingsCardRow(
                        title: "Line for CLAUDE.md or AGENTS.md",
                        subtitle: OnboardingCopy.projectLine,
                        subtitleLineLimit: 1,
                        showsDivider: false
                    ) {
                        copyButton(OnboardingCopy.projectLine)
                    }
                }
            }
            sharingNote
            StarterPromptsSection()
            links
        }
        .task { await agentsModel.start() }
        .task { await designHelpers.refresh() }
        .onChange(of: pluginOffer.checks) { _, checks in agentsModel.applyPluginChecks(checks) }
        .sheet(isPresented: $showsFullInstructions) {
            AgentInstructionsFullTextSheet(onClose: { showsFullInstructions = false })
        }
    }

    private var runtimeCard: some View {
        // Each row pads only below its own divider, so the gap above the
        // next row comes from the stack spacing (matches the 14 below).
        VStack(alignment: .leading, spacing: 14) {
            ForEach(agentsModel.rows) { row in
                if row.runtime == .claude {
                    ClaudeRuntimeGroupView(
                        claudeCodeRow: row,
                        appModel: claudeApp,
                        showsDivider: row.id != agentsModel.rows.last?.id,
                        onConnect: { agentsModel.connect(row.runtime) },
                        onRetry: { agentsModel.retry() },
                        onRemoveOldEntry: { agentsModel.removeOldEntry(row.runtime) })
                } else {
                OnboardingRuntimeRowView(
                    row: row,
                    onConnect: { agentsModel.connect(row.runtime) },
                    showsDivider: row.id != agentsModel.rows.last?.id,
                    showsReconnectWhenConnected: true,
                    onRetry: { agentsModel.retry() },
                    onRemoveOldEntry: { agentsModel.removeOldEntry(row.runtime) }
                )
                }
            }
        }
        .padding(16)
        .background(Theme.Colors.win)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Colors.line, lineWidth: 1))
    }

    /// For people who share a setup (HAIL-193). Waggle stays off for anyone who has not installed it.
    private var sharingNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel(AgentsSharingNote.label)
            SettingsCard {
                SettingsCardRow(
                    title: AgentsSharingNote.title,
                    subtitle: AgentsSharingNote.subtitle,
                    showsDivider: false
                ) {
                    SettingsCopyButton(text: AgentsSharingNote.installLink, label: AgentsSharingNote.buttonTitle)
                }
            }
        }
    }

    private var links: some View {
        HStack(spacing: 20) {
            Button(action: { showsFullInstructions = true }) {
                Text("See the exact instructions")
                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    .foregroundColor(Theme.Colors.accent)
            }
            .buttonStyle(.plain).pointerCursor()
            Button(action: runSetupAgain) {
                Text("Run setup again")
                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    .foregroundColor(Theme.Colors.ink2)
            }
            .buttonStyle(.plain).pointerCursor()
        }
    }

    /// "Run setup again" (contract: "same action as the menu's Set Up
    /// Knock…, including `OnboardingLaunchPolicy.requestExplicitOpen()`").
    private func runSetupAgain() {
        OnboardingMenuCommand.runSetupAgain(onboardingModel: onboardingModel, openWindow: openWindow)
    }

    private func copyButton(_ text: String) -> some View {
        SettingsCopyButton(text: text)
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
