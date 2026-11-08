import AppKit
import SwiftUI

/// Holds the Updates page's two toggle values (HAIL-52 contract): "Download
/// updates automatically" (Sparkle's own `automaticallyDownloadsUpdates`,
/// which Sparkle persists itself) and "Show a toast when an update is ready"
/// (`UpdateToastSettings`, this app's own `UserDefaults` flag). A separate
/// model rather than plain `@State`, matching every other Settings page, so
/// the load-once-on-appear/set-and-reread shape stays consistent.
@MainActor
final class UpdatesSettingsModel: ObservableObject {
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var toastEnabled = UpdateToastSettings.isEnabled()
    @Published private(set) var checkOnStart = LaunchUpdateCheckSettings.isEnabled()

    func load() {
        automaticallyDownloadsUpdates = Updater.automaticallyDownloadsUpdates
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        Updater.automaticallyDownloadsUpdates = enabled
        automaticallyDownloadsUpdates = Updater.automaticallyDownloadsUpdates
    }

    func setCheckOnStart(_ enabled: Bool) {
        LaunchUpdateCheckSettings.setEnabled(enabled)
        checkOnStart = LaunchUpdateCheckSettings.isEnabled()
    }

    func setToastEnabled(_ enabled: Bool) {
        UpdateToastSettings.setDisabled(!enabled)
        toastEnabled = UpdateToastSettings.isEnabled()
    }
}

/// The Updates page (HAIL-50 contract, extended HAIL-52): version, "Check
/// now" (`Updater.checkForUpdates`, disabled with the existing reason in dev
/// builds), last check time if Sparkle exposes it
/// (`updater.lastUpdateCheckDate`), 'What's new in <version>' opening
/// `UpdateReadyModel.releaseNotesURL`, plus "Download updates automatically",
/// "Show a toast when an update is ready", and an "Up to date"/"Update ready"
/// chip.
struct UpdatesSettingsView: View {
    @StateObject private var model = UpdatesSettingsModel()
    @ObservedObject private var updateReady = UpdateReadyModel.shared

    var body: some View {
        SettingsPageChrome(title: SettingsPage.updates.title, subtitle: SettingsPage.updates.subtitle) {
            SettingsCard {
                SettingsCardRow(title: "Waggle \(Updater.appVersion)", subtitle: checkSubtitle, showsDivider: true) {
                    HStack(spacing: 10) {
                        SettingsStatusChip(text: UpdateReadinessChip.label(isReady: updateReady.isReady), ok: true)
                        SettingsSecondaryButton(title: "Check now", action: Updater.checkForUpdates)
                            .disabled(!Updater.isAvailable)
                    }
                }
                SettingsCardLinkRow(
                    title: "What's new in \(Updater.appVersion)",
                    subtitle: "Know when a new version is ready",
                    showsDivider: false,
                    action: openWhatsNew
                )
            }
            SettingsCard {
                SettingsCardRow(
                    title: "Check for updates when Waggle starts",
                    subtitle: "Offers to install, wait or skip when a new version is out.",
                    showsDivider: true
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.checkOnStart },
                            set: { model.setCheckOnStart($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch).pointerCursor()
                    .disabled(!Updater.isAvailable)
                }
                SettingsCardRow(
                    title: "Download updates automatically",
                    subtitle: "Off still checks and tells you, but never downloads on its own.",
                    showsDivider: true
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.automaticallyDownloadsUpdates },
                            set: { model.setAutomaticallyDownloadsUpdates($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch).pointerCursor()
                    .disabled(!Updater.isAvailable)
                }
                SettingsCardRow(
                    title: "Show a toast when an update is ready",
                    subtitle: "Off still installs the update on quit, just without telling you first.",
                    showsDivider: false
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.toastEnabled },
                            set: { model.setToastEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch).pointerCursor()
                }
            }
        }
        .onAppear { model.load() }
    }

    private var checkSubtitle: String {
        guard Updater.isAvailable else { return "Updates are off in development builds" }
        guard let lastCheckDate = Updater.lastCheckDate else { return "Not checked yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked \(formatter.localizedString(for: lastCheckDate, relativeTo: Date()))"
    }

    private func openWhatsNew() {
        NSWorkspace.shared.open(UpdateReadyModel.releaseNotesURL(version: Updater.appVersion))
    }
}
