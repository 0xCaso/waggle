import AppKit
import SwiftUI

/// Runs `knock doctor` for the Help page and keeps every parsed line
/// (HAIL-50 contract: "'Check my setup' runs `knock doctor` and lists its
/// lines with ok/fail icons"). Reuses `DoctorLineParser` directly, the same
/// parser onboarding's own doctor probe uses.
@MainActor
final class HelpSettingsModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var results: [DoctorCheckResult] = []
    /// Every raw `knock doctor` stdout line, kept alongside the parsed
    /// `results` for "Copy diagnostics" (HAIL-52 contract: "the `knock
    /// doctor` output" - the command's own text, not a reformatted summary).
    @Published private(set) var rawLines: [String] = []

    private let runner: OnboardingCommandRunning

    init(runner: OnboardingCommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    func runCheck() async {
        isRunning = true
        var checks: [DoctorCheckResult] = []
        var lines: [String] = []
        _ = await runner.run(["doctor"], onLine: { line in
            lines.append(line)
            if let check = DoctorLineParser.parse(line) {
                checks.append(check)
            }
        })
        results = checks
        rawLines = lines
        isRunning = false
    }
}

/// The Help page (HAIL-50 contract, extended HAIL-52): "'Check my setup' runs
/// `knock doctor` and lists its lines with ok/fail icons; common fix row 'My
/// agent says Knock is unavailable' ...; Run setup again; 'Install guide'
/// link ..."; plus "Copy diagnostics": versions (app, daemon, macOS), the
/// `knock doctor` output and the last 50 lines of the update log, to the
/// clipboard - no ask content.
struct HelpSettingsView: View {
    let client: KnockClient
    let onboardingModel: OnboardingModel

    @StateObject private var model = HelpSettingsModel()
    @Environment(\.openWindow) private var openWindow
    @State private var diagnosticsCopied = false
    @State private var showsFullInstructions = false

    var body: some View {
        SettingsPageChrome(title: SettingsPage.help.title, subtitle: SettingsPage.help.subtitle) {
            checkCard
            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionLabel("COMMON FIXES")
                SettingsCard {
                    SettingsCardRow(
                        title: "My agent says Waggle is unavailable",
                        subtitle: "In Claude Code run /mcp, pick waggle, then Reconnect. Or start a new session.",
                        showsDivider: true
                    ) { EmptyView() }
                    SettingsCardLinkRow(
                        title: "Run setup again",
                        subtitle: "Connect agents and send a test decision, from step 1.",
                        showsDivider: false,
                        action: runSetupAgain
                    )
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionLabel("USE IT ON YOUR REAL WORK")
                SettingsCard {
                    SettingsCardRow(
                        title: "Prompt for a running session",
                        subtitle: OnboardingCopy.sessionPrompt,
                        subtitleLineLimit: 1
                    ) {
                        SettingsCopyButton(text: OnboardingCopy.sessionPrompt)
                    }
                    SettingsCardRow(
                        title: "Line for CLAUDE.md or AGENTS.md",
                        subtitle: OnboardingCopy.projectLine,
                        subtitleLineLimit: 1,
                        showsDivider: false
                    ) {
                        SettingsCopyButton(text: OnboardingCopy.projectLine)
                    }
                }
            }
            StarterPromptsSection()
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
            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionLabel("DIAGNOSTICS")
                SettingsCard {
                    SettingsCardRow(
                        title: "Copy diagnostics",
                        subtitle: "Versions, the setup check and the update log. Never a decision's content.",
                        showsDivider: false
                    ) {
                        SettingsSecondaryButton(
                            icon: diagnosticsCopied ? "checkmark" : "doc.on.doc",
                            title: diagnosticsCopied ? "Copied" : "Copy",
                            action: copyDiagnostics
                        )
                    }
                }
            }
            Button(action: { showsFullInstructions = true }) {
                Text("See the exact instructions")
                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    .foregroundColor(Theme.Colors.accent)
            }
            .buttonStyle(.plain).pointerCursor()
            Button(action: openInstallGuide) {
                HStack(spacing: 5) {
                    Text("Install guide")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(Theme.Colors.accent)
            }
            .buttonStyle(.plain).pointerCursor()
        }
        .task { await model.runCheck() }
        .sheet(isPresented: $showsFullInstructions) {
            AgentInstructionsFullTextSheet(onClose: { showsFullInstructions = false })
        }
    }

    private var checkCard: some View {
        SettingsCard {
            SettingsCardRow(
                title: "Check my setup",
                subtitle: "Runs waggle doctor: service, agents, sessions.",
                showsDivider: !model.results.isEmpty
            ) {
                SettingsPrimaryButton(title: "Run check") { Task { await model.runCheck() } }
                    .disabled(model.isRunning)
            }
            ForEach(Array(model.results.enumerated()), id: \.offset) { index, result in
                checkRow(result, showsDivider: index != model.results.count - 1)
            }
        }
    }

    private func checkRow(_ result: DoctorCheckResult, showsDivider: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: result.status).name)
                .foregroundColor(icon(for: result.status).color)
            Text(result.label)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .overlay(
            Rectangle().fill(showsDivider ? Theme.Colors.line : .clear).frame(height: 1),
            alignment: .bottom
        )
    }

    private func icon(for status: DoctorCheckStatus) -> (name: String, color: Color) {
        switch status {
        case .ok: ("checkmark.circle.fill", Theme.Colors.ok)
        case .fail: ("xmark.circle.fill", Theme.Colors.accent)
        case .skip: ("minus.circle.fill", Theme.Colors.ink3)
        }
    }

    private func runSetupAgain() {
        OnboardingMenuCommand.runSetupAgain(onboardingModel: onboardingModel, openWindow: openWindow)
    }

    /// "Copy diagnostics" (HAIL-52 contract): versions, `knock doctor`'s own
    /// output and the last 50 lines of the update log - never an ask's
    /// content. `service.status` failing (daemon unreachable) still copies
    /// with "unknown" for the daemon version, rather than doing nothing.
    private func copyDiagnostics() {
        Task {
            let daemonVersion = (try? await client.serviceStatus().version) ?? "unknown"
            let updateLogURL = UpdaterLogDelegate.logDirectory().appendingPathComponent("update.log")
            let text = DiagnosticsText.build(
                appVersion: Updater.appVersion,
                daemonVersion: daemonVersion,
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                doctorLines: model.rawLines,
                updateLogLines: UpdateLogTail.read(url: updateLogURL)
            )
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            diagnosticsCopied = true
            try? await Task.sleep(for: .seconds(1.5))
            diagnosticsCopied = false
        }
    }

    private func openInstallGuide() {
        guard let url = URL(string: "https://github.com/limone-eth/knock-releases#readme") else { return }
        NSWorkspace.shared.open(url)
    }
}
