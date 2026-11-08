import AppKit
import SwiftUI

/// The notification-permission row shown by step 3 of setup and by Settings
/// (contract: "Settings (⌘,) gets the same row"): one of three states read
/// from `NotificationPermissionObserver`, a request button when the
/// permission was never asked, or - once it was asked and denied - a button
/// straight to this app's pane in System Settings.
struct NotificationPermissionRow: View {
    @ObservedObject var observer: NotificationPermissionObserver
    let onRequestPermission: () -> Void
    /// False in Settings, whose row subtitle already says the state; the
    /// trailing side then holds only the button (a squeezed "Notificati /
    /// ons are off" column, 29 Sep).
    var showsStatusText: Bool = true

    var body: some View {
        content
            .task { await observer.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch observer.state {
        case .on:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Theme.Colors.ok)
                Text("Notifications on")
                    .knockTextStyle(Theme.Typography.micro12w600)
                    .foregroundColor(Theme.Colors.ok)
            }
        case .off:
            HStack(spacing: 8) {
                if showsStatusText {
                    Text("Notifications are off")
                        .knockTextStyle(Theme.Typography.caption11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .fixedSize()
                }
                OnboardingSmallButton(icon: "gearshape.fill", title: "Open System Settings", action: Self.openSystemSettings)
                    // Keep the label on one line; the row's description wraps instead.
                    .fixedSize(horizontal: true, vertical: false)
            }
        case .notAsked:
            OnboardingSmallButton(icon: "bell.fill", title: "Allow notifications", action: onRequestPermission)
        }
    }

    /// `x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=<bundle id>`
    /// opens this app's own notification pane directly, rather than the
    /// general Notifications settings list.
    static func openSystemSettings() {
        let bundleId = Bundle.main.bundleIdentifier ?? "dev.limone.knock"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)") else { return }
        NSWorkspace.shared.open(url)
    }
}
