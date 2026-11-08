import Foundation
import Testing
@testable import Knock

/// PERF-3: the Answered grouping, the caught-up stats and the date parsing give the same results
/// as before, and the model computes them on a data change, not in a view body.
@MainActor
struct DerivedListsTests {
    private static func iso(_ date: Date) -> String { KnockDateFormat.string(from: date) }

    /// 60 asks over 4 days, 12 tasks. Every 7th has a newer ask on its task; some replies are not
    /// picked up, some are fresh, some have a closed session.
    private static func fixture(now: Date) -> [Case] {
        (0..<60).map { i in
            let created = now.addingTimeInterval(-Double(i) * 1.6 * 3600 - 300)
            let answeredAt = created.addingTimeInterval(240)
            let delivered = i % 5 == 0 ? nil : answeredAt.addingTimeInterval(30)
            return Case(
                id: String(format: "c_%03d", i), taskId: "t_\(i % 12)", kind: .question, title: "Ask \(i)",
                need: "N", why: "W", recommendation: "R", recommendationWhy: "RW", options: [],
                status: .waitingOnAgent, hasArtifact: false,
                latestReplyId: "r_\(i)", latestReplyState: delivered == nil ? .queued : .delivered,
                latestReplyAt: iso(answeredAt), latestReplyDeliveredAt: delivered.map(iso),
                latestReplyIntent: i % 9 == 0 ? .moreDetail : .decision,
                firstReplySubmittedAt: iso(answeredAt),
                sessionState: i % 4 == 0 ? .ended : .live,
                createdAt: iso(created), updatedAt: iso(answeredAt)
            )
        }
    }

    private func makeModel() -> AppModel {
        let client = KnockClient(socketPath: makeTempSocketPath(), backoffSchedule: [0.02])
        let home = NSTemporaryDirectory() + "knock-perf3-\(UUID().uuidString)"
        return AppModel(client: client, environment: ["KNOCK_HOME": home])
    }

    @Test func storedGroupingEqualsTheDirectComputation() {
        let model = makeModel()
        let cases = Self.fixture(now: model.now)
        model.applyLists(needsYouRaw: [], waitingRaw: cases)

        let waiting = AppModel.newestFirst(cases)
        let expected = AnswerGrouping.split(waiting: waiting, allCases: waiting, now: model.now)
        #expect(model.stillWaitingCases.map(\.id) == expected.waiting.map(\.id))
        #expect(model.answeredCases.map(\.id) == expected.answered.map(\.id))
        #expect(model.stillWaitingCases.count + model.answeredCases.count == 60)
        #expect(model.answeredCases.count > 10)

        // Answered is newest answer first, and the sections cover it in order with the same counts.
        let times = model.answeredCases.map { AnswerGrouping.answeredAt($0)! }
        #expect(times == times.sorted(by: >))
        let sections = model.visibleAnsweredDaySections
        #expect(sections == AnswerGrouping.daySections(model.answeredCases, now: model.now))
        #expect(sections.flatMap(\.cases).map(\.id) == model.answeredCases.map(\.id))
        #expect(sections.count >= 2)
        #expect(sections.first?.title == "TODAY")
        #expect(sections.map(\.cases.count).reduce(0, +) == model.answeredCases.count)
    }

    @Test func followUpDetectionAndTheStaysWaitingRuleAreUnchanged() {
        let now = Date()
        let cases = Self.fixture(now: now)
        let followed = AnswerGrouping.followedUpIds(in: cases)
        // A task's newest ask is never followed up; every older ask on a task with a newer one is.
        for item in cases {
            let newest = cases.filter { $0.taskId == item.taskId }.max { $0.createdAtDate! < $1.createdAtDate! }!
            #expect(followed.contains(item.id) == (item.id != newest.id))
        }
        // Fresh delivered reply, live session, not followed up: stays. Picked up long ago: moves.
        let fresh = cases.first { $0.latestReplyState == .delivered && $0.sessionState == .live && !followed.contains($0.id) }!
        let at = fresh.latestReplyDeliveredAtDate!
        #expect(AnswerGrouping.staysWaiting(fresh, isFollowedUp: false, now: at.addingTimeInterval(9 * 60)))
        #expect(!AnswerGrouping.staysWaiting(fresh, isFollowedUp: false, now: at.addingTimeInterval(10 * 60 + 1)) || fresh.latestReplyIntent == .moreDetail)
    }

    @Test func caughtUpStatsAreStoredAndMatchTheFunction() {
        let model = makeModel()
        let cases = Self.fixture(now: model.now)
        model.applyLists(needsYouRaw: [], waitingRaw: cases)
        model.liveSessionCount = 3
        let expected = CaughtUpStats.compute(waitingOnAgentCases: model.waitingOnAgentCases, liveSessionCount: 3, now: model.now)
        #expect(model.caughtUpStats == expected)
        #expect(model.caughtUpStats.agentsRunning == 3)
        #expect(model.caughtUpStats.answeredToday > 0)
    }

    @Test func aRefreshRegroupsOnceAndNotAtAllWhenNothingChanged() {
        let model = makeModel()
        let cases = Self.fixture(now: model.now)
        let before = model.regroupCount
        model.applyLists(needsYouRaw: [], waitingRaw: cases)
        #expect(model.regroupCount == before + 1)
        model.applyLists(needsYouRaw: [], waitingRaw: cases)
        #expect(model.regroupCount == before + 1)
        model.applyLists(needsYouRaw: [], waitingRaw: Array(cases.dropFirst()))
        #expect(model.regroupCount == before + 2)
    }

    @Test func sharedParsingMatchesAFreshFormatterAndIsFaster() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let strings = (0..<2000).map { i -> String in
            let s = Self.iso(base.addingTimeInterval(Double(i) * 977.123))
            return i % 3 == 0 ? String(s.prefix(19)) + "Z" : s
        }
        func fresh(_ s: String) -> Date? {
            let a = ISO8601DateFormatter()
            a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = a.date(from: s) { return d }
            let b = ISO8601DateFormatter()
            b.formatOptions = [.withInternetDateTime]
            return b.date(from: s)
        }
        let clock = ContinuousClock()
        var expected: [Date?] = []
        let freshTime = clock.measure { expected = strings.map(fresh) }
        var got: [Date?] = []
        let sharedTime = clock.measure { got = strings.map { KnockDateFormat.parse($0) } }
        let cachedTime = clock.measure { _ = strings.map { KnockDateFormat.date(from: $0) } }
        _ = strings.map { KnockDateFormat.date(from: $0) }
        let warm = clock.measure { got = strings.map { KnockDateFormat.date(from: $0) } }
        #expect(got == expected)
        print("PERF3 parse x2000: fresh \(freshTime), shared \(sharedTime), cold cache \(cachedTime), warm cache \(warm)")
        #expect(sharedTime < freshTime / 2)
    }
}
