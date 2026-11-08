import Foundation
import Testing
@testable import Knock

/// The one line under the answer (WAG-267): "Sent", "The agent got it", "Applied", or the not-applied line.
struct ReplyApplyCopyTests {
    private func ask(_ state: ReplyStatus?, apply: ReplyApplyState? = nil, session: SessionState? = .live) -> Case {
        Case(
            id: "a", taskId: "t", kind: .question, title: "T", need: "N", why: "W", recommendation: "a",
            recommendationWhy: "RW", options: [Option(id: "a", label: "Keep it all", title: "Keep")],
            status: .waitingOnAgent, hasArtifact: false, latestReplyState: state,
            latestReplyAt: "2026-10-07T10:00:00Z", latestReplyChoice: "a",
            latestReplyApplyState: apply, sessionState: session,
            createdAt: "2026-10-07T09:00:00Z", updatedAt: "2026-10-07T10:00:00Z")
    }

    @Test func eachStateHasItsOwnLine() {
        #expect(ReplyApplyCopy.line(for: ask(.queued))?.text == "Sent")
        #expect(ReplyApplyCopy.line(for: ask(.delivered, apply: .pending))?.text == "The agent got it")
        #expect(ReplyApplyCopy.line(for: ask(.delivered, apply: .applied))?.text == "Applied")
        #expect(ReplyApplyCopy.line(for: ask(.delivered, apply: .notApplied))?.text
            == "The agent got your answer but has not acted on it yet.")
    }

    @Test func aDeliveredReplyFromAnOlderDaemonReadsAsGotIt() {
        #expect(ReplyApplyCopy.line(for: ask(.delivered))?.text == "The agent got it")
    }

    @Test func theAppsOwnDeliveredStateBeatsAStaleQueuedRow() {
        let line = ReplyApplyCopy.line(for: ask(.queued), delivery: .delivered(at: Date()))
        #expect(line?.text == "The agent got it")
    }

    @Test func failedSupersededAndNoReplyShowNoLine() {
        #expect(ReplyApplyCopy.line(for: ask(.failed)) == nil)
        #expect(ReplyApplyCopy.line(for: ask(.superseded)) == nil)
        #expect(ReplyApplyCopy.line(for: ask(nil)) == nil)
    }

    @Test func noLineHasAnEmDash() {
        for line in [ReplyApplyCopy.sent, ReplyApplyCopy.gotIt, ReplyApplyCopy.applied, ReplyApplyCopy.notApplied] {
            #expect(!line.contains("—"))
        }
    }

    @Test func notAppliedOffersTheExistingPickupActions() {
        let now = Date()
        #expect(PickupFallback.mode(for: ask(.delivered, apply: .notApplied), now: now) == .live)
        #expect(PickupFallback.mode(for: ask(.delivered, apply: .notApplied, session: .ended), now: now) == .closed)
        #expect(PickupFallback.mode(for: ask(.delivered, apply: .applied), now: now) == .none)
        #expect(PickupFallback.mode(for: ask(.delivered, apply: .pending), now: now) == .none)
    }

    @Test func decodesTheNewFieldsAndToleratesAnUnknownValue() throws {
        let json = #"""
        {"id":"r1","case_id":"c1","idempotency_key":"k","comments":[],"captures":[],"state":"delivered",
         "created_at":"2026-10-07T10:00:00.000Z","apply_state":"not_applied"}
        """#
        let reply = try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
        #expect(reply.applyState == .notApplied)
        let future = json.replacingOccurrences(of: "not_applied", with: "something_new")
        #expect(try JSONDecoder().decode(Reply.self, from: Data(future.utf8)).applyState == nil)
        let old = json.replacingOccurrences(of: #","apply_state":"not_applied""#, with: "")
        #expect(try JSONDecoder().decode(Reply.self, from: Data(old.utf8)).applyState == nil)
    }
}
