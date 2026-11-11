import AppKit
import SwiftUI

/// HAIL-164: the optional "Claude app and Cowork" place under the Claude row in
/// Settings > Agents. It changes the Claude app's settings file only after the
/// person presses Connect and confirms.
@MainActor
final class ClaudeAppModel: ObservableObject {
    @Published private(set) var status: ClaudeDesktopConfig.Status = .notConnected
    @Published var showsConfirm = false
    @Published private(set) var errorMessage: String?
    /// True after an add in this window: shows the restart note.
    @Published private(set) var justAdded = false

    let config: ClaudeDesktopConfig
    private let binaryPath: () -> String?

    static let unreadableMessage = "Waggle could not read the Claude app's settings file. Nothing was changed."

    init(
        config: ClaudeDesktopConfig = .standard(),
        binaryPath: @escaping () -> String? = { KnockBinaryLocator.resolve()?.path }
    ) {
        self.config = config
        self.binaryPath = binaryPath
        refresh()
    }

    var isConnected: Bool { status == .connected }

    func refresh() {
        status = config.status()
        if status == .unreadable { errorMessage = Self.unreadableMessage }
        // HAIL-176: a failed move of the old entry shows here until the person connects again.
        else if errorMessage == nil, status != .connected, let failure = LaunchMigrationStatus.shared.claudeAppFailure {
            errorMessage = failure
        }
    }

    func connectTapped() { showsConfirm = true }

    func cancelConfirm() { showsConfirm = false }

    /// "Add Knock" in the confirm sheet.
    func confirmAdd() {
        showsConfirm = false
        guard let path = binaryPath() else {
            errorMessage = "Waggle could not find its own program, so it added nothing."
            return
        }
        apply { try config.add(binaryPath: path) }
        if errorMessage == nil { justAdded = true }
    }

    func remove() {
        apply { try config.remove() }
        justAdded = false
    }

    private func apply(_ change: () throws -> Void) {
        errorMessage = nil
        do {
            try change()
        } catch ClaudeDesktopConfig.ConfigError.unreadable {
            errorMessage = Self.unreadableMessage
        } catch {
            errorMessage = "Waggle could not write the Claude app's settings file. Nothing was changed."
        }
        status = config.status()
        if status == .unreadable { errorMessage = Self.unreadableMessage }
        if errorMessage == nil, status == .connected { LaunchMigrationStatus.shared.claudeAppFailure = nil }
    }

    /// The Claude app is on this Mac: its app folder, or the settings folder it makes on first launch.
    static func isInstalled(config: ClaudeDesktopConfig, fileManager: FileManager = .default) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return fileManager.fileExists(atPath: "/Applications/Claude.app")
            || fileManager.fileExists(atPath: home + "/Applications/Claude.app")
            || fileManager.fileExists(atPath: config.fileURL.deletingLastPathComponent().path)
    }

    var canShowFile: Bool { FileManager.default.fileExists(atPath: config.fileURL.path) }

    func showFile() {
        NSWorkspace.shared.activateFileViewerSelecting([config.fileURL])
    }
}

private enum ClaudeAppStyle {
    static let groupTitle = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 14).weight(.semibold),
        size: 14, lineHeight: nil, letterSpacing: nil)
}

/// The Claude group: one header, then "Claude Code" and "Claude app and Cowork" under it.
struct ClaudeRuntimeGroupView: View {
    let claudeCodeRow: OnboardingModel.RuntimeRow
    @ObservedObject var appModel: ClaudeAppModel
    var showsDivider: Bool
    let onConnect: () -> Void
    let onRetry: () -> Void
    let onRemoveOldEntry: (() -> Void)?
    /// Onboarding (HAIL-175) never shows "Reconnect" and words the Claude app place its own way.
    var showsReconnectWhenConnected = true
    var appStyle: ClaudeAppPlaceRow.Style = .settings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Colors.ink2)
                Text("Claude")
                    .knockTextStyle(ClaudeAppStyle.groupTitle)
                    .foregroundColor(Theme.Colors.ink)
            }
            OnboardingRuntimeRowView(
                row: claudeCodeRow,
                onConnect: onConnect,
                showsDivider: false,
                showsReconnectWhenConnected: showsReconnectWhenConnected,
                onRetry: onRetry,
                onRemoveOldEntry: onRemoveOldEntry,
                isNested: true)
            ClaudeAppPlaceRow(model: appModel, style: appStyle)
        }
        .padding(EdgeInsets(top: 0, leading: 0, bottom: showsDivider ? 14 : 0, trailing: 0))
        .overlay(
            Rectangle().fill(showsDivider ? Theme.Colors.line : .clear).frame(height: 1),
            alignment: .bottom)
    }
}

struct ClaudeAppPlaceRow: View {
    enum Style { case settings, onboarding }

    @ObservedObject var model: ClaudeAppModel
    var style: Style = .settings

    private var subline: String {
        switch (style, model.isConnected) {
        case (.settings, true): return "Added to claude_desktop_config.json. A backup is next to it."
        case (.settings, false): return "For chats and Cowork. No terminal needed. Optional."
        case (.onboarding, true): return "Added to the Claude app settings. Backup kept."
        case (.onboarding, false): return "For chats and Cowork tasks. No terminal needed."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("Claude app and Cowork")
                            .knockTextStyle(Theme.Typography.button13_5w500)
                            .foregroundColor(Theme.Colors.ink)
                        if model.isConnected {
                            RuntimeStatusChip(text: "Connected", fg: Theme.Colors.ok, bg: Theme.Colors.ok.opacity(0.1))
                        } else {
                            RuntimeStatusChip(text: "Not connected", fg: Theme.Colors.ink2, bg: Theme.Colors.side)
                        }
                    }
                    Text(subline)
                        .knockTextStyle(style == .onboarding ? Theme.Typography.monoMeta11_5w400 : Theme.Typography.recommendLine12w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // The button keeps its natural size; the text column takes the rest and wraps.
                Group {
                    if model.isConnected {
                        if style == .onboarding {
                            Button(action: model.remove) {
                                Text("Remove")
                                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                                    .foregroundColor(Theme.Colors.ink2)
                            }
                            .buttonStyle(.plain).pointerCursor()
                        } else {
                            SettingsSecondaryButton(icon: "trash", title: "Remove", action: model.remove)
                        }
                    } else {
                        OnboardingSmallButton(icon: "bolt.fill", title: "Connect", action: model.connectTapped)
                    }
                }
                .fixedSize()
                .layoutPriority(1)
            }
            if let message = model.errorMessage {
                HStack(spacing: 10) {
                    Text(message)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if model.canShowFile {
                        SettingsSecondaryButton(title: "Show file", action: model.showFile)
                    }
                }
            }
        }
        .padding(.leading, 16)
        .sheet(isPresented: $model.showsConfirm) {
            ClaudeAppConfirmSheet(onCancel: model.cancelConfirm, onAdd: model.confirmAdd)
        }
    }
}

/// The confirm sheet (approved copy).
struct ClaudeAppConfirmSheet: View {
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Waggle to the Claude app?")
                .knockTextStyle(Theme.Typography.panelTitleSm16w650)
                .foregroundColor(Theme.Colors.ink)
            Text("Waggle adds one entry, \"waggle\", to this file. Your other servers stay exactly as they are.")
                .knockTextStyle(Theme.Typography.body13_5w400)
                .foregroundColor(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(ClaudeDesktopConfig.displayPath)
                .knockTextStyle(Theme.Typography.monoMeta11_5w400)
                .foregroundColor(Theme.Colors.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.side)
                .cornerRadius(8)
            Text("A backup is saved next to it first. Remove takes the entry out again.")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                SettingsSecondaryButton(title: "Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                SettingsPrimaryButton(title: "Add Waggle", action: onAdd)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.Colors.win)
        .cornerRadius(12)
        .preferredColorScheme(.light)
    }
}

/// Onboarding (HAIL-175): the grey note under the rows after a connect in this window.
struct ClaudeAppOnboardingNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quit and reopen the Claude app once")
                .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                .foregroundColor(Theme.Colors.ink)
            Text("The Claude app loads Waggle when it starts. Then Waggle shows in the tools menu of a chat or a Cowork task.")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(10)
    }
}

/// Below the card, after adding: the restart note and what to expect in the Claude app.
struct ClaudeAppAfterNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Restart the Claude app to finish")
                    .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                    .foregroundColor(Theme.Colors.ink)
                Text("Quit Claude, then open it again. Waggle never restarts it for you.")
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.honeySoft)
            .cornerRadius(10)
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionLabel("IN THE CLAUDE APP")
                Text("· Your answer is not pushed into the chat. Say \"check Waggle\" to continue.")
                Text("· No status line. Decisions still arrive here and as notifications.")
            }
            .knockTextStyle(Theme.Typography.body12_5w400)
            .foregroundColor(Theme.Colors.ink2)
        }
    }
}
