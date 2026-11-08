import Foundation
import Testing
@testable import Knock

/// The "You picked" card (HAIL-86): its copy and when the one page shows it.
struct SentAnswerCardTests {
    private func ask(choice: String? = nil, message: String? = nil, intent: ReplyIntent? = nil) -> Case {
        Case(
            id: "a", taskId: "t", kind: .question, title: "T", need: "N", why: "W", recommendation: "b",
            recommendationWhy: "RW",
            options: [Option(id: "a", label: "Keep it all", title: "Keep"), Option(id: "b", label: "Compact rows", title: "Compact")],
            status: .waitingOnAgent, hasArtifact: true, latestReplyState: .queued,
            latestReplyAt: "2026-09-29T13:02:00Z", latestReplyChoice: choice, latestReplyMessage: message,
            latestReplyIntent: intent, createdAt: "2026-09-29T11:00:00Z", updatedAt: "2026-09-29T13:02:00Z")
    }

    @Test func aChoiceReadsNumberAndTitleWithTheNote() {
        let answer = SentAnswerCopy.answer(for: ask(choice: "b", message: "But keep the header"))
        #expect(answer == .init(label: "YOU PICKED", title: "2 · Compact", note: "But keep the header"))
    }

    @Test func aMessageOnlyReplyShowsTheReplyText() {
        let answer = SentAnswerCopy.answer(for: ask(message: "Neither, try a table"))
        #expect(answer == .init(label: "YOU REPLIED", title: "Neither, try a table", note: nil))
    }

    @Test func aMoreDetailAskIsNotCalledAPick() {
        let answer = SentAnswerCopy.answer(for: ask(message: "Which one is faster?", intent: .moreDetail))
        #expect(answer == .init(label: "YOU ASKED", title: "Which one is faster?", note: nil))
    }

    @Test func aMoreDetailAskWithoutAMessageReadsMoreDetail() {
        let answer = SentAnswerCopy.answer(for: ask(intent: .moreDetail))
        #expect(answer == .init(label: "YOU ASKED", title: "More detail", note: nil))
    }

    @Test func sentLineShowsTheClock() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(SentAnswerCopy.sentLine(sentAt: Date(timeIntervalSince1970: 1_790_000_000), timeZone: utc) == "sent 14:13")
        #expect(SentAnswerCopy.sentLine(sentAt: nil) == nil)
    }

    @Test func theOnePageKeepsTheQuestionOnceSentButTheFullReviewKeepsTheRecap() {
        func kind(_ lock: ReplyLockState, onePage: Bool, editing: Bool = false) -> ReviewWorkspaceView.RightColumnKind {
            ReviewWorkspaceView.rightColumnKind(
                lockState: lock, isEditingLockedAnswer: editing, isReviewingBeforeSend: false, tab: .question,
                isOnePage: onePage)
        }
        for lock in [ReplyLockState.queued, .delivered, .failed] {
            #expect(kind(lock, onePage: true) == .askWithStatus)
            #expect(kind(lock, onePage: false) == .answeredRecap)
        }
        #expect(kind(.queued, onePage: true, editing: true) == .interact)
        #expect(kind(.editable, onePage: true) == .interact)
    }
}
