import Foundation
import Testing
@testable import Knock

/// HAIL-102: the session line and the earlier asks of the same session.
struct SessionContextBlockTests {
    private let now = KnockDateFormat.date(from: "2026-10-01T12:00:00Z")!

    private func ask(
        _ id: String, taskId: String = "t1", createdAt: String, status: CaseStatus = .waitingOnAgent,
        choice: String? = nil, message: String? = nil, replyAt: String? = nil,
        updateMessage: String? = nil, updateAt: String? = nil, dismissedAt: String? = nil,
        withdrawnAt: String? = nil
    ) -> Case {
        Case(
            id: id, taskId: taskId, kind: .question, title: "T \(id)", need: "N", why: "W", recommendation: "a",
            recommendationWhy: "RW",
            options: [Option(id: "a", label: "Plain language, three lines at most", title: "Plain language"),
                      Option(id: "b", label: "Technical", title: "Technical")],
            status: status, hasArtifact: false,
            latestReplyAt: replyAt, latestReplyChoice: choice, latestReplyMessage: message,
            updateCount: updateMessage == nil ? nil : 1, latestUpdateAt: updateAt, latestUpdateMessage: updateMessage,
            dismissedAt: dismissedAt, withdrawnAt: withdrawnAt,
            createdAt: createdAt, updatedAt: createdAt
        )
    }

    private func session(said: String?) -> SessionInfo {
        SessionInfo(
            id: "s", taskId: "t1", runtime: .claude, taskName: "main", project: "omea", branch: "main",
            cwd: "/tmp", state: .live, connectedAt: "2026-10-01T10:00:00Z", lastSeenAt: "2026-10-01T11:59:00Z",
            context: said.map { SessionContext(said: $0) })
    }

    private var third: Case { ask("c", createdAt: "2026-10-01T11:30:00Z", status: .needsYou) }
    private var earlierAsks: [Case] {
        [
            ask("a", createdAt: "2026-10-01T10:00:00Z", choice: "a", replyAt: "2026-10-01T10:12:00Z"),
            ask("b", createdAt: "2026-10-01T10:30:00Z", message: "Show study size\nand year", replyAt: "2026-10-01T11:05:00Z",
                updateMessage: "Search box done", updateAt: "2026-10-01T11:20:00Z"),
        ]
    }

    @Test func earlierItemsAreAnswersAndUpdatesOldestFirst() {
        let items = SessionContextBlock.items(of: third, in: earlierAsks + [third])
        #expect(items.map(\.text) == [
            "You chose: Plain language", "You answered: Show study size", "Update: Search box done",
        ])
        #expect(items.map(\.caseId) == ["a", "b", "b"])
        #expect(items.map(\.kind) == [.answer, .answer, .update])
    }

    @Test func otherSessionsLaterAsksAndDismissedAsksAreLeftOut() {
        let cases = earlierAsks + [
            ask("x", taskId: "t2", createdAt: "2026-10-01T10:00:00Z", choice: "a", replyAt: "2026-10-01T10:01:00Z"),
            ask("later", createdAt: "2026-10-01T11:45:00Z", choice: "a", replyAt: "2026-10-01T11:50:00Z"),
            ask("gone", createdAt: "2026-10-01T10:10:00Z", choice: "a", replyAt: "2026-10-01T10:11:00Z",
                dismissedAt: "2026-10-01T10:20:00Z"),
            ask("old", createdAt: "2026-10-01T10:05:00Z", choice: "a", replyAt: "2026-10-01T10:06:00Z",
                withdrawnAt: "2026-10-01T10:07:00Z"),
            third,
        ]
        let items = SessionContextBlock.items(of: third, in: cases)
        #expect(Set(items.map(\.caseId)) == ["a", "b"])
    }

    @Test func anEarlierAskWithNoAnswerOrUpdateAddsNothing() {
        let open = ask("o", createdAt: "2026-10-01T10:00:00Z", status: .needsYou)
        #expect(SessionContextBlock.items(of: third, in: [open, third]).isEmpty)
    }

    @Test func foldsToTheLastTwoAndShowsAllOnRequest() {
        let items = SessionContextBlock.items(of: third, in: earlierAsks + [third])
        #expect(SessionContextBlock.visible(items, showAll: false).map(\.text) == [
            "You answered: Show study size", "Update: Search box done",
        ])
        #expect(SessionContextBlock.visible(items, showAll: true).count == 3)
    }

    @Test func ordinals() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 101, 112].map(SessionContextBlock.ordinal)
            == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "101st", "112th"])
    }

    @Test func theLineNamesTheSummaryTheNumberAndTheStart() {
        let cases = earlierAsks + [third]
        let line = SessionContextBlock.line(item: third, session: session(said: "Wiring a real source."), cases: cases, now: now)
        #expect(line?.summary == "omea", "the agent's last message is never the summary")
        #expect(line?.detail == "· 3rd decision · started 2h 0m ago")
    }

    @Test func theLineFallsBackToTheProjectWithoutATitleOrGoal() {
        let cases = earlierAsks + [third]
        #expect(SessionContextBlock.line(item: third, session: session(said: nil), cases: cases, now: now)?.summary == "omea")
        #expect(SessionContextBlock.line(item: third, session: session(said: "Wiring a real source."), cases: cases, now: now)?.summary == "omea")
        #expect(SessionContextBlock.line(item: third, session: nil, cases: cases, now: now) == nil)
        let block = SessionContextBlock.make(item: ask("solo", createdAt: "2026-10-01T09:00:00Z"), session: nil, cases: [], now: now)
        #expect(block.isEmpty)
    }

    @Test func aFreeTextAnswerWithNoMessageAddsNothing() {
        let empty = ask("e", createdAt: "2026-10-01T10:00:00Z", replyAt: "2026-10-01T10:01:00Z")
        #expect(SessionContextBlock.items(of: third, in: [empty, third]).isEmpty)
    }
}
