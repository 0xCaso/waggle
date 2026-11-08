import Foundation
import UserNotifications

/// The sample notification the setup step's sound list shows (HAIL-82):
/// "Knock · sample" / "This is how a decision will look.". Posted for real when
/// notifications are allowed, drawn inside the setup window otherwise.
enum NotificationSample {
    static let title = "Waggle · sample"
    static let body = "This is how a decision will look."

    /// Posts the real sample. Silent, like every Knock notification: the
    /// caller plays the chosen sound locally (see `NotificationSoundPlayer`).
    static func post(center: UNUserNotificationCenter = .current()) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: "sample.\(UUID().uuidString)", content: content, trigger: nil))
    }
}
