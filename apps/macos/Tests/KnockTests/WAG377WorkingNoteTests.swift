import Foundation
import Testing
@testable import Knock

/// WAG-377: a progress note (waggle_update working: true) shows a "Working on it" line, folds the options and
/// leaves the free reply open.
struct WAG377WorkingNoteTests {
    private func make(
        note: String? = "I am drawing a second version now.", status: CaseStatus = .waitingOnAgent, doneAt: String? = nil,
        replied: Bool = true
    ) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Which version?", need: "N", why: "W",
            recommendation: "a", recommendationWhy: "RW",
            options: [Option(id: "a", label: "Version one"), Option(id: "b", label: "Version two")],
            status: status, hasArtifact: true,
            latestReplyId: replied ? "r1" : nil, latestReplyState: replied ? .delivered : nil,
            latestReplyAt: replied ? "2026-10-16T10:00:00.000Z" : nil,
            revisionCount: 1, latestRevisionAt: "2026-10-16T09:00:00.000Z", doneAt: doneAt, workingNote: note,
            createdAt: "2026-10-16T09:00:00.000Z", updatedAt: "2026-10-16T10:05:00.000Z")
    }

    @Test func theNoteShowsOnTheAgentSide() {
        #expect(make().workingNoteText == "I am drawing a second version now.")
        #expect(WorkingNoteCopy.title == "Working on it")
    }

    @Test func noNoteWhenTheCaseNeedsYouIsDoneOrTheNoteIsEmpty() {
        #expect(make(status: .needsYou).workingNoteText == nil)
        #expect(make(doneAt: "2026-10-16T10:05:00.000Z").workingNoteText == nil)
        #expect(make(note: "  \n").workingNoteText == nil)
        #expect(make(note: nil).workingNoteText == nil)
    }

    @Test func theOptionsFoldAndOnlyTheFreeReplyStays() {
        let item = make()
        #expect(item.earlierRoundIsReadOnly)
        #expect(AskBarMode.forCase(item) == .reply)
        #expect(item.options.count == 2) // folded, not deleted
        #expect(!item.isAnswerLocked)
        #expect(item.replyLockState == .editable)
    }

    @Test func theNextRealRoundRestoresTheOptions() {
        let item = make(note: nil, status: .needsYou)
        #expect(!item.earlierRoundIsReadOnly)
        #expect(AskBarMode.forCase(item) == .decide)
    }

    @Test func anAnsweredCaseWithoutANoteStaysLocked() {
        let item = make(note: nil)
        #expect(item.isAnswerLocked)
    }
}
