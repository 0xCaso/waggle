import Foundation

/// Suppresses a repeat notification for the same case within `window`
/// seconds (contract: "No notification for revisions of a case already
/// notified within the last 60 s").
///
/// Not synchronized: every caller in this app runs on the main actor
/// (`NotificationCenterController`), so a lock would only add overhead.
final class NotificationDeduper {
    private var lastNotifiedAt: [String: Date] = [:]
    private let window: TimeInterval

    init(window: TimeInterval = 60) {
        self.window = window
    }

    /// Returns whether `caseId` should notify at `now`. When it does, `now`
    /// is recorded as that case's last notification time.
    func shouldNotify(caseId: String, now: Date) -> Bool {
        if let last = lastNotifiedAt[caseId], now.timeIntervalSince(last) < window {
            return false
        }
        lastNotifiedAt[caseId] = now
        return true
    }
}
