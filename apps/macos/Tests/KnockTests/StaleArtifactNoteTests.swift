import Testing
import Foundation
@testable import Knock

/// HAIL-146: the stage header says when the newest update sent no new artifact.
struct StaleArtifactNoteTests {
    private func makeCase(
        hasArtifact: Bool = true, revisions: Int? = 1, revisionAt: String? = "2026-10-03T14:26:00.000Z",
        updateAt: String? = "2026-10-03T14:27:00.000Z", optionsAt: String? = nil
    ) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .review, title: "Which sentence?", need: "Pick one",
            why: "W", recommendation: "a", recommendationWhy: "RW",
            options: [Option(id: "a", label: "A")], status: .needsYou, hasArtifact: hasArtifact,
            updateCount: updateAt == nil ? 0 : 1, latestUpdateAt: updateAt, latestUpdateMessage: "m",
            revisionCount: revisions, latestRevisionAt: revisionAt, taskName: "T", project: "p",
            createdAt: "2026-10-03T14:00:00.000Z", updatedAt: "2026-10-03T14:27:00.000Z", optionsUpdatedAt: optionsAt)
    }

    @Test func messageAfterTheNewestRevisionIsStale() {
        let note = makeCase().staleArtifactNote
        #expect(note?.shownRevision == 1)
        #expect(note?.changeAt == KnockDateFormat.date(from: "2026-10-03T14:27:00.000Z"))
        #expect(note?.text.hasPrefix("Still showing v1 \u{00B7} not updated with the ") == true)
    }

    @Test func newOptionsAloneAreStale() {
        #expect(makeCase(updateAt: nil, optionsAt: "2026-10-03T14:30:00.000Z").staleArtifactNote != nil)
    }

    @Test func anUpdateWithItsOwnRevisionIsNotStale() {
        let same = "2026-10-03T14:27:00.000Z"
        #expect(makeCase(revisions: 2, revisionAt: same, updateAt: same, optionsAt: same).staleArtifactNote == nil)
    }

    @Test func namesTheLatestRevisionStillShown() {
        #expect(makeCase(revisions: 3).staleArtifactNote?.shownRevision == 3)
    }

    @Test func noArtifactOrNoUpdateIsNeverStale() {
        #expect(makeCase(hasArtifact: false, revisions: nil, revisionAt: nil).staleArtifactNote == nil)
        #expect(makeCase(updateAt: nil).staleArtifactNote == nil)
    }
}
