import Foundation
import Testing
@testable import Knock

/// HAIL-104: an answered ask shows a settled line, not a live status with a timer.
struct SettledAnswerTests {
    private static let now = KnockDateFormat.date(from: "2026-10-01T12:00:00Z")!

    private func iso(minutesAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Self.now.addingTimeInterval(-minutesAgo * 60))
    }

    private func ask(
        id: String = "a", taskId: String = "t", pickedUpMinutesAgo: Double = 1, session: SessionState? = .live,
        createdMinutesAgo: Double = 900, follows: String? = nil, title: String = "Title"
    ) -> Case {
        Case(
            id: id, taskId: taskId, kind: .question, title: title, need: "N", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [], status: .waitingOnAgent, hasArtifact: false,
            latestReplyId: "r", latestReplyState: .delivered,
            latestReplyAt: iso(minutesAgo: createdMinutesAgo - 1),
            latestReplyDeliveredAt: iso(minutesAgo: pickedUpMinutesAgo),
            latestReplyIntent: .decision, sessionState: session, followsCaseId: follows,
            createdAt: iso(minutesAgo: createdMinutesAgo), updatedAt: iso(minutesAgo: createdMinutesAgo))
    }

    private func settled(_ item: Case, _ all: [Case]? = nil) -> AnswerGrouping.Settled? {
        AnswerGrouping.settled(item, allCases: all ?? [item], now: Self.now)
    }

    @Test func aFollowedUpAskIsSettledWithALinkToTheFollowUp() throws {
        let old = ask(pickedUpMinutesAgo: 890)
        let next = ask(id: "b", createdMinutesAgo: 880, follows: "a", title: "Next question")
        let result = try #require(settled(old, [old, next]))
        #expect(result.followUp == .init(id: "b", title: "Next question"))
        #expect(result.pickedUpAt != nil)
    }

    @Test func anAskPastThePickupWindowIsSettledWithNoFollowUp() throws {
        let old = ask(pickedUpMinutesAgo: 11, createdMinutesAgo: 30)
        let result = try #require(settled(old))
        #expect(result.followUp == nil)
    }

    @Test func anAskOfAClosedSessionIsSettled() {
        #expect(settled(ask(session: .ended)) != nil)
    }

    @Test func aStillWorkingAskIsNotSettled() {
        #expect(settled(ask(pickedUpMinutesAgo: 2, createdMinutesAgo: 10)) == nil)
    }

    @Test func anAskThatNeedsYouIsNotSettled() {
        var item = ask(session: .ended)
        item = Case(
            id: item.id, taskId: item.taskId, kind: .question, title: "T", need: "N", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [], status: .needsYou, hasArtifact: false,
            createdAt: iso(minutesAgo: 5), updatedAt: iso(minutesAgo: 5))
        #expect(settled(item) == nil)
    }

    @Test func theCopyHasNoTimerWords() {
        let utc = TimeZone(identifier: "UTC")!
        let at = KnockDateFormat.date(from: "2026-10-01T21:05:00Z")!
        #expect(AgentStatusCopy.settledLine(pickedUpAt: at, timeZone: utc) == "Picked up at 21:05")
        #expect(AgentStatusCopy.settledLine(pickedUpAt: nil) == "Not picked up")
        #expect(AgentStatusCopy.followUpLine(.init(id: "b", title: "Next **one**")) == "Followed up: Next one")
    }
}
