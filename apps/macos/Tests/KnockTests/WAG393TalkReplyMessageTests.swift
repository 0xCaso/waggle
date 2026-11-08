import Foundation
import Testing
@testable import Knock

/// WAG-393: a message-only update after a talk reply (discuss or more detail) keeps the round's options
/// live, and the page shows the agent's full message, not the cut preview.
struct WAG393TalkReplyMessageTests {
    private let full = String(repeating: "A long answer about the trade-offs. ", count: 52)

    private func make(intent: ReplyIntent, message: String? = nil) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Which way?", need: "N", why: "W",
            recommendation: "a", recommendationWhy: "RW",
            options: [Option(id: "a", label: "Option A"), Option(id: "b", label: "Option B")],
            status: .needsYou, hasArtifact: false,
            latestReplyId: "r1", latestReplyAt: "2026-10-18T10:34:06.000Z", latestReplyMessage: "Why A?",
            latestReplyIntent: intent,
            updateCount: 1, latestUpdateAt: "2026-10-18T10:34:26.000Z",
            latestUpdateMessage: message ?? String(full.prefix(400)),
            revisionCount: 1, latestRevisionAt: "2026-10-18T10:00:00.000Z", doneAt: nil,
            createdAt: "2026-10-18T10:00:00.000Z", updatedAt: "2026-10-18T10:34:26.000Z",
            optionsUpdatedAt: "2026-10-18T10:00:00.000Z")
    }

    private func messages(_ text: String) -> [Message] {
        let json = """
        [{"id":"m1","case_id":"c1","role":"agent","text":"Which way?","created_at":"2026-10-18T10:00:00.000Z"},
         {"id":"m2","case_id":"c1","role":"agent","text":\(String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)),"created_at":"2026-10-18T10:34:26.000Z"}]
        """
        return try! JSONDecoder().decode([Message].self, from: Data(json.utf8))
    }

    @Test func aDiscussReplyKeepsTheOptionsLiveWithTheFullMessage() throws {
        let item = make(intent: .discuss)
        #expect(!item.earlierRoundIsReadOnly)
        #expect(AskBarMode.forCase(item) == .decide)
        let note = try #require(item.messageOnlyUpdate)
        #expect(note.staysLive)
        let replyAt = item.latestReplyAtDate
        let shown = note.fullText(from: messages(full), after: replyAt)
        #expect(shown.message == full.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(shown.message.count > 400)
        #expect(shown.staysLive)
    }

    @Test func aMoreDetailReplyAlsoKeepsTheOptionsLive() {
        #expect(!make(intent: .moreDetail).earlierRoundIsReadOnly)
    }

    @Test func aDecisionReplyStillFoldsTheRound() throws {
        let item = make(intent: .decision)
        #expect(item.earlierRoundIsReadOnly)
        #expect(try #require(item.messageOnlyUpdate).staysLive == false)
    }

    @Test func aDecisionReplyWithAQuestionKeepsOptionsLive() {
        #expect(!make(intent: .decision, message: "Fine.\nShould I go on?").earlierRoundIsReadOnly)
    }

    @Test func withoutALaterAgentMessageThePreviewStays() throws {
        let note = try #require(make(intent: .discuss).messageOnlyUpdate)
        let old = Array(messages(full).prefix(1))
        #expect(note.fullText(from: old, after: make(intent: .discuss).latestReplyAtDate) == note)
    }
}
