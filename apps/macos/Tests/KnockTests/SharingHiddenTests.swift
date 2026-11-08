import Foundation
import Testing
@testable import Knock

/// Operator decision 8 Nov (case c_186e3e80): the daemon's SHARING_AVAILABLE hides Sharing. The app hides the
/// Sharing and Account pages and every share action.
@MainActor
struct SharingHiddenTests {
    @Test func hiddenSharingDropsTheSharingAndAccountPages() {
        let pages = SettingsPage.visible(sharingAvailable: false)
        #expect(!pages.contains(.sharing))
        #expect(!pages.contains(.account))
        #expect(pages.contains(.agents))
        #expect(SettingsPage.visible(sharingAvailable: true) == SettingsPage.allCases)
    }

    @Test func anOlderDaemonReadsAsAvailable() throws {
        let json = #"{"enabled":false,"shared_count":0,"share":null,"comments":[],"error":null}"#
        let state = try JSONDecoder().decode(SharingState.self, from: Data(json.utf8))
        #expect(state.available)
    }

    @Test func theDaemonSaysHiddenSoTheShareButtonStaysAway() async throws {
        let json = #"{"available":false,"enabled":false,"shared_count":0,"share":null,"comments":[],"error":null}"#
        let state = try JSONDecoder().decode(SharingState.self, from: Data(json.utf8))
        #expect(!state.available)
        #expect(!ShareSheetLogic.showsButton(enabled: state.enabled, isShared: state.share != nil))

        let nav = SettingsNavigationModel(environment: ["KNOCK_SETTINGS_PAGE": "sharing"])
        await nav.loadSharing { state }
        #expect(!nav.sharingAvailable)
        #expect(nav.selected == .agents)
        #expect(!nav.visiblePages.contains(.sharing))
    }
}
