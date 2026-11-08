import Foundation

/// The three Notifications-page settings (Contract), each persisted in
/// `UserDefaults.standard`. Unlike `HTMLPreviewSettings`/`OnboardingState`
/// (marker files under the `KNOCK_HOME`-scoped data root), these live in
/// `UserDefaults`: the brief for this story calls for the app bundle's own
/// defaults domain, so a disposable `KNOCK_BUNDLE_ID` evidence/test copy
/// already writes to its own `~/Library/Preferences/<id>.plist` and can never
/// touch the operator's real one. Every accessor still takes an injectable
/// `UserDefaults` so a unit test can use an ephemeral suite instead of
/// `.standard`.
enum NotificationSoundSettings {
    private static let key = "notificationSound"

    /// Default `.none`: `NotificationCenterController.notify` never set a
    /// `UNNotificationSound` before this story, so silence is "the current
    /// behaviour" the contract asks this default to keep.
    static func selected(defaults: UserDefaults = .standard) -> NotificationSound {
        guard let raw = defaults.string(forKey: key), let sound = NotificationSound(rawValue: raw) else {
            return .none
        }
        return sound
    }

    static func setSelected(_ sound: NotificationSound, defaults: UserDefaults = .standard) {
        defaults.set(sound.rawValue, forKey: key)
    }

    /// True once a sound (even `.none`) was ever chosen. The setup step's
    /// "preselect Tink when nothing was ever set" needs this: `selected` alone
    /// cannot tell "never set" from "chose No sound".
    static func hasBeenSet(defaults: UserDefaults = .standard) -> Bool {
        guard let raw = defaults.string(forKey: key) else { return false }
        return NotificationSound(rawValue: raw) != nil
    }
}

enum NotificationQuestionSettings {
    private static let key = "notificationShowsQuestion"

    /// On by default (Contract). `object(forKey:)` (not `bool(forKey:)`, which
    /// returns `false` for an unset key) is what makes "never set" default
    /// true instead of false.
    static func isShown(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? true
    }

    static func setShown(_ shown: Bool, defaults: UserDefaults = .standard) {
        defaults.set(shown, forKey: key)
    }
}

enum NotificationReminderSettings {
    private static let key = "notificationRemindEnabled"

    /// Off by default (Contract).
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? false
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}
