import Testing
import Foundation
@testable import Knock

/// Sound/question/reminder persistence and defaults (Contract). Each test
/// uses its own ephemeral `UserDefaults` suite, removed afterwards, so a
/// run never reads or writes the test runner's real defaults domain.
struct NotificationPreferencesTests {
    private func withEphemeralDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "knock-test-notifications-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    // MARK: - Sound

    @Test func soundDefaultsToNone() throws {
        try withEphemeralDefaults { defaults in
            #expect(NotificationSoundSettings.selected(defaults: defaults) == .none)
        }
    }

    @Test func soundRoundTrips() throws {
        try withEphemeralDefaults { defaults in
            NotificationSoundSettings.setSelected(.glass, defaults: defaults)
            #expect(NotificationSoundSettings.selected(defaults: defaults) == .glass)
            NotificationSoundSettings.setSelected(.none, defaults: defaults)
            #expect(NotificationSoundSettings.selected(defaults: defaults) == .none)
        }
    }

    @Test func soundSystemNamesMatchTheFiveApprovedSounds() {
        let named = Set(NotificationSound.allCases.compactMap(\.systemSoundName))
        #expect(named == ["Tink", "Glass", "Pop", "Ping", "Purr"])
    }

    // MARK: - Show the question

    @Test func showsQuestionDefaultsToOn() throws {
        try withEphemeralDefaults { defaults in
            #expect(NotificationQuestionSettings.isShown(defaults: defaults))
        }
    }

    @Test func showsQuestionRoundTrips() throws {
        try withEphemeralDefaults { defaults in
            NotificationQuestionSettings.setShown(false, defaults: defaults)
            #expect(!NotificationQuestionSettings.isShown(defaults: defaults))
            NotificationQuestionSettings.setShown(true, defaults: defaults)
            #expect(NotificationQuestionSettings.isShown(defaults: defaults))
        }
    }

    // MARK: - Remind me if a request waits

    @Test func reminderDefaultsToOff() throws {
        try withEphemeralDefaults { defaults in
            #expect(!NotificationReminderSettings.isEnabled(defaults: defaults))
        }
    }

    @Test func reminderRoundTrips() throws {
        try withEphemeralDefaults { defaults in
            NotificationReminderSettings.setEnabled(true, defaults: defaults)
            #expect(NotificationReminderSettings.isEnabled(defaults: defaults))
            NotificationReminderSettings.setEnabled(false, defaults: defaults)
            #expect(!NotificationReminderSettings.isEnabled(defaults: defaults))
        }
    }
}
