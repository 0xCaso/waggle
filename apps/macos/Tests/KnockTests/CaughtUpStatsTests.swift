import Foundation
import Testing
@testable import Knock

/// `CaughtUpStats.compute` (Contract "All caught up"): "answered today"'s
/// today boundary, and the median time-to-decide's odd/even cases and its
/// "no data" fallback.
struct CaughtUpStatsTests {
    private func waitingCase(id: String, createdAt: String, firstReplySubmittedAt: String?) -> Case {
        Case(
            id: id, taskId: "t1", kind: .question, title: "Title", need: "N", why: "W",
            recommendation: "R", recommendationWhy: "RW", options: [], status: .waitingOnAgent,
            hasArtifact: false, firstReplySubmittedAt: firstReplySubmittedAt,
            createdAt: createdAt, updatedAt: createdAt
        )
    }

    @Test func countsOnlyCasesFirstAnsweredOnNowsCalendarDay() {
        let now = KnockDateFormat.date(from: "2026-09-29T12:00:00Z")!
        let cases = [
            waitingCase(id: "a", createdAt: "2026-09-29T10:00:00Z", firstReplySubmittedAt: "2026-09-29T10:05:00Z"),
            // Answered yesterday - still `waitingOnAgent` today, but not
            // "answered today".
            waitingCase(id: "b", createdAt: "2026-09-28T10:00:00Z", firstReplySubmittedAt: "2026-09-28T10:10:00Z"),
        ]
        let stats = CaughtUpStats.compute(waitingOnAgentCases: cases, liveSessionCount: 2, now: now)
        #expect(stats.answeredToday == 1)
        #expect(stats.agentsRunning == 2, "agents running is the live session count, not the Waiting on agent group")
    }

    @Test func medianIsTheMiddleDurationForAnOddCount() {
        let now = KnockDateFormat.date(from: "2026-09-29T12:00:00Z")!
        let cases = [
            waitingCase(id: "a", createdAt: "2026-09-29T10:00:00Z", firstReplySubmittedAt: "2026-09-29T10:01:00Z"), // 60s
            waitingCase(id: "b", createdAt: "2026-09-29T10:00:00Z", firstReplySubmittedAt: "2026-09-29T10:05:00Z"), // 300s
            waitingCase(id: "c", createdAt: "2026-09-29T10:00:00Z", firstReplySubmittedAt: "2026-09-29T10:03:00Z"), // 180s
        ]
        let stats = CaughtUpStats.compute(waitingOnAgentCases: cases, liveSessionCount: 2, now: now)
        #expect(stats.medianTimeToDecideTodaySeconds == 180)
    }

    @Test func medianIsTheAverageOfTheTwoMiddleDurationsForAnEvenCount() {
        let now = KnockDateFormat.date(from: "2026-09-29T12:00:00Z")!
        let cases = [
            waitingCase(id: "a", createdAt: "2026-09-29T10:00:00Z", firstReplySubmittedAt: "2026-09-29T10:01:00Z"), // 60s
            waitingCase(id: "b", createdAt: "2026-09-29T10:00:00Z", firstReplySubmittedAt: "2026-09-29T10:03:00Z"), // 180s
        ]
        let stats = CaughtUpStats.compute(waitingOnAgentCases: cases, liveSessionCount: 2, now: now)
        #expect(stats.medianTimeToDecideTodaySeconds == 120)
    }

    @Test func showsADashWhenNothingWasAnsweredToday() {
        let now = KnockDateFormat.date(from: "2026-09-29T12:00:00Z")!
        let cases = [waitingCase(id: "a", createdAt: "2026-09-28T10:00:00Z", firstReplySubmittedAt: "2026-09-28T10:10:00Z")]
        let stats = CaughtUpStats.compute(waitingOnAgentCases: cases, liveSessionCount: 2, now: now)
        #expect(stats.answeredToday == 0)
        #expect(stats.medianTimeToDecideTodaySeconds == nil)
    }

    @Test func ignoresACaseWithNoReplyYet() {
        let now = KnockDateFormat.date(from: "2026-09-29T12:00:00Z")!
        let cases = [waitingCase(id: "a", createdAt: "2026-09-29T10:00:00Z", firstReplySubmittedAt: nil)]
        let stats = CaughtUpStats.compute(waitingOnAgentCases: cases, liveSessionCount: 2, now: now)
        #expect(stats.answeredToday == 0)
        #expect(stats.agentsRunning == 2)
    }
}
