import Testing
import Foundation
@testable import Knock

/// The "Show a toast when an update is ready" toggle (HAIL-52 contract): on
/// by default. Each case uses its own `UserDefaults` suite so a test never
/// touches the real one.
struct UpdateToastSettingsTests {
    private func withTempDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "knock-update-toast-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test func enabledByDefault() throws {
        try withTempDefaults { defaults in
            #expect(UpdateToastSettings.isEnabled(defaults: defaults))
            #expect(!UpdateToastSettings.isDisabled(defaults: defaults))
        }
    }

    @Test func setDisabledRoundTrips() throws {
        try withTempDefaults { defaults in
            UpdateToastSettings.setDisabled(true, defaults: defaults)
            #expect(UpdateToastSettings.isDisabled(defaults: defaults))
            #expect(!UpdateToastSettings.isEnabled(defaults: defaults))

            UpdateToastSettings.setDisabled(false, defaults: defaults)
            #expect(!UpdateToastSettings.isDisabled(defaults: defaults))
            #expect(UpdateToastSettings.isEnabled(defaults: defaults))
        }
    }
}

/// `UpdateReadinessChip.label` (HAIL-52): pure text rule for the Updates
/// page's status chip.
struct UpdateReadinessChipTests {
    @Test func upToDateWhenNotReady() {
        #expect(UpdateReadinessChip.label(isReady: false) == "Up to date")
    }

    @Test func updateReadyWhenReady() {
        #expect(UpdateReadinessChip.label(isReady: true) == "Update ready")
    }
}
