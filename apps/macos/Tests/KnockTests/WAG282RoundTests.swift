import Foundation
import Testing
@testable import Knock

/// WAG-282: the decision page, the full-size panel, the sidebar row and the notification show the newest
/// round, never the first one. The fixtures are the daemon's own `cases.get` results for each kind of
/// waggle_update (`WAG282_FIXTURES=… bun test test/wag-282-rounds.test.ts` writes them).
@MainActor
struct WAG282RoundTests {
    private func detail(_ name: String) throws -> CaseDetail {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wag-282/\(name).json")
        return try JSONDecoder().decode(CaseDetail.self, from: Data(contentsOf: url))
    }

    private let firstNeed = "Review the drawn flow of 25 screens."

    @Test func questionUpdateWithOptionsLeadsWithRoundTwo() throws {
        let c = try detail("question-options").case
        let heading = try #require(c.roundHeading)
        #expect(heading.tag == "Round 2")
        #expect(heading.title == "Where does the intake go in the demo?")
        #expect(heading.was == "Was: Investor demo: is this the flow to build? · You answered: Flow")
        #expect(heading.instruction == "Pick one.")
        // The honey box shows round 2's own text. The first round's reason does not repeat (WAG-335).
        #expect(c.currentNeed(planRounds: nil) == "It sits after the sign-in screen.")
        #expect(c.currentWhy == nil)
        #expect(c.options.map(\.id) == ["c"])
        #expect(c.rowTitle == "Where does the intake go in the demo?")
        #expect(AskPanelLayout.parts(for: c, picked: nil) == [.crumb, .title, .need])
    }

    @Test func roundTwoStaysAfterYouAnswerIt() throws {
        let original = try detail("question-options").case
        var json = try JSONEncoder().encode(original)
        json = Data(String(decoding: json, as: UTF8.self)
            .replacingOccurrences(of: "\"needs_you\"", with: "\"waiting_on_agent\"").utf8)
        let answered = try JSONDecoder().decode(Case.self, from: json)
        #expect(answered.rowTitle == "Where does the intake go in the demo?")
        #expect(answered.roundHeading?.was == "Was: Investor demo: is this the flow to build?")
    }

    @Test func messageOnlyUpdateKeepsTheOpenQuestion() throws {
        let d = try detail("message-only")
        #expect(d.case.roundHeading == nil)
        #expect(d.case.rowTitle == "Investor demo: is this the flow to build?")
        #expect(d.case.currentNeed(planRounds: nil) == firstNeed)
        #expect(d.case.currentWhy == "It sets the demo scope.")
        // The update's message reaches the page as the update card and the agent bubble.
        #expect(d.messages.last?.text == "I fixed the copy.\n\nSee the note.")
        #expect(d.case.pendingUpdate?.message.hasPrefix("I fixed the copy.") == true)
    }

    @Test func newArtifactTabsShowTheLatestVersionOfEach() throws {
        let tabs = ArtifactTabs.tabs(revisions: try detail("artifacts").revisions)
        #expect(tabs.map(\.title) == ["Flow", "Spec"])
        #expect(tabs.map(\.revision) == [2, 3])
    }

    @Test func aNewVersionBringsItsTabToTheFront() throws {
        let revisions = try detail("artifacts").revisions
        let model = LiveArtifactModel(
            caseId: "c", client: KnockClient(socketPath: "/nonexistent"),
            tabs: ArtifactTabs.tabs(revisions: Array(revisions.prefix(1))))
        #expect(model.selectedTab?.revision == 1)
        model.update(tabs: ArtifactTabs.tabs(revisions: Array(revisions.prefix(3))))
        // Spec is new: it shows.
        #expect(model.selectedTab?.title == "Spec")
        model.select("name:flow")
        // A later version of Flow comes to the front even though Spec was the last tab.
        var next = revisions
        next.append(Revision(id: "r9", caseId: "c", n: 4, createdAt: "2026-10-07T10:00:00.000Z", name: "Flow", kind: .markdown))
        model.select("name:spec")
        model.update(tabs: ArtifactTabs.tabs(revisions: next))
        #expect(model.selectedTab?.title == "Flow")
        #expect(model.selectedTab?.revision == 4)
    }

    @Test func roundWithItsOwnArtifactLeadsWithTheRoundAndTheNewestRevision() throws {
        let d = try detail("round-artifact")
        #expect(d.case.roundHeading?.title == "Where does the intake go in the demo?")
        #expect(d.case.currentWhy == nil)
        #expect(d.revisions.map(\.n).max() == 2)
    }

    @Test func planRoundsShowTheNewestRoundText() throws {
        let d = try detail("plan-rounds")
        #expect(d.case.roundHeading == nil)
        let need = d.case.currentNeed(planRounds: d.planRounds)
        #expect(need.hasPrefix("Where does the intake go in the demo?"))
        #expect(!need.contains("25 screens"))
        #expect(d.case.currentWhy == nil)
        #expect(d.planRounds?.last?.revision == 2)
        #expect(AskPanelLayout.parts(for: d.case, picked: nil) == [.need])
    }

    @Test func doneNoteOpensNoRound() throws {
        let d = try detail("done")
        #expect(d.case.isDone)
        #expect(d.case.roundHeading == nil)
        #expect(d.case.doneMessage == "All shipped.")
    }

    @Test func notificationsNameTheNewestRound() throws {
        let d = try detail("question-options")
        let content = NotificationBuilder.content(
            for: d.case, task: d.task, environment: [:], bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier)
        #expect(content.title == "Claude needs your decision: Where does the intake go in the demo?")
        let update = NotificationBuilder.updateContent(
            for: d.case, environment: [:], bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier)
        if let update { #expect(update.title == "Updated: Where does the intake go in the demo?") }
    }
}
