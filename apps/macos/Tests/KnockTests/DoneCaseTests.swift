import Foundation
import Testing
@testable import Knock

/// HAIL-152: a done update closes a case. The row says "Done", never offers pick-up or Nudge,
/// stays until Got it, and an old daemon's payload (no done_at) still decodes.
struct DoneCaseTests {
    private static let now = KnockDateFormat.date(from: "2026-10-03T17:10:00Z")!

    private func make(
        done: Bool, replyState: ReplyStatus? = .queued, session: SessionState? = .live,
        status: CaseStatus = .waitingOnAgent, message: String? = "Done and live.\nEvery cell is honey now."
    ) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Ship the rebrand?", need: "N", why: "W",
            recommendation: "R", recommendationWhy: "RW", options: [], status: status, hasArtifact: false,
            latestReplyId: replyState == nil ? nil : "r1", latestReplyState: replyState,
            latestReplyAt: replyState == nil ? nil : "2026-10-03T16:50:00.000Z",
            latestUpdateMessage: message, sessionState: session,
            doneAt: done ? "2026-10-03T17:05:00.000Z" : nil,
            createdAt: "2026-10-03T16:00:00.000Z", updatedAt: "2026-10-03T17:05:00.000Z"
        )
    }

    @Test func aDoneCaseStaysInViewWhateverItsReplyState() {
        for state in [ReplyStatus.queued, .delivered, .failed] {
            let item = make(done: true, replyState: state)
            #expect(AnswerGrouping.staysWaiting(item, isFollowedUp: true, now: Self.now))
        }
        // The same case without done keeps the old rule: an answered, followed-up ask moves on.
        let normal = make(done: false, replyState: .delivered)
        #expect(!AnswerGrouping.staysWaiting(normal, isFollowedUp: true, now: Self.now))
    }

    @Test func aDoneCaseNeverShowsPickUpNudgeOrANotPickedUpNotice() {
        let done = make(done: true, replyState: .queued, session: .ended)
        #expect(!done.isStaleQueuedReply)
        #expect(PickupFallback.mode(for: done, now: Self.now) == .none)
        #expect(AgentStatus.forCase(done) != .waitingForPickup)
        // Without the flag the same case still offers all of it.
        let real = make(done: false, replyState: .queued, session: .live)
        #expect(PickupFallback.mode(for: real, now: Self.now) == .live)
        #expect(AgentStatus.forCase(real) == .waitingForPickup)
        #expect(make(done: false, replyState: .queued, session: .ended).isStaleQueuedReply)
    }

    @Test func aDoneCaseIsReadOnlyAndHasNoReplyToChange() {
        let done = make(done: true, replyState: nil)
        #expect(done.isAnswerLocked)
        #expect(done.replyLockState == .delivered)
        #expect(make(done: true, replyState: .queued).replyLockState == .delivered)
        #expect(make(done: false, replyState: .queued).replyLockState == .queued)
    }

    @Test func theRowLineIsTheMessageOnOneLine() {
        #expect(make(done: true).doneMessage == "Done and live. Every cell is honey now.")
        #expect(make(done: true, message: nil).doneMessage == "")
        #expect(make(done: true).doneAtDate != nil)
    }

    @Test func aDoneCaseDoesNotCountAsAnActiveAskForItsSession() {
        let done = make(done: true, replyState: .delivered)
        #expect(AgentStatus.forCase(done) == .closed)
    }

    @Test func caseDecodesWithAndWithoutDoneAt() throws {
        let base = ##"{"id":"c1","task_id":"t1","kind":"question","title":"T","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"waiting_on_agent","has_artifact":false,"runtime":"claude","created_at":"2026-10-03T16:00:00.000Z","updated_at":"2026-10-03T17:05:00.000Z""##
        let old = try JSONDecoder().decode(Case.self, from: Data((base + "}").utf8))
        #expect(old.doneAt == nil)
        #expect(!old.isDone)
        let new = try JSONDecoder().decode(Case.self, from: Data((base + #","done_at":"2026-10-03T17:05:00.000Z"}"#).utf8))
        #expect(new.isDone)
        #expect(new.status == .waitingOnAgent)
    }
}
