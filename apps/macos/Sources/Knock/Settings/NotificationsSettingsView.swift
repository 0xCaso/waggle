import SwiftUI
import UserNotifications

/// The Notifications page's Sound/question/reminder state (Contract). Each
/// setter writes straight through to `UserDefaults` (see
/// `NotificationPreferences.swift`) and mirrors the result into a
/// `@Published` property, the same read-after-write pattern
/// `PreviewsSettingsModel.setHTMLPreviewEnabled` already uses.
@MainActor
final class NotificationsSettingsModel: ObservableObject {
    @Published private(set) var sound: NotificationSound
    @Published private(set) var showsQuestion: Bool
    @Published private(set) var remindEnabled: Bool

    init() {
        sound = NotificationSoundSettings.selected()
        showsQuestion = NotificationQuestionSettings.isShown()
        remindEnabled = NotificationReminderSettings.isEnabled()
    }

    func setSound(_ sound: NotificationSound) {
        NotificationSoundSettings.setSelected(sound)
        self.sound = sound
    }

    func setShowsQuestion(_ shown: Bool) {
        NotificationQuestionSettings.setShown(shown)
        showsQuestion = shown
    }

    func setRemindEnabled(_ enabled: Bool) {
        NotificationReminderSettings.setEnabled(enabled)
        remindEnabled = enabled
    }

    func previewSound() {
        NotificationSoundPlayer.play(sound)
    }
}

/// The Notifications page (HAIL-50 contract for the permission row; this
/// story's contract for Sound/question/reminder). Reuses
/// `NotificationPermissionRow` exactly as `SettingsView` already did.
struct NotificationsSettingsView: View {
    @ObservedObject private var observer = NotificationPermissionObserver.shared
    @StateObject private var model = NotificationsSettingsModel()

    /// The row subtitle says the state, so the trailing side needs only
    /// the button.
    private var statusLine: String {
        switch observer.state {
        case .on: return "Turned on. Waggle alerts you the moment an agent needs a decision."
        case .off: return "Turned off in System Settings. Turn them on so you hear when an agent needs you."
        case .notAsked: return "Not allowed yet. Allow them so you hear when an agent needs you."
        }
    }

    var body: some View {
        SettingsPageChrome(title: SettingsPage.notifications.title, subtitle: SettingsPage.notifications.subtitle) {
            SettingsCard {
                SettingsCardRow(
                    title: "macOS notifications",
                    subtitle: statusLine,
                    showsDivider: observer.state != .notAsked
                ) {
                    NotificationPermissionRow(observer: .shared, onRequestPermission: requestPermission, showsStatusText: false)
                }
                if observer.state != .notAsked {
                    SettingsCardRow(
                        title: observer.dockBadge.statusLine,
                        subtitle: "The Needs you count on Waggle's Dock icon.",
                        showsDivider: false
                    ) {
                        if observer.dockBadge == .off {
                            Button(action: NotificationPermissionRow.openSystemSettings) {
                                Text("Open System Settings ›")
                                    .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                                    .foregroundColor(Theme.Colors.ink2)
                            }
                            .buttonStyle(.plain).pointerCursor()
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            SettingsCard {
                SettingsCardRow(title: "Sound", subtitle: "Plays with every notification.") {
                    HStack(spacing: 10) {
                        Picker(
                            "",
                            selection: Binding(get: { model.sound }, set: { model.setSound($0) })
                        ) {
                            ForEach(NotificationSound.allCases) { sound in
                                Text(sound.displayName).tag(sound)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)

                        Button(action: model.previewSound) {
                            Image(systemName: "play.circle")
                                .font(.system(size: 15))
                                .foregroundColor(Theme.Colors.ink2)
                        }
                        .buttonStyle(.plain).pointerCursor()
                        .disabled(model.sound == .none)
                        .help("Play the selected sound")
                    }
                }
                SettingsCardRow(
                    title: "Show the decision in the notification",
                    subtitle: "Off shows \"Your agent needs a decision\" and the project name only, for screen sharing."
                ) {
                    Toggle(
                        "",
                        isOn: Binding(get: { model.showsQuestion }, set: { model.setShowsQuestion($0) })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch).pointerCursor()
                }
                SettingsCardRow(
                    title: "Remind me if a decision waits",
                    subtitle: "Another notification after 15 minutes without an answer.",
                    showsDivider: false
                ) {
                    Toggle(
                        "",
                        isOn: Binding(get: { model.remindEnabled }, set: { model.setRemindEnabled($0) })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch).pointerCursor()
                }
            }
        }
    }

    /// Safe to call even when the tester already answered the system prompt
    /// once (KnockAppDelegate already requests at launch): macOS only ever
    /// shows it once and just replays the stored answer after that.
    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: NotificationAuthorization.options) { _, _ in
            Task { @MainActor in await NotificationPermissionObserver.shared.refresh() }
        }
    }
}
