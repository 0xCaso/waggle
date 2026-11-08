import Foundation

/// The title, body and identifier of the one macOS notification a
/// `needs_you` case gets (docs/protocol-mvp.md "case";
/// docs/design/mvp-values.md §M2 `HS75s`). Built by `NotificationBuilder`,
/// then handed to `NotificationCenterController` for posting. `subtitle`
/// carries the runtime label (KNOCK-20): the title/body strings stay exactly
/// the KNOCK-09 contract text, so the new connector label rides the
/// `UNMutableNotificationContent.subtitle` field the KNOCK-09 build left unset.
struct NotificationContent: Equatable, Sendable {
    let identifier: String
    let caseId: String
    let title: String
    let subtitle: String
    let body: String
    /// Notification Center groups items with the same thread id (WAG-394: the case id for team comments).
    var threadId: String? = nil
    /// WAG-397: a click opens the case on its Comments tab (a team comment).
    var opensComments = false
}
