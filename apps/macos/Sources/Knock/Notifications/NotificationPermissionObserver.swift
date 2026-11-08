import AppKit
import UserNotifications

/// App-wide, shared read of the real notification permission state
/// (contract: "Read `UNUserNotificationCenter.current().notificationSettings()`
/// when the setup window and Settings appear, after the request, and when
/// the app becomes active"). A singleton, like `IsolationGate`, so the setup
/// window and Settings (⌘,) - two separate SwiftUI roots - always show the
/// same state instead of each polling its own copy.
@MainActor
final class NotificationPermissionObserver: ObservableObject {
    static let shared = NotificationPermissionObserver()

    @Published private(set) var state: NotificationPermissionState = .notAsked

    @Published private(set) var dockBadge: DockBadgeSettingState = .off

    private let center: UNUserNotificationCenter
    private var didObserveActivation = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Evidence only: `KNOCK_EVIDENCE_NOTIFICATION_PERMISSION=off|on|denied`
    /// fakes the state (off = never asked, denied = macOS blocked it), so the
    /// setup step can be captured in each state without touching the real
    /// system permission. While set, nothing calls `requestAuthorization`.
    static func evidenceOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NotificationPermissionState? {
        switch environment["KNOCK_EVIDENCE_NOTIFICATION_PERMISSION"] {
        case "off": .notAsked
        case "on": .on
        case "denied": .off
        default: nil
        }
    }

    func refresh() async {
        if let fake = Self.evidenceOverride() {
            state = fake
            dockBadge = fake == .on ? .on : .off
            return
        }
        let settings = await center.notificationSettings()
        state = NotificationPermissionState.from(settings.authorizationStatus)
        dockBadge = DockBadgeSettingState.from(settings.badgeSetting)
    }

    /// Registers the app-activation refresh once. A tester who flips the
    /// permission in System Settings and switches back to Knock sees the
    /// change without reopening the setup window or Settings.
    func observeActivation() {
        guard !didObserveActivation else { return }
        didObserveActivation = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }
}
