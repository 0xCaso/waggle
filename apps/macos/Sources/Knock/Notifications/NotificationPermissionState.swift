import UserNotifications

/// The three states the setup window's step 3 and Settings show for
/// notification permission (contract: "Notification permission shows the
/// real state"). A pure mapping from `UNAuthorizationStatus`, kept apart
/// from `UNUserNotificationCenter` itself (which needs a bundled app to run,
/// see `NotificationCenterController`) so the mapping is unit-testable under
/// plain `swift test`.
enum NotificationPermissionState: Equatable {
    /// The system prompt was never answered: show the request button.
    case notAsked
    /// Authorized (or provisional, which also delivers without a further
    /// ask): "Notifications on", green check.
    case on
    /// Denied: "Notifications are off" with a button to System Settings.
    case off

    static func from(_ status: UNAuthorizationStatus) -> NotificationPermissionState {
        switch status {
        case .notDetermined:
            .notAsked
        case .denied:
            .off
        case .authorized, .provisional:
            .on
        @unknown default:
            .notAsked
        }
    }
}

/// The options every `requestAuthorization` call in the app asks for
/// (HAIL-90). macOS draws an app's Dock badge only when the app is authorized
/// for "Badge application icon", so `.badge` must be part of the request, or
/// `NSApp.dockTile.badgeLabel` is set but never drawn.
enum NotificationAuthorization {
    static let options: UNAuthorizationOptions = [.alert, .sound, .badge]
}

/// The Dock badge row in Settings > Notifications: "On" or "Off in System
/// Settings". Mapped from `UNNotificationSettings.badgeSetting`, apart from
/// `UNUserNotificationCenter` so it is unit-testable.
enum DockBadgeSettingState: Equatable {
    case on
    case off

    static func from(_ setting: UNNotificationSetting) -> DockBadgeSettingState {
        setting == .enabled ? .on : .off
    }

    /// Ask once more when the badge is not enabled. Skipped while the state
    /// is unknown-good (enabled). Never prompts again once macOS decided.
    static func needsAuthorizationRetry(_ setting: UNNotificationSetting) -> Bool {
        setting != .enabled
    }

    var statusLine: String {
        switch self {
        case .on: "Dock badge: On"
        case .off: "Dock badge: Off in System Settings"
        }
    }
}
