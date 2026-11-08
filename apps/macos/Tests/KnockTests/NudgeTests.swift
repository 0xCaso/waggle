import Testing
import Foundation
@testable import Knock

// HAIL-76 / HAIL-129: the nudge, always on for a session that can be nudged.
struct NudgeTests {
    private let sent = "2026-09-30T10:00:00.000Z"

    private func makeCase(replyState: ReplyStatus? = .queued, sessionState: SessionState? = .live) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "Title",
            need: "Need", why: "Why", recommendation: "a",
            recommendationWhy: "Because", options: [], status: .waitingOnAgent,
            hasArtifact: false, latestReplyId: "r_1", latestReplyState: replyState, latestReplyAt: sent,
            sessionState: sessionState,
            createdAt: "2026-09-30T09:00:00.000Z", updatedAt: sent
        )
    }

    private func at(_ seconds: TimeInterval) -> Date {
        KnockDateFormat.date(from: sent)!.addingTimeInterval(seconds)
    }

    private func phase(
        canNudge: Bool = true, record: NudgeRecord? = nil, now: TimeInterval = 120,
        item: Case? = nil
    ) -> Nudge.Phase {
        let item = item ?? makeCase()
        return Nudge.phase(
            mode: PickupFallback.mode(for: item, now: at(now)), canNudge: canNudge,
            record: record, now: at(now))
    }

    @Test func showsFromTwoMinutesWhenTheSessionCanBeNudged() {
        #expect(phase(now: 119) == .off)
        #expect(phase(now: 120) == .ready)
        #expect(phase(canNudge: false) == .off)
    }

    @Test func noNudgeForAPickedUpOrClosedReply() {
        #expect(phase(item: makeCase(replyState: .delivered)) == .off)
        #expect(phase(item: makeCase(sessionState: .ended)) == .off)
        #expect(phase(item: makeCase(sessionState: .disconnected)) == .off)
    }

    // The states.
    @Test func sentThenStillAsleepAfterSixtySeconds() {
        let record = NudgeRecord(count: 1, lastAt: at(130))
        #expect(phase(record: record, now: 130) == .sent)
        #expect(phase(record: record, now: 189) == .sent)
        #expect(phase(record: record, now: 190) == .stillAsleep)
    }

    @Test func aCallInFlightReadsAsSent() {
        #expect(phase(record: NudgeRecord(sending: true)) == .sent)
    }

    @Test func nudgeAgainIsOfferedAfterEachMinute() {
        let record = NudgeRecord(count: 5, lastAt: at(130))
        #expect(phase(record: record, now: 200) == .stillAsleep)
        #expect(phase(record: NudgeRecord(count: 5, lastAt: at(200)), now: 210) == .sent)
    }

    @Test func nudgedLabelCountsSecondsThenMinutes() {
        #expect(Nudge.nudgedLabel(since: at(130), now: at(142)) == "Nudged · 12s")
        #expect(Nudge.nudgedLabel(since: at(130), now: at(130)) == "Nudged · 0s")
        #expect(Nudge.nudgedLabel(since: at(130), now: at(195)) == "Nudged · 1m 5s")
        #expect(Nudge.nudgedLabel(since: nil, now: at(130)) == "Nudging…")
    }

    @Test func aNudgeDoesNotMoveTheWaitingTimer() {
        // The timer start is the reply's send time, whatever the nudge record says.
        let item = makeCase()
        #expect(AgentStatus.timerStart(item, status: .waitingForPickup, deliveryStatus: nil) == item.latestReplyAtDate)
    }

    @Test func aSessionThatCannotBeNudgedFallsBackToTheFallback() {
        #expect(phase(record: NudgeRecord(failure: .notSupported)) == .off)
        #expect(phase(record: NudgeRecord(failure: .sessionClosed)) == .off)
        // A failed post hands over to Copy prompt too.
        #expect(phase(record: NudgeRecord(failure: .postFailed)) == .off)
    }

    // The record.
    @Test func recordCountsSentNudgesAndKeepsTheFailure() {
        var record = NudgeRecord(sending: true)
        record = record.applying(NudgeResult(sent: true), at: at(130))
        #expect(record.count == 1)
        #expect(record.lastAt == at(130))
        #expect(record.sending == false)
        #expect(record.failure == nil)
        record = record.applying(NudgeResult(sent: false, reason: .postFailed), at: at(200))
        #expect(record.count == 1)
        #expect(record.failure == .postFailed)
        // A rate limit from the daemon means a nudge went out in the last minute.
        record = NudgeRecord().applying(NudgeResult(sent: false, reason: .rateLimited), at: at(210))
        #expect(record.count == 1)
        #expect(record.lastAt == at(210))
        #expect(record.failure == nil)
    }

    @Test func deliveredAfterANudgeSaysItWokeUp() {
        let delivered = makeCase(replyState: .delivered)
        #expect(Nudge.wokeUp(item: delivered, record: NudgeRecord(count: 1, lastAt: at(130))))
        #expect(!Nudge.wokeUp(item: delivered, record: nil))
        #expect(!Nudge.wokeUp(item: makeCase(), record: NudgeRecord(count: 1)))
    }

    // Copy.
    @Test func copyMatchesThePrototype() {
        #expect(Nudge.readyHelp == "It may have finished its turn. A nudge asks it to check Waggle for your reply.")
        #expect(Nudge.sentHelp == "If it is in the middle of a long step, it sees the nudge when that step ends.")
        #expect(Nudge.deliveredLine == "Delivered · it woke up and has your answer")
        #expect(Nudge.nudgeLabel(runtime: "Claude Code") == "Nudge Claude Code")
        #expect(Nudge.nudgeAgainLabel == "Nudge again")
        let copy = [
            Nudge.readyHelp, Nudge.sentHelp, Nudge.asleepHelp, Nudge.deliveredLine,
            Nudge.failureLine(.postFailed), Nudge.failureLine(.notSupported),
            Nudge.failureLine(.sessionClosed),
        ].compactMap { $0 }
        #expect(copy.allSatisfy { !$0.contains("\u{2014}") })
        #expect(Nudge.failureLine(.alreadyPickedUp) == nil)
    }

    @Test func readLineSaysWokeUpAfterANudge() {
        let date = KnockDateFormat.date(from: sent)!
        let utc = TimeZone(identifier: "UTC")!
        #expect(AgentStatusCopy.readLine(readAt: date, timeZone: utc) == "read at 10:00")
        #expect(AgentStatusCopy.readLine(readAt: date, afterNudge: true, timeZone: utc)
            == "woke up after the nudge · read at 10:00")
    }

    // The wire.
    @Test func decodesCanNudgeAndDefaultsToFalse() throws {
        func session(_ extra: String) throws -> SessionInfo {
            let json = """
            {"id":"s","task_id":"t","runtime":"claude","task_name":"n","project":"p","branch":null,
             "cwd":"/x","pid":1,\(extra)"state":"live","connected_at":"\(sent)","last_seen_at":"\(sent)"}
            """
            return try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
        }
        #expect(try session("\"can_nudge\":true,").canNudge == true)
        #expect(try session("\"can_nudge\":false,").canNudge == false)
        #expect(try session("").canNudge == false)
    }

    @Test func decodesTheNudgeResultAndEvent() throws {
        let ok = try JSONDecoder().decode(NudgeResult.self, from: Data(#"{"sent":true}"#.utf8))
        #expect(ok == NudgeResult(sent: true))
        let no = try JSONDecoder().decode(
            NudgeResult.self, from: Data(#"{"sent":false,"reason":"already_picked_up"}"#.utf8))
        #expect(no == NudgeResult(sent: false, reason: .alreadyPickedUp))
        for reason in ["session_closed", "not_supported", "already_picked_up", "rate_limited", "post_failed"] {
            let r = try JSONDecoder().decode(
                NudgeResult.self, from: Data(#"{"sent":false,"reason":"\#(reason)"}"#.utf8))
            #expect(r.reason?.rawValue == reason)
        }
        let event = try JSONDecoder().decode(
            Event.self, from: Data(#"{"type":"session.nudged","case_id":"c_1","at":"\#(sent)"}"#.utf8))
        #expect(event.type == .sessionNudged)
        #expect(event.caseId == "c_1")
    }

    @Test func encodesTheNudgeParams() throws {
        let data = try JSONEncoder().encode(NudgeParams(caseId: "c_9"))
        #expect(String(decoding: data, as: UTF8.self) == #"{"case_id":"c_9"}"#)
    }

    // The context wires the setting, the session and the record into one phase.
    @Test func contextGatesOnTheSessionTask() {
        var context = NudgeContext(canNudgeByTaskId: ["t_1": true])
        #expect(context.phase(for: makeCase(), mode: .live, now: at(120)) == .ready)
        context.canNudgeByTaskId = ["t_1": false]
        #expect(context.phase(for: makeCase(), mode: .live, now: at(120)) == .off)
        context.canNudgeByTaskId = [:]
        #expect(context.phase(for: makeCase(), mode: .live, now: at(120)) == .off)
        #expect(NudgeContext().phase(for: makeCase(), mode: .live, now: at(120)) == .off)
    }

    /// HAIL-134: a Claude Code mod's "open" button reaches the app as an event.
    @Test func caseOpenRequestedDecodesAndCarriesTheCase() throws {
        let sent = "2026-10-02T10:00:00.000Z"
        let event = try JSONDecoder().decode(
            Event.self, from: Data(#"{"type":"case.open_requested","case_id":"c_9","at":"\#(sent)"}"#.utf8))
        #expect(event.type == .caseOpenRequested)
        #expect(event.caseId == "c_9")
    }
}
