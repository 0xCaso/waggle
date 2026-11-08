import Testing
import UserNotifications
@testable import Knock

/// HAIL-24: the pure `UNAuthorizationStatus` -> `NotificationPermissionState`
/// mapping the setup window and Settings both read to show "Notifications
/// on", "Notifications are off", or the request button.
struct NotificationPermissionStateTests {
    @Test func notDeterminedMapsToNotAsked() {
        #expect(NotificationPermissionState.from(.notDetermined) == .notAsked)
    }

    @Test func deniedMapsToOff() {
        #expect(NotificationPermissionState.from(.denied) == .off)
    }

    @Test func authorizedMapsToOn() {
        #expect(NotificationPermissionState.from(.authorized) == .on)
    }

    @Test func provisionalMapsToOnSinceItAlreadyDeliversWithoutAFurtherAsk() {
        #expect(NotificationPermissionState.from(.provisional) == .on)
    }
}

/// HAIL-90: the Dock badge needs `.badge` authorization, and Settings maps
/// `badgeSetting` to its row state.
struct DockBadgeAuthorizationTests {
    @Test func requestOptionsIncludeBadgeAlertAndSound() {
        let options = NotificationAuthorization.options
        #expect(options.contains(.badge))
        #expect(options.contains(.alert))
        #expect(options.contains(.sound))
    }

    @Test func enabledMapsToOn() {
        #expect(DockBadgeSettingState.from(.enabled) == .on)
    }

    @Test func disabledAndNotSupportedMapToOff() {
        #expect(DockBadgeSettingState.from(.disabled) == .off)
        #expect(DockBadgeSettingState.from(.notSupported) == .off)
    }

    @Test func retryOnlyWhenNotEnabled() {
        #expect(DockBadgeSettingState.needsAuthorizationRetry(.disabled))
        #expect(!DockBadgeSettingState.needsAuthorizationRetry(.enabled))
    }

    @Test func statusLines() {
        #expect(DockBadgeSettingState.on.statusLine == "Dock badge: On")
        #expect(DockBadgeSettingState.off.statusLine == "Dock badge: Off in System Settings")
    }
}
