import Testing
import Foundation
@testable import Knock

/// The "Ask before opening links" toggle (HAIL-52 contract): on by default,
/// off skips the confirmation. Each case uses its own `UserDefaults` suite so
/// a test never touches the real one.
struct LinkConfirmSettingsTests {
    private func withTempDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "knock-link-confirm-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test func enabledByDefault() throws {
        try withTempDefaults { defaults in
            #expect(LinkConfirmSettings.isEnabled(defaults: defaults))
            #expect(!LinkConfirmSettings.isDisabled(defaults: defaults))
        }
    }

    @Test func setDisabledRoundTrips() throws {
        try withTempDefaults { defaults in
            LinkConfirmSettings.setDisabled(true, defaults: defaults)
            #expect(LinkConfirmSettings.isDisabled(defaults: defaults))
            #expect(!LinkConfirmSettings.isEnabled(defaults: defaults))

            LinkConfirmSettings.setDisabled(false, defaults: defaults)
            #expect(!LinkConfirmSettings.isDisabled(defaults: defaults))
            #expect(LinkConfirmSettings.isEnabled(defaults: defaults))
        }
    }
}

/// `LinkOpenPolicy.decide` (HAIL-52): a pure mirror of the toggle's own
/// meaning, testable without a settings fixture or a hosted view.
struct LinkOpenPolicyTests {
    @Test func confirmEnabledMeansConfirm() {
        #expect(LinkOpenPolicy.decide(confirmEnabled: true) == .confirm)
    }

    @Test func confirmDisabledMeansOpenDirectly() {
        #expect(LinkOpenPolicy.decide(confirmEnabled: false) == .openDirectly)
    }
}
