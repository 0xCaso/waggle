import Testing
import Foundation
@testable import Knock

// WAG-258 (waggle-releases issue 3): a host closed the agent's session. The pane and the queue say so
// before and after the human answers, one banner per reply, no Retry that does nothing.
struct SessionClosedTests {
    private let created = "2026-10-07T09:30:00.000Z"
    private let ended = "2026-10-07T10:10:00.000Z"
    private let before = "2026-10-07T10:05:00.000Z"
    private let after = "2026-10-07T10:14:37.000Z"

    private func makeCase(
        status: CaseStatus = .needsYou, session: SessionState? = .ended, replyState: ReplyStatus? = nil,
        replyAt: String? = nil, endedAt: String? = nil, doneAt: String? = nil
    ) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "Pick a layout",
            need: "Need", why: "Why", recommendation: "a",
            recommendationWhy: "Because", options: [Option(id: "a", label: "Compact")], status: status,
            hasArtifact: false, latestReplyId: replyState == nil ? nil : "reply_1", latestReplyState: replyState,
            latestReplyAt: replyAt, sessionState: session, doneAt: doneAt, sessionEndedAt: endedAt,
            createdAt: created, updatedAt: created
        )
    }

    // MARK: Before you answer (AC 1)

    @Test func anOpenAskOnAnEndedSessionGetsTheNoticeAndTheMark() {
        let item = makeCase()
        #expect(item.sessionClosedBeforeAnswer)
        #expect(item.showsSessionClosedMark)
        #expect(SessionClosedCopy.notice == "This agent's session has closed. Your answer is saved and reaches the agent when you next message it.")
        #expect(SessionClosedCopy.mark == "Session closed")
    }

    @Test func aLiveOrDisconnectedSessionShowsNeitherNoticeNorMark() {
        for state: SessionState? in [.live, .disconnected, nil] {
            let item = makeCase(session: state)
            #expect(!item.sessionClosedBeforeAnswer)
            #expect(!item.showsSessionClosedMark)
        }
    }

    @Test func aDoneOrResolvedCaseNeverShowsTheMark() {
        #expect(!makeCase(doneAt: created).showsSessionClosedMark)
        #expect(!makeCase(status: .resolved).showsSessionClosedMark)
    }

    // MARK: The queue mark for every held or failed reply (AC 5)

    @Test func everyCaseWithAFailedOrHeldReplyShowsTheSameMark() {
        let failedEnded = makeCase(status: .waitingOnAgent, replyState: .failed, replyAt: after, endedAt: ended)
        let failedLive = makeCase(status: .waitingOnAgent, session: .live, replyState: .failed, replyAt: after)
        let queuedEnded = makeCase(status: .waitingOnAgent, replyState: .queued, replyAt: before, endedAt: ended)
        let delivered = makeCase(status: .waitingOnAgent, replyState: .delivered, replyAt: before, endedAt: ended)
        let queuedLive = makeCase(status: .waitingOnAgent, session: .live, replyState: .queued, replyAt: before)
        #expect(failedEnded.showsSessionClosedMark)
        #expect(failedLive.showsSessionClosedMark)
        #expect(queuedEnded.showsSessionClosedMark)
        #expect(!delivered.showsSessionClosedMark)
        #expect(!queuedLive.showsSessionClosedMark)
    }

    // MARK: After you answer (AC 2)

    @Test func theStripSaysWhichCameFirst() {
        let closedFirst = makeCase(status: .waitingOnAgent, replyState: .failed, replyAt: after, endedAt: ended)
        let repliedFirst = makeCase(status: .waitingOnAgent, replyState: .queued, replyAt: before, endedAt: ended)
        let read = makeCase(status: .waitingOnAgent, replyState: .delivered, replyAt: before, endedAt: ended)
        #expect(closedFirst.closedBeforeReply)
        #expect(!repliedFirst.closedBeforeReply)
        #expect(SessionClosedCopy.stripHeadline(for: closedFirst) == "The session closed before you replied")
        #expect(SessionClosedCopy.stripHeadline(for: repliedFirst) == "The session closed before it read your reply")
        #expect(SessionClosedCopy.stripHeadline(for: read) == "The session closed after it read your reply")
        #expect(AgentStatusCopy.headline(status: .closed, runtime: "Claude Code", item: closedFirst) == "The session closed before you replied")
        #expect(AgentStatusCopy.headline(status: .working, runtime: "Claude Code", item: closedFirst) == "Claude Code is working on your reply")
    }

    @Test func withoutAnEndTimeTheOlderCopyApplies() {
        let item = makeCase(status: .waitingOnAgent, replyState: .failed, replyAt: after)
        #expect(!item.closedBeforeReply)
    }

    @Test func theBannerCopiesTheStandaloneAnswer() {
        let item = makeCase(status: .waitingOnAgent, replyState: .failed, replyAt: after, endedAt: ended)
        let line = DeliveryOutcomeBanner.copyLine(for: item)
        #expect(line == ClaudeCheck.standaloneAnswer(for: item))
        #expect(line?.hasPrefix("My Waggle answer to \"Pick a layout\" (case c_1):") == true)
        #expect(SessionClosedCopy.savedNote == "Your answer is saved. It reaches the agent when you next message it, or paste the copied answer in the agent's chat.")
    }

    @Test func theSavedStateReplacesDeliveryFailed() {
        #expect(SessionClosedCopy.savedTitle == "Saved · delivers when the agent's session resumes")
        #expect(DeliveryOutcomeBanner.copyLine(for: makeCase(status: .waitingOnAgent, replyState: .failed, replyAt: after, endedAt: ended)) != nil)
        // No Retry while the session is ended; a live session keeps it.
        #expect(DeliveryOutcomeBanner.copyLine(for: makeCase(status: .waitingOnAgent, session: .live, replyState: .failed, replyAt: after)) == nil)
        for text in [SessionClosedCopy.notice, SessionClosedCopy.mark, SessionClosedCopy.savedTitle, SessionClosedCopy.savedNote] {
            #expect(!text.contains("\u{2014}"))
        }
    }

    // MARK: One banner per reply (AC 3)

    @Test func aFailedOutcomeHasOneOwnerAndADeliveredOutcomeHasOne() {
        #expect(DeliveryBannerSlot.slot(for: .failed(replyId: "reply_1")) == .paneTop)
        #expect(DeliveryBannerSlot.slot(for: .delivered(at: Date())) == .footer)
        for state: DeliveryState? in [nil, .idle, .sending, .sent, .offline] {
            #expect(DeliveryBannerSlot.slot(for: state) == nil)
        }
    }

    // MARK: The wire

    @Test func theCaseDecodesWhenTheSessionEnded() throws {
        let json = """
        {"id":"c_1","task_id":"t_1","kind":"question","title":"T","need":"N","why":"W","recommendation":"a",
         "recommendation_why":"R","options":[],"status":"needs_you","has_artifact":false,"session_state":"ended",
         "session_ended_at":"\(ended)","created_at":"\(created)","updated_at":"\(created)"}
        """
        let item = try JSONDecoder().decode(Case.self, from: Data(json.utf8))
        #expect(item.sessionEndedAt == ended)
        #expect(item.sessionClosedBeforeAnswer)
    }
}
