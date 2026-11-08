import SwiftUI

/// The "T3 Code" card on Settings > Agents (WAG-264). One row for the state with its buttons,
/// and, when the `t3` command is missing, one row with T3's install line and a Copy button.
struct T3CodeCard: View {
    @ObservedObject var model: T3ConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("T3 CODE")
            SettingsCard {
                SettingsCardRow(
                    title: model.state.title, subtitle: model.state.help,
                    showsDivider: model.state == .installCLI || model.failure != nil
                ) {
                    HStack(spacing: 10) {
                        if model.busy { LoadingStatus(label: "Working…") }
                        buttons
                    }
                }
                if model.state == .installCLI {
                    SettingsCardRow(
                        title: "Install line", subtitle: T3Command.installLine, subtitleLineLimit: 1,
                        showsDivider: model.failure != nil
                    ) {
                        SettingsCopyButton(text: T3Command.installLine)
                    }
                }
                if let failure = model.failure {
                    Text(failure)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task { await model.refresh() }
    }

    @ViewBuilder private var buttons: some View {
        switch model.state {
        case .notOnMac: EmptyView()
        case .installCLI, .scopeUnsupported:
            SettingsSecondaryButton(title: "Check again") { Task { await model.refresh() } }
                .disabled(model.busy)
        case .notConnected:
            SettingsPrimaryButton(title: "Connect") { Task { await model.connect() } }
                .disabled(model.busy)
        case .connected:
            SettingsSecondaryButton(title: "Renew") { Task { await model.connect() } }
                .disabled(model.busy)
            SettingsSecondaryButton(title: "Disconnect") { Task { await model.disconnect() } }
                .disabled(model.busy)
        case .expired:
            SettingsPrimaryButton(title: "Renew") { Task { await model.connect() } }
                .disabled(model.busy)
        }
    }
}
