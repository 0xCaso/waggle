import Foundation
import UserNotifications

/// Posts the one notification a new `needs_you` case gets, and opens that
/// exact case when the human clicks it (contract, docs/design/mvp-values.md
/// §M2 `HS75s`). Never instantiated by `swift test`: `UNUserNotificationCenter`
/// needs a bundled app, which is why the story's verification splits "swift
/// test for the notification builder" (pure `NotificationBuilder`/
/// `NotificationDeduper`, no `UserNotifications` import) from the operator's
/// manual click-through on the bundled app.
@MainActor
final class NotificationCenterController: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let deduper: NotificationDeduper
    private let onOpenCase: (String, Bool) -> Void

    init(
        center: UNUserNotificationCenter = .current(),
        deduper: NotificationDeduper = NotificationDeduper(),
        onOpenCase: @escaping (String, Bool) -> Void
    ) {
        self.center = center
        self.deduper = deduper
        self.onOpenCase = onOpenCase
        super.init()
        center.delegate = self
    }

    /// "The app asks for notification permission on first run." Safe to
    /// call on every launch: macOS only shows the system prompt once and
    /// remembers the human's answer after that.
    func requestAuthorization() {
        guard NotificationPermissionObserver.evidenceOverride() == nil else { return }
        // Users who granted alerts before `.badge` existed keep a badge
        // setting that is not enabled: ask again with the full option set.
        // macOS does not show the prompt again once it has decided.
        let center = self.center
        Task { @MainActor in
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined
                || DockBadgeSettingState.needsAuthorizationRetry(settings.badgeSetting)
            {
                _ = try? await center.requestAuthorization(options: NotificationAuthorization.options)
            }
            await NotificationPermissionObserver.shared.refresh()
        }
    }

    /// Posts the notification itself silent (no `UNNotificationSound`, same
    /// as before this story) and plays the Sound setting's choice locally
    /// instead - see `NotificationSoundPlayer`'s doc comment for why.
    func notify(_ content: NotificationContent, now: Date = Date()) {
        // A team comment is announced once by the daemon (WAG-394), so the 60 s case window does not apply to it.
        guard content.threadId != nil || deduper.shouldNotify(caseId: content.caseId, now: now) else { return }
        let mutable = UNMutableNotificationContent()
        mutable.title = content.title
        mutable.subtitle = content.subtitle
        mutable.body = content.body
        mutable.userInfo = ["case_id": content.caseId, "opens_comments": content.opensComments]
        if let threadId = content.threadId { mutable.threadIdentifier = threadId }
        let request = UNNotificationRequest(identifier: content.identifier, content: mutable, trigger: nil)
        center.add(request)
        NotificationSoundPlayer.play(NotificationSoundSettings.selected())
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shows the banner even while Knock is the active app; there is no
    /// separate in-app "needs you" surface this notification would
    /// otherwise duplicate against.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// "Clicking it activates the app and opens exactly that case
    /// (`userInfo.case_id` → `open(caseId:)`)." No action buttons are
    /// registered in the pilot, so `response.actionIdentifier` is always
    /// the default "open" action here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let caseId = userInfo["case_id"] as? String
        let opensComments = userInfo["opens_comments"] as? Bool ?? false
        Task { @MainActor in
            if let caseId {
                self.onOpenCase(caseId, opensComments)
            }
        }
        completionHandler()
    }
}
