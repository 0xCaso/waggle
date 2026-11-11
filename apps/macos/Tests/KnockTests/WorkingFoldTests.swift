import Foundation
import Testing
@testable import Knock

/// C11 (docs/decisions/2026-11-09-request-page-spec.md): the sidebar's Working group folds,
/// closed by default, the choice saved in its own key.
struct WorkingFoldTests {
    @Test func theWorkingGroupIsClosedByDefaultAndRemembersTheChoice() throws {
        let suite = "knock.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WorkingGroupSettings.isOpen(defaults: defaults) == false)
        WorkingGroupSettings.setOpen(true, defaults: defaults)
        #expect(WorkingGroupSettings.isOpen(defaults: defaults))
        WorkingGroupSettings.setOpen(false, defaults: defaults)
        #expect(WorkingGroupSettings.isOpen(defaults: defaults) == false)
    }

    @Test func theWorkingKeyIsItsOwnAndNeverFollowsAnswered() throws {
        let suite = "knock.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WorkingGroupSettings.key == "queueWorkingGroupOpen")
        #expect(WorkingGroupSettings.key != AnsweredGroupSettings.key)
        AnsweredGroupSettings.setOpen(true, defaults: defaults)
        #expect(WorkingGroupSettings.isOpen(defaults: defaults) == false)
    }

    @Test @MainActor func theModelReadsBackTheSavedChoiceAfterARelaunch() throws {
        let suite = "knock.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = KnockClient(socketPath: "/tmp/knock-nonexistent-\(UUID().uuidString).sock")
        let first = AppModel(client: client, environment: isolatedKnockEnvironment(), defaults: defaults)
        #expect(first.workingOpen == false)
        first.workingOpen = true
        #expect(defaults.bool(forKey: WorkingGroupSettings.key))
        let relaunched = AppModel(client: client, environment: isolatedKnockEnvironment(), defaults: defaults)
        #expect(relaunched.workingOpen)
        #expect(relaunched.answeredOpen == false)
        relaunched.workingOpen = false
        let again = AppModel(client: client, environment: isolatedKnockEnvironment(), defaults: defaults)
        #expect(again.workingOpen == false)
    }

    @Test @MainActor func theEvidenceFlagOpensTheGroupWithoutSavingIt() throws {
        let suite = "knock.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = KnockClient(socketPath: "/tmp/knock-nonexistent-\(UUID().uuidString).sock")
        let model = AppModel(
            client: client, environment: isolatedKnockEnvironment(["KNOCK_EVIDENCE_WORKING_OPEN": "1"]),
            defaults: defaults)
        #expect(model.workingOpen)
        #expect(defaults.object(forKey: WorkingGroupSettings.key) == nil)
    }

    @Test func theOnboardingFirstJobKeepsWorkingOpen() {
        let plain = SidebarSections.WorkingRow(id: "a", name: "A", meta: "", openCaseId: nil)
        var first = plain; first.isFirstJob = true
        let onIt = SidebarSections.WorkingRow(id: "b", name: "B", meta: "", openCaseId: nil, isOnboarding: true)
        #expect(SidebarSections.workingShowsRows([plain], saved: false) == false)
        #expect(SidebarSections.workingShowsRows([plain], saved: true))
        #expect(SidebarSections.workingShowsRows([plain, first], saved: false))
        #expect(SidebarSections.workingShowsRows([onIt], saved: false))
    }
}
