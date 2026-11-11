import Foundation
import Testing
@testable import Knock

/// HAIL-59: the sessions panel's "now" rule, its per-session counts and the
/// queue filter it sets.
struct SessionActivityTests {
    private let now = KnockDateFormat.date(from: "2026-09-29T12:00:00Z")!

    private func session(
        _ id: String = "s1", taskId: String = "t1", branch: String? = "main",
        lastSeenAt: String = "2026-09-29T11:48:00Z"
    ) -> SessionInfo {
        SessionInfo(
            id: id, taskId: taskId, runtime: .claude, taskName: "main", project: "knock", branch: branch,
            cwd: "/tmp/knock", state: .live, connectedAt: "2026-09-29T09:46:00Z", lastSeenAt: lastSeenAt
        )
    }

    private func ask(
        _ id: String, taskId: String = "t1", status: CaseStatus, replyState: ReplyStatus? = nil,
        replyAt: String? = nil, createdAt: String = "2026-09-29T11:00:00Z"
    ) -> Case {
        Case(
            id: id, taskId: taskId, kind: .question, title: "Title \(id)", need: "N", why: "W",
            recommendation: "R", recommendationWhy: "RW", options: [], status: status, hasArtifact: false,
            latestReplyState: replyState, latestReplyAt: replyAt, createdAt: createdAt, updatedAt: createdAt
        )
    }

    // MARK: Now line

    @Test func needsYouAskWinsAndNamesTheNewestOne() {
        let cases = [
            ask("a", status: .needsYou, createdAt: "2026-09-29T10:00:00Z"),
            ask("b", status: .needsYou, createdAt: "2026-09-29T11:00:00Z"),
            ask("c", status: .waitingOnAgent, replyState: .delivered, replyAt: "2026-09-29T11:59:00Z"),
        ]
        let activity = SessionActivity.make(session: session(), cases: cases, now: now)
        #expect(activity.kind == .needsYou)
        #expect(activity.nowLine == "Waiting on you: Title b")
    }

    @Test func queuedLatestReplyWaitsForPickup() {
        let cases = [ask("a", status: .waitingOnAgent, replyState: .queued, replyAt: "2026-09-29T11:59:20Z")]
        let activity = SessionActivity.make(session: session(), cases: cases, now: now)
        #expect(activity.kind == .waitingForPickup)
        #expect(activity.nowLine == "Sent 40s ago · waiting for pickup")
    }

    @Test func deliveredLatestReplyMeansWorking() {
        let cases = [ask("a", status: .waitingOnAgent, replyState: .delivered, replyAt: "2026-09-29T11:57:00Z")]
        let activity = SessionActivity.make(session: session(), cases: cases, now: now)
        #expect(activity.kind == .working)
        #expect(activity.nowLine == "Working · 3m since your reply")
    }

    @Test func theLatestReplyDecidesBetweenAsks() {
        let cases = [
            ask("old", status: .waitingOnAgent, replyState: .queued, replyAt: "2026-09-29T11:00:00Z"),
            ask("new", status: .waitingOnAgent, replyState: .delivered, replyAt: "2026-09-29T11:50:00Z"),
        ]
        #expect(SessionActivity.make(session: session(), cases: cases, now: now).nowLine == "Working · 10m since your reply")
    }

    @Test func noAsksMeansConnectedWithNothingToAsk() {
        let activity = SessionActivity.make(session: session(), cases: [], now: now)
        #expect(activity.kind == .idle)
        #expect(activity.nowLine == "Connected, nothing to decide")
    }

    @Test func aFailedReplyIsNotWorking() {
        let cases = [ask("a", status: .waitingOnAgent, replyState: .failed, replyAt: "2026-09-29T11:59:00Z")]
        #expect(SessionActivity.make(session: session(), cases: cases, now: now).kind == .idle)
    }

    // MARK: Counts and last seen

    @Test func countsAreOnlyForTheSessionsOwnTask() {
        let cases = [
            ask("a", status: .needsYou),
            ask("b", status: .needsYou),
            ask("c", status: .waitingOnAgent, replyState: .delivered, replyAt: "2026-09-29T11:59:00Z"),
            ask("other", taskId: "t2", status: .needsYou),
        ]
        let activity = SessionActivity.make(session: session(), cases: cases, now: now)
        #expect(activity.needsYouCount == 2)
        #expect(activity.waitingCount == 1)
        let other = SessionActivity.make(session: session("s2", taskId: "t3"), cases: cases, now: now)
        #expect(other.needsYouCount == 0)
        #expect(other.waitingCount == 0)
    }

    @Test func aSessionWithoutATaskIdOwnsNoAsks() {
        let cases = [ask("a", taskId: "", status: .needsYou)]
        #expect(SessionActivity.asks(for: session(taskId: ""), in: cases).isEmpty)
    }

    @Test func lastSeenLabelFollowsTheState() {
        let needs = SessionActivity.make(
            session: session(), cases: [ask("a", status: .needsYou, createdAt: "2026-09-29T11:58:00Z")], now: now
        )
        #expect(needs.lastSeenLabel == "asked 2m ago")
        let waiting = [ask("a", status: .waitingOnAgent, replyState: .delivered, replyAt: "2026-09-29T11:59:00Z")]
        let working = SessionActivity.make(session: session(lastSeenAt: "2026-09-29T11:59:40Z"), cases: waiting, now: now)
        #expect(working.lastSeenLabel == "seen 20s ago")
        let idle = SessionActivity.make(session: session(), cases: [], now: now)
        #expect(idle.lastSeenLabel == "idle 12m")
        let justNow = SessionActivity.make(session: session(lastSeenAt: "2026-09-29T11:59:58Z"), cases: waiting, now: now)
        #expect(justNow.lastSeenLabel == "seen just now")
    }

    @Test func countLabelPrefersNeedsYou() {
        let both = SessionActivity(kind: .needsYou, nowLine: "", needsYouCount: 1, waitingCount: 2, lastSeenLabel: "")
        #expect(SessionsPopoverView.countLabel(both)?.text == "1 needs you")
        #expect(SessionsPopoverView.countLabel(both)?.urgent == true)
        let waiting = SessionActivity(kind: .working, nowLine: "", needsYouCount: 0, waitingCount: 1, lastSeenLabel: "")
        #expect(SessionsPopoverView.countLabel(waiting)?.text == "1 waiting on it")
        let none = SessionActivity(kind: .idle, nowLine: "", needsYouCount: 0, waitingCount: 0, lastSeenLabel: "")
        #expect(SessionsPopoverView.countLabel(none) == nil)
    }

    // MARK: Only really-waiting asks count (HAIL-81)

    /// What the app feeds the popover: needs-you plus the really-waiting asks.
    private func active(_ cases: [Case]) -> [Case] {
        let needsYou = cases.filter { $0.status == .needsYou }
        let waiting = cases.filter { $0.status == .waitingOnAgent }
        return needsYou + AnswerGrouping.split(waiting: waiting, allCases: cases, now: now).waiting
    }

    private func answeredAsks(_ count: Int) -> [Case] {
        (0..<count).map { i in
            ask("d\(i)", status: .waitingOnAgent, replyState: .delivered, replyAt: "2026-09-29T10:\(String(format: "%02d", i)):00Z",
                createdAt: "2026-09-29T09:\(String(format: "%02d", i)):00Z")
        }
    }

    @Test func twelveAnsweredAsksShowNoWaitingCount() {
        let cases = active(answeredAsks(12))
        let activity = SessionActivity.make(session: session(), cases: cases, now: now)
        #expect(activity.waitingCount == 0)
        #expect(SessionsPopoverView.countLabel(activity) == nil)
        #expect(activity.kind == .idle)
        #expect(AgentStatus.forSession(session(), cases: cases) == .connected)
    }

    @Test func oneQueuedReplyAmongAnsweredAsksCountsAsOne() {
        let queued = ask("q", status: .waitingOnAgent, replyState: .queued, replyAt: "2026-09-29T11:59:00Z",
                         createdAt: "2026-09-29T11:58:00Z")
        let cases = active(answeredAsks(12) + [queued])
        let activity = SessionActivity.make(session: session(), cases: cases, now: now)
        #expect(activity.waitingCount == 1)
        #expect(SessionsPopoverView.countLabel(activity)?.text == "1 waiting on it")
        #expect(activity.kind == .waitingForPickup)
        #expect(AgentStatus.forSession(session(), cases: cases) == .waitingForPickup)
    }

    @Test func aFreshDeliveredReplyIsWorkingAndCountsAsWaiting() {
        let fresh = ask("f", status: .waitingOnAgent, replyState: .delivered, replyAt: "2026-09-29T11:57:00Z",
                        createdAt: "2026-09-29T11:50:00Z")
        let cases = active(answeredAsks(12) + [fresh])
        let activity = SessionActivity.make(session: session(), cases: cases, now: now)
        #expect(activity.waitingCount == 1)
        #expect(activity.kind == .working)
    }

    @Test func footerWorkingCountIgnoresAnsweredAsks() {
        let cases = active(answeredAsks(12))
        let statuses = [AgentStatus.forSession(session(), cases: cases)]
        #expect(AgentStatus.workingCount(statuses) == 0)
    }

    // MARK: Titles, closed count, today

    @Test func titleAndUptime() {
        #expect(SessionActivity.title(session()) == "Knock")
        #expect(SessionActivity.title(session(branch: nil)) == "Knock")
        #expect(SessionActivity.uptime(session(), now: now) == "up 2h 14m")
    }

    @Test func closedInTheLastHourCountsOnlyRecentNonLiveSessions() {
        func closed(_ id: String, _ state: SessionState, _ seen: String) -> SessionInfo {
            SessionInfo(
                id: id, runtime: .claude, taskName: "t", project: "p", branch: nil, state: state,
                connectedAt: "2026-09-29T08:00:00Z", lastSeenAt: seen
            )
        }
        let sessions = [
            session(),
            closed("a", .disconnected, "2026-09-29T11:30:00Z"),
            closed("b", .ended, "2026-09-29T10:00:00Z"),
            closed("c", .ended, "2026-09-29T11:10:00Z"),
        ]
        #expect(SessionActivity.closedInLastHour(sessions, now: now) == 2)
    }

    @Test func asksTodayDropsYesterdayAndSortsNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let asks = [
            ask("y", status: .needsYou, createdAt: "2026-09-28T23:00:00Z"),
            ask("a", status: .needsYou, createdAt: "2026-09-29T09:00:00Z"),
            ask("b", status: .needsYou, createdAt: "2026-09-29T10:00:00Z"),
        ]
        #expect(SessionActivity.asksToday(asks, now: now, calendar: calendar).map(\.id) == ["b", "a"])
    }

    // MARK: Filter

    @Test func filterKeepsOnlyTheSessionsTask() {
        let cases = [ask("a", status: .needsYou), ask("b", taskId: "t2", status: .needsYou)]
        let filter = SessionFilter(taskId: "t1", label: "knock · main")
        #expect(filter.apply(cases).map(\.id) == ["a"])
    }
}

/// HAIL-69: the sessions panel's height rule and the detail's ask rows.
struct SessionsPanelAsksTests {
    private let now = KnockDateFormat.date(from: "2026-09-29T12:00:00Z")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func ask(
        _ id: String, status: CaseStatus, replyState: ReplyStatus? = nil,
        intent: ReplyIntent? = nil, createdAt: String = "2026-09-29T11:00:00Z"
    ) -> Case {
        Case(
            id: id, taskId: "t1", kind: .question, title: "Title \(id)", need: "N", why: "W",
            recommendation: "R", recommendationWhy: "RW", options: [], status: status, hasArtifact: false,
            latestReplyState: replyState, latestReplyIntent: intent, createdAt: createdAt, updatedAt: createdAt
        )
    }

    @Test func heightIsWindowMinusFooterAndMargin() {
        #expect(SessionsPanelLayout.maxHeight(windowHeight: 400) == CGFloat(336))
        #expect(SessionsPanelLayout.maxHeight(windowHeight: 700) == 520)
        #expect(SessionsPanelLayout.maxHeight(windowHeight: 584) == 520)
        #expect(SessionsPanelLayout.maxHeight(windowHeight: 30) == 0)
    }

    @Test func askListShowsAtMostEightRows() {
        let h = SessionsPanelLayout.askRowHeight
        #expect(SessionsPanelLayout.askListHeight(rowCount: 3, dividerCount: 0) == 3 * h)
        #expect(SessionsPanelLayout.askListHeight(rowCount: 20, dividerCount: 0) == 8 * h)
        #expect(SessionsPanelLayout.askListHeight(rowCount: 20, dividerCount: 1) == 8 * h + SessionsPanelLayout.dividerHeight)
    }

    @Test func stateLineFollowsTheQueueStatus() {
        func line(_ c: Case, answered: Bool = false) -> String {
            SessionAskRow(ask: c, status: AgentStatus.forCase(c), isAnswered: answered).stateLine
        }
        #expect(line(ask("a", status: .needsYou)) == "Needs you")
        #expect(line(ask("b", status: .waitingOnAgent, replyState: .queued)) == "Not picked up yet")
        #expect(line(ask("c", status: .waitingOnAgent, replyState: .delivered)) == "Working")
        #expect(line(ask("d", status: .waitingOnAgent, replyState: .delivered, intent: .moreDetail)) == "Writing")
        #expect(line(ask("e", status: .waitingOnAgent, replyState: .delivered), answered: true) == "Answered")
    }

    @Test func groupsAreNewestFirstOpenBeforeAnsweredAndCountAll() {
        let open = [
            ask("o1", status: .needsYou, createdAt: "2026-09-29T09:00:00Z"),
            ask("o2", status: .waitingOnAgent, replyState: .queued, createdAt: "2026-09-29T10:00:00Z"),
        ]
        let answered = [
            ask("a1", status: .waitingOnAgent, replyState: .delivered, createdAt: "2026-09-29T08:00:00Z"),
            ask("a2", status: .waitingOnAgent, replyState: .delivered, createdAt: "2026-09-29T07:00:00Z"),
            ask("old", status: .waitingOnAgent, replyState: .delivered, createdAt: "2026-09-28T07:00:00Z"),
        ]
        let groups = SessionActivity.askGroups(open: open, answered: answered, now: now, calendar: calendar)
        #expect(groups.open.map(\.id) == ["o2", "o1"])
        #expect(groups.answered.map(\.id) == ["a1", "a2"])
        #expect(groups.total == 4)
        #expect(groups.answered.allSatisfy { $0.stateLine == "Answered" })
    }
}
