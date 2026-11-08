import Foundation
import Testing
@testable import Knock

/// WAG-337: a message-only update heads the page, the earlier round folds, the row shows the first line.
struct WAG337MessageOnlyUpdateTests {
    private func make(
        message: String? = "OK, I will design in Pen first.\nThen I build it.", optionsAt: String? = nil,
        revisions: Int? = 1, status: CaseStatus = .needsYou, doneAt: String? = nil
    ) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Approve the spec?", need: "N", why: "W",
            recommendation: "a", recommendationWhy: "RW",
            options: [Option(id: "a", label: "Approve and build"), Option(id: "b", label: "Change it")],
            status: status, hasArtifact: false,
            latestReplyId: "r1", latestReplyAt: "2026-10-09T12:40:00.000Z", latestReplyMessage: "Design first",
            updateCount: 1, latestUpdateAt: "2026-10-09T12:50:00.000Z", latestUpdateMessage: message,
            revisionCount: revisions, latestRevisionAt: revisions == 2 ? "2026-10-09T12:50:00.000Z" : "2026-10-09T12:00:00.000Z", doneAt: doneAt,
            createdAt: "2026-10-09T12:00:00.000Z", updatedAt: "2026-10-09T12:50:00.000Z",
            optionsUpdatedAt: optionsAt)
    }

    @Test func aMessageOnlyUpdateAfterAReplyHeadsThePage() {
        let note = make().messageOnlyUpdate
        #expect(note?.message == "OK, I will design in Pen first.\nThen I build it.")
        #expect(note?.waitsForAnswer == false)
    }

    @Test func theEarlierRoundIsReadOnlyAndOnlyTheReplyFieldStays() {
        let item = make()
        #expect(item.earlierRoundIsReadOnly)
        #expect(AskBarMode.forCase(item) == .reply)
    }

    @Test func aMessageThatAsksKeepsTheOptionsLive() {
        let item = make(message: "I can start now.\nShould I use the old colours?")
        #expect(item.messageOnlyUpdate?.waitsForAnswer == true)
        #expect(!item.earlierRoundIsReadOnly)
        #expect(AskBarMode.forCase(item) == .decide)
    }

    @Test func newOptionsADoneNoteOrARevisionAreNotMessageOnly() {
        #expect(make(optionsAt: "2026-10-09T12:50:00.000Z").messageOnlyUpdate == nil)
        #expect(make(revisions: 2).messageOnlyUpdate == nil)
        #expect(make(doneAt: "2026-10-09T12:50:00.000Z").messageOnlyUpdate == nil)
        #expect(make(status: .waitingOnAgent).messageOnlyUpdate == nil)
    }

    @Test func theRowAndTheNotificationUseTheFirstLine() {
        let item = make()
        #expect(item.pendingUpdate?.firstLine == "OK, I will design in Pen first.")
        let content = NotificationBuilder.updateContent(for: item)
        #expect(content?.body == "OK, I will design in Pen first.")
    }
}
