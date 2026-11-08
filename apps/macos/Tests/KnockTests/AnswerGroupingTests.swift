import Foundation
import Testing
@testable import Knock

/// HAIL-64: which answered asks stay in "Waiting on agent" and which move to
/// "Answered", the day sections, and the remembered open state.
struct AnswerGroupingTests {
    private static let now = KnockDateFormat.date(from: "2026-09-29T12:00:00Z")!

    private func iso(minutesAgo: Double) -> String {
        let date = Self.now.addingTimeInterval(-minutesAgo * 60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func waitingCase(
        id: String = "c1", taskId: String = "t1", replyState: ReplyStatus? = .delivered,
        intent: ReplyIntent = .decision, deliveredMinutesAgo: Double? = 1,
        session: SessionState? = .live, createdMinutesAgo: Double = 60,
        follows: String? = nil, replaces: String? = nil, status: CaseStatus = .waitingOnAgent
    ) -> Case {
        Case(
            id: id, taskId: taskId, kind: .question, title: "Title \(id)", need: "N", why: "W",
            recommendation: "R", recommendationWhy: "RW", options: [], status: status, hasArtifact: false,
            latestReplyId: replyState == nil ? nil : "r_\(id)", latestReplyState: replyState,
            latestReplyAt: replyState == nil ? nil : iso(minutesAgo: createdMinutesAgo - 1),
            latestReplyDeliveredAt: deliveredMinutesAgo.map { iso(minutesAgo: $0) },
            latestReplyIntent: intent, sessionState: session,
            followsCaseId: follows, replacesCaseId: replaces,
            createdAt: iso(minutesAgo: createdMinutesAgo), updatedAt: iso(minutesAgo: createdMinutesAgo)
        )
    }

    private func stays(_ item: Case, followedUp: Bool = false) -> Bool {
        AnswerGrouping.staysWaiting(item, isFollowedUp: followedUp, now: Self.now)
    }

    // MARK: replaced / dismissed (HAIL-130)

    @Test func aReplacedOrDismissedCaseNeverShowsInWaitingOnAgent() {
        let live = waitingCase(id: "live", replyState: .queued, deliveredMinutesAgo: nil)
        let replaced = Self.closed(waitingCase(id: "old", replyState: .queued, deliveredMinutesAgo: nil), withdrawn: true)
        let dismissed = Self.closed(waitingCase(id: "gone", replyState: .queued, deliveredMinutesAgo: nil), dismissed: true)
        let split = AnswerGrouping.split(waiting: [live, replaced, dismissed], allCases: [live], now: Self.now)
        #expect(split.waiting.map(\.id) == ["live"])
        #expect(split.answered.isEmpty)
    }

    private static func closed(_ item: Case, withdrawn: Bool = false, dismissed: Bool = false) -> Case {
        var json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        if withdrawn { json["withdrawn_at"] = "2026-09-29T11:00:00Z" }
        if dismissed { json["dismissed_at"] = "2026-09-29T11:00:00Z" }
        return try! JSONDecoder().decode(Case.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: stays

    @Test func aQueuedReplyStaysWhileTheSessionIsLive() {
        #expect(stays(waitingCase(replyState: .queued, deliveredMinutesAgo: nil)))
    }

    @Test func aQueuedOrFailedReplyStaysForTenMinutesAfterTheSessionCloses() {
        #expect(stays(waitingCase(replyState: .queued, deliveredMinutesAgo: nil, session: .disconnected, createdMinutesAgo: 6)))
        #expect(stays(waitingCase(replyState: .failed, deliveredMinutesAgo: nil, session: .ended, createdMinutesAgo: 6)))
    }

    @Test func aNeverPickedUpReplyMovesOnceItsSessionIsGoneAndItIsTenMinutesOld() {
        #expect(!stays(waitingCase(replyState: .queued, deliveredMinutesAgo: nil, session: .disconnected)))
        #expect(!stays(waitingCase(replyState: .failed, deliveredMinutesAgo: nil, session: .ended)))
    }

    @Test func aNeverPickedUpReplyMovesWhenANewerAskFollowsIt() {
        #expect(!stays(waitingCase(replyState: .queued, deliveredMinutesAgo: nil), followedUp: true))
        #expect(!stays(waitingCase(replyState: .failed, deliveredMinutesAgo: nil), followedUp: true))
    }

    @Test func aDeliveredMoreDetailRequestStaysWhileTheSessionIsLiveEvenPastTenMinutes() {
        #expect(stays(waitingCase(intent: .moreDetail, deliveredMinutesAgo: 90)))
    }

    @Test func aReplyPickedUpUnderTenMinutesAgoStaysWhileTheSessionIsLive() {
        #expect(stays(waitingCase(deliveredMinutesAgo: 0)))
        #expect(stays(waitingCase(deliveredMinutesAgo: 9.99)))
    }

    // MARK: moves

    @Test func movesAtExactlyTenMinutesAfterPickup() {
        #expect(!stays(waitingCase(deliveredMinutesAgo: 10)))
        #expect(!stays(waitingCase(deliveredMinutesAgo: 10.01)))
        #expect(!stays(waitingCase(deliveredMinutesAgo: 600)))
    }

    @Test func movesAsSoonAsTheSessionIsClosedEndedOrDisconnected() {
        for state in [SessionState.ended, .disconnected] {
            #expect(!stays(waitingCase(deliveredMinutesAgo: 1, session: state)))
            #expect(!stays(waitingCase(intent: .moreDetail, deliveredMinutesAgo: 1, session: state)))
        }
    }

    @Test func movesWhenANewerAskFollowsIt() {
        #expect(!stays(waitingCase(deliveredMinutesAgo: 1), followedUp: true))
        #expect(!stays(waitingCase(intent: .moreDetail, deliveredMinutesAgo: 1), followedUp: true))
    }

    @Test func aSessionWithNoStateCountsAsLive() {
        #expect(stays(waitingCase(deliveredMinutesAgo: 1, session: nil)))
    }

    @Test func fallsBackToTheReplyTimeWhenAnOlderDaemonSendsNoPickupTime() {
        // latestReplyAt is created - 1 minute; created 30 minutes ago => old.
        #expect(!stays(waitingCase(deliveredMinutesAgo: nil, createdMinutesAgo: 30)))
        #expect(stays(waitingCase(deliveredMinutesAgo: nil, createdMinutesAgo: 5)))
    }

    // MARK: follow-ups

    @Test func followedUpIdsCoverFollowsReplacesAndAnyNewerCaseOnTheTask() {
        let old = waitingCase(id: "old", taskId: "t1", createdMinutesAgo: 60)
        let newer = waitingCase(id: "newer", taskId: "t1", createdMinutesAgo: 30, status: .needsYou)
        let other = waitingCase(id: "other", taskId: "t2", createdMinutesAgo: 90)
        let follower = waitingCase(id: "f", taskId: "t3", createdMinutesAgo: 5, follows: "x")
        let replacer = waitingCase(id: "r", taskId: "t3", createdMinutesAgo: 5, replaces: "y")
        let ids = AnswerGrouping.followedUpIds(in: [old, newer, other, follower, replacer])
        #expect(ids.contains("old"))
        #expect(!ids.contains("newer"))
        #expect(!ids.contains("other"), "a case on another task is not followed up")
        #expect(ids.contains("x"))
        #expect(ids.contains("y"))
    }

    @Test func splitPutsEachCaseInItsGroupAndSortsAnsweredNewestFirst() {
        let waiting = waitingCase(id: "w", taskId: "tw", deliveredMinutesAgo: 2, createdMinutesAgo: 20)
        let a1 = waitingCase(id: "a1", taskId: "ta", deliveredMinutesAgo: 120, createdMinutesAgo: 200)
        let a2 = waitingCase(id: "a2", taskId: "tb", deliveredMinutesAgo: 60, createdMinutesAgo: 100)
        let split = AnswerGrouping.split(waiting: [waiting, a1, a2], allCases: [waiting, a1, a2], now: Self.now)
        #expect(split.waiting.map(\.id) == ["w"])
        #expect(split.answered.map(\.id) == ["a2", "a1"])
    }

    // MARK: day sections

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func answered(_ id: String, at: String) -> Case {
        Case(
            id: id, taskId: "t", kind: .question, title: id, need: "N", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [], status: .waitingOnAgent, hasArtifact: false,
            latestReplyId: "r", latestReplyState: .delivered, latestReplyAt: at,
            createdAt: at, updatedAt: at
        )
    }

    @Test func groupsByDayWithTodayYesterdayThenDatesNewestFirst() {
        let cases = [
            answered("a", at: "2026-09-29T11:00:00Z"),
            answered("b", at: "2026-09-29T01:00:00Z"),
            answered("c", at: "2026-09-28T23:00:00Z"),
            answered("d", at: "2026-09-27T09:00:00Z"),
            answered("e", at: "2025-12-31T09:00:00Z"),
        ]
        let sections = AnswerGrouping.daySections(
            cases, now: Self.now, calendar: utc, locale: Locale(identifier: "en_US"))
        #expect(sections.map(\.header) == ["TODAY · 2", "YESTERDAY · 1", "SEP 27 · 1", "DEC 31, 2025 · 1"])
        #expect(sections.map { $0.cases.map(\.id) } == [["a", "b"], ["c"], ["d"], ["e"]])
    }

    @Test func noAnsweredCasesMakeNoSections() {
        #expect(AnswerGrouping.daySections([], now: Self.now).isEmpty)
    }

    // MARK: open state and keyboard

    @Test func theOpenStateIsClosedByDefaultAndRemembered() throws {
        let suite = "knock.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AnsweredGroupSettings.isOpen(defaults: defaults) == false)
        AnsweredGroupSettings.setOpen(true, defaults: defaults)
        #expect(AnsweredGroupSettings.isOpen(defaults: defaults))
        AnsweredGroupSettings.setOpen(false, defaults: defaults)
        #expect(AnsweredGroupSettings.isOpen(defaults: defaults) == false)
    }

    @Test @MainActor func theModelReadsAndWritesTheRememberedState() throws {
        let suite = "knock.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = KnockClient(socketPath: "/tmp/knock-nonexistent-\(UUID().uuidString).sock")
        let first = AppModel(client: client, environment: isolatedKnockEnvironment(), defaults: defaults)
        #expect(first.answeredOpen == false)
        first.answeredOpen = true
        let relaunched = AppModel(client: client, environment: isolatedKnockEnvironment(), defaults: defaults)
        #expect(relaunched.answeredOpen)
    }

    @Test func keyboardNavigationSkipsTheCollapsedGroupAndIncludesTheOpenOne() {
        let needs = [waitingCase(id: "n", status: .needsYou)]
        let waiting = [waitingCase(id: "w")]
        let done = [waitingCase(id: "a")]
        #expect(AppModel.navigationIds(needsYou: needs, waiting: waiting, answered: done, answeredOpen: false) == ["n", "w"])
        #expect(AppModel.navigationIds(needsYou: needs, waiting: waiting, answered: done, answeredOpen: true) == ["n", "w", "a"])
    }
}
