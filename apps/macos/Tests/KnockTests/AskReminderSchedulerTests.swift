import Testing
import Foundation
@testable import Knock

/// `AskReminderScheduler.reconcile` (Contract: "off by default; on posts one
/// more notification after 15 minutes if the ask is still waiting for you,
/// only once per ask; cancelled when answered or dismissed"). Every case
/// drives the pure function directly with an explicit `now`, no real clock.
struct AskReminderSchedulerTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func disabledSchedulesNothing() {
        let outcome = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: [:], reminded: [], enabled: false, now: start
        )
        #expect(outcome.pending.isEmpty)
        #expect(outcome.due.isEmpty)
    }

    @Test func enabledSchedulesFifteenMinutesOut() {
        let outcome = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: [:], reminded: [], enabled: true, now: start
        )
        #expect(outcome.pending["c1"] == start.addingTimeInterval(15 * 60))
        #expect(outcome.due.isEmpty)
    }

    @Test func firesOnceTheMarkHasPassed() {
        let scheduled = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: [:], reminded: [], enabled: true, now: start
        )
        let later = start.addingTimeInterval(15 * 60 + 1)
        let outcome = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: scheduled.pending, reminded: scheduled.reminded,
            enabled: true, now: later
        )
        #expect(outcome.due == ["c1"])
        #expect(outcome.pending["c1"] == nil)
        #expect(outcome.reminded.contains("c1"))
    }

    @Test func doesNotFireBeforeTheMark() {
        let scheduled = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: [:], reminded: [], enabled: true, now: start
        )
        let stillEarly = start.addingTimeInterval(14 * 60)
        let outcome = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: scheduled.pending, reminded: scheduled.reminded,
            enabled: true, now: stillEarly
        )
        #expect(outcome.due.isEmpty)
        #expect(outcome.pending["c1"] != nil)
    }

    @Test func onlyFiresOncePerAsk() {
        var pending: [String: Date] = [:]
        var reminded: Set<String> = []
        let scheduled = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: pending, reminded: reminded, enabled: true, now: start
        )
        pending = scheduled.pending
        reminded = scheduled.reminded

        let fired = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: pending, reminded: reminded,
            enabled: true, now: start.addingTimeInterval(16 * 60)
        )
        pending = fired.pending
        reminded = fired.reminded
        #expect(fired.due == ["c1"])

        // The case is still needs_you an hour later: no second reminder.
        let again = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: pending, reminded: reminded,
            enabled: true, now: start.addingTimeInterval(76 * 60)
        )
        #expect(again.due.isEmpty)
        #expect(again.pending["c1"] == nil)
    }

    @Test func cancelledWhenTheCaseLeavesNeedsYouBeforeTheMark() {
        let scheduled = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: [:], reminded: [], enabled: true, now: start
        )
        // Answered or dismissed: c1 drops out of needs_you before 15 minutes.
        let outcome = AskReminderScheduler.reconcile(
            needsYouCaseIds: [], pending: scheduled.pending, reminded: scheduled.reminded,
            enabled: true, now: start.addingTimeInterval(20 * 60)
        )
        #expect(outcome.pending.isEmpty)
        #expect(outcome.due.isEmpty)
        #expect(outcome.reminded.isEmpty)
    }

    @Test func aFreshAskOnTheSameCaseCanRemindAgain() {
        let scheduled = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: [:], reminded: [], enabled: true, now: start
        )
        let fired = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: scheduled.pending, reminded: scheduled.reminded,
            enabled: true, now: start.addingTimeInterval(16 * 60)
        )
        #expect(fired.due == ["c1"])

        // c1 leaves needs_you (answered), then returns later as a new ask.
        let left = AskReminderScheduler.reconcile(
            needsYouCaseIds: [], pending: fired.pending, reminded: fired.reminded,
            enabled: true, now: start.addingTimeInterval(20 * 60)
        )
        #expect(left.reminded.isEmpty)

        let backAgain = AskReminderScheduler.reconcile(
            needsYouCaseIds: ["c1"], pending: left.pending, reminded: left.reminded,
            enabled: true, now: start.addingTimeInterval(21 * 60)
        )
        #expect(backAgain.pending["c1"] == start.addingTimeInterval(21 * 60 + 15 * 60))
    }
}
