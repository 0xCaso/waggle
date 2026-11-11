import SwiftUI

/// Step 1 "Connect your agent" (WAG-338). The per-runtime rows are the ones the old setup had
/// (HAIL-20/HAIL-24); one connected agent is enough, and it is the only required step.
struct OnboardingConnectView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingHeaderView(
                title: "Connect your agent",
                subtitle: "Waggle is where your agents bring you decisions. Connect the one you use. One is enough."
            )
            VStack(alignment: .leading, spacing: 14) {
                rows
            }
            if model.claudeApp.justAdded && model.claudeApp.isConnected { ClaudeAppOnboardingNote() }
            Text("No step is required. Everything else can wait, and lives in Settings.")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                SettingsSecondaryButton(title: "Check again", action: model.recheck)
                    .disabled(!ConnectStepRules.checkAgainIsAvailable(phase: model.connectPhase))
                Spacer()
                OnboardingGhostButton(title: "Skip for now", action: model.skipSetup)
                OnboardingPrimaryButton(title: "Next: your first job", systemImage: "arrow.right", trailing: true, action: model.continueFromConnect)
                    .disabled(!model.connectSucceeded)
            }
        }
    }

    /// Claude is a group with two places, like Settings > Agents (HAIL-175).
    @ViewBuilder private func runtimeRow(_ row: OnboardingModel.RuntimeRow, isLast: Bool) -> some View {
        if row.runtime == .claude {
            ClaudeRuntimeGroupView(
                claudeCodeRow: row,
                appModel: model.claudeApp,
                showsDivider: !isLast,
                onConnect: { model.connect(row.runtime) },
                onRetry: { model.recheck() },
                onRemoveOldEntry: nil,
                showsReconnectWhenConnected: false,
                appStyle: .onboarding)
        } else {
            OnboardingRuntimeRowView(
                row: row, onConnect: { model.connect(row.runtime) }, showsDivider: !isLast,
                onRetry: { model.recheck() }, oneAction: true)
        }
    }

    @ViewBuilder private var rows: some View {
        switch model.connectPhase {
        case .idle:
            EmptyView()
        case .checking:
            ForEach(Runtime.allCases, id: \.self) { runtime in
                runtimeRow(
                    OnboardingModel.RuntimeRow(runtime: runtime, status: .probing),
                    isLast: runtime == Runtime.allCases.last)
            }
        case .loaded(let rows):
            ForEach(rows) { row in
                runtimeRow(row, isLast: row.id == rows.last?.id)
            }
            if model.didRegisterDevelopmentBuildPath {
                Text("Registered a development build path. Reinstall from ~/Applications for testers.")
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.accent)
            }
        }
    }
}

/// Not `private`: the Settings window's Agents page (HAIL-50) reuses this
/// exact sheet for its own "See the exact instructions" link.
struct AgentInstructionsFullTextSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The exact instructions")
                .knockTextStyle(Theme.Typography.cardTitle15w650)
                .foregroundColor(Theme.Colors.ink)
            AgentInstructionsColumns()
            ScrollView {
                Text(AgentInstructions.agentInstructionsFullText())
                    .knockTextStyle(Theme.Typography.monoMeta11_5w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(.plain).pointerCursor()
                    .knockTextStyle(Theme.Typography.button13_5w500)
                    .foregroundColor(Theme.Colors.ink)
            }
        }
        .padding(24)
        .frame(width: 600, height: 480)
        // The sheet took the system's dark window background in dark mode,
        // under Knock's light-theme ink text: unreadable (operator, 29 Sep).
        // Knock is light-only, like its other windows.
        .background(Theme.Colors.win)
    }
}
