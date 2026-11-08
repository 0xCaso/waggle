import Testing
import Foundation
@testable import Knock

/// HAIL-50: which page the Settings sidebar window opens on, and the
/// `KNOCK_SETTINGS_PAGE` evidence hook that lets an evidence run choose one
/// without a click.
struct SettingsPageTests {
    @Test func defaultsToAgentsWithNoEnvironmentOverride() {
        #expect(SettingsPage.initial(environment: [:]) == .agents)
    }

    @Test func everyPageRawValueRoundTripsThroughTheEnvironmentVariable() {
        for page in SettingsPage.allCases {
            let resolved = SettingsPage.initial(environment: ["KNOCK_SETTINGS_PAGE": page.rawValue])
            #expect(resolved == page)
        }
    }

    @Test func anUnrecognisedValueFallsBackToAgents() {
        #expect(SettingsPage.initial(environment: ["KNOCK_SETTINGS_PAGE": "not-a-page"]) == .agents)
    }

    @MainActor
    @Test func navigationModelSeedsItsSelectionFromTheEnvironment() {
        let navigation = SettingsNavigationModel(environment: ["KNOCK_SETTINGS_PAGE": "help"])
        #expect(navigation.selected == .help)
    }
}
