import Foundation
import Testing
@testable import Knock

/// HAIL-191: Home groups asks and sessions into one card per project or topic.
struct HomeCardsTests {
    private let now = KnockDateFormat.date(from: "2026-10-06T12:00:00Z")!
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func ask(
        _ id: String, project: String, status: CaseStatus = .needsYou, at: String = "2026-10-06T10:00:00Z",
        replyAt: String? = nil, doneAt: String? = nil, kind: ArtifactKind? = nil, task: String = "t1", title: String? = nil
    ) -> Case {
        Case(
            id: id, taskId: task, kind: .question, title: title ?? "Ask \(id)", need: "N", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [Option(id: "o1", label: "Approve it fully", title: "Approve")],
            status: status, hasArtifact: kind != nil, latestReplyAt: replyAt, latestReplyChoice: replyAt == nil ? nil : "o1",
            doneAt: doneAt, project: project, createdAt: at, updatedAt: replyAt ?? at, artifactKind: kind)
    }

    private func session(task: String = "t1", project: String = "p", plan: SessionContext.Plan? = nil) -> SessionInfo {
        SessionInfo(
            id: "s-\(task)", taskId: task, runtime: .claude, taskName: "main", project: project, branch: "main",
            cwd: "/tmp/\(project)", state: .live, connectedAt: "2026-10-06T09:00:00Z", lastSeenAt: "2026-10-06T11:00:00Z",
            context: SessionContext(title: nil, goal: nil, said: nil, plan: plan))
    }

    private func build(_ all: [Case], active: [Case]? = nil, sessions: [SessionInfo] = []) -> HomeCards.Overview {
        HomeCards.build(
            allCases: all, activeCases: active ?? all.filter { $0.status == .needsYou || ($0.status == .waitingOnAgent && !$0.isDone) },
            sessions: sessions, now: now, calendar: utc)
    }

    @Test func oneCardPerProjectNotPerAsk() {
        let overview = build([
            ask("a", project: "Pricing page"), ask("b", project: "pricing page", at: "2026-10-06T11:00:00Z"),
            ask("c", project: "avatar-app"),
        ])
        #expect(overview.cards.map(\.name).sorted() == ["Avatar app", "Pricing page"])
    }

    @Test func stateChips() {
        let needs = ask("n", project: "alpha")
        let working = ask("w", project: "beta", status: .waitingOnAgent, replyAt: "2026-10-06T11:00:00Z")
        let decidedToday = ask("d", project: "gamma", status: .waitingOnAgent, replyAt: "2026-10-06T08:00:00Z")
        let old = ask("q", project: "delta", status: .waitingOnAgent, at: "2026-10-04T08:00:00Z", replyAt: "2026-10-04T09:00:00Z")
        // The last two are answered: they left the open set.
        let overview = build([needs, working, decidedToday, old], active: [needs, working])
        let byName = Dictionary(uniqueKeysWithValues: overview.cards.map { ($0.name, $0.state) })
        #expect(byName["Alpha"] == .waitingOnYou)
        #expect(byName["Beta"] == .working)
        #expect(byName["Gamma"] == .decided)
        #expect(byName["Delta"] == .quiet)
    }

    @Test func cardsSortByStateThenRecency() {
        let all = [
            ask("q", project: "quiet", status: .waitingOnAgent, at: "2026-10-05T08:00:00Z", replyAt: "2026-10-05T09:00:00Z"),
            ask("n1", project: "older", at: "2026-10-06T08:00:00Z"), ask("n2", project: "newer", at: "2026-10-06T11:00:00Z"),
        ]
        let overview = build(all, active: all.filter { $0.status == .needsYou })
        #expect(overview.cards.map(\.name) == ["Newer", "Older", "Quiet"])
    }

    @Test func oldQuietCardsLeaveHome() {
        let old = ask("o", project: "ancient", status: .waitingOnAgent, at: "2026-09-01T08:00:00Z", replyAt: "2026-09-01T09:00:00Z")
        #expect(build([old], active: []).cards.isEmpty)
    }

    @Test func summaryLine() {
        let n1 = ask("n1", project: "a"), n2 = ask("n2", project: "b")
        let w1 = ask("w1", project: "c", status: .waitingOnAgent, replyAt: "2026-10-06T11:00:00Z")
        let w2 = ask("w2", project: "d", status: .waitingOnAgent, replyAt: "2026-10-06T11:00:00Z")
        let decided = ask("x", project: "e", status: .waitingOnAgent, replyAt: "2026-10-06T07:00:00Z")
        let overview = build([n1, n2, w1, w2, decided], active: [n1, n2, w1, w2])
        #expect(overview.summary == HomeCards.Summary(waiting: 2, inProgress: 2, decidedToday: 1))
        #expect(overview.summary.line == "2 things wait on you · 2 in progress · 1 decided today")
        #expect(HomeCards.Summary(waiting: 1, inProgress: 0, decidedToday: 0).line == "1 thing waits on you")
        #expect(HomeCards.Summary(waiting: 0, inProgress: 0, decidedToday: 0).line == "Nothing is waiting on you")
    }

    @Test func lineThumbsAndOpenCase() {
        let a = ask("a", project: "p", at: "2026-10-06T09:00:00Z", kind: .htmlBundle, title: "Old question")
        let b = ask("b", project: "p", at: "2026-10-06T11:00:00Z", kind: .markdown, title: "Fresh question")
        let card = build([a, b]).cards[0]
        #expect(card.line == "Fresh question")
        #expect(card.openCaseId == "b")
        #expect(card.thumbs.map(\.icon) == [.doc, .prototype])
        #expect(card.agents == ["Claude Code"])
    }

    @Test func progressOnlyWithAPlan() {
        let working = ask("w", project: "p", status: .waitingOnAgent, replyAt: "2026-10-06T11:00:00Z")
        let none = build([working], sessions: [session(project: "p")]).cards[0]
        #expect(none.progress == nil)
        let withPlan = build([working], sessions: [session(project: "p", plan: .init(done: 2, total: 5, current: nil))]).cards[0]
        #expect(withPlan.progress == HomeCards.Progress(done: 2, total: 5))
        let empty = build([working], sessions: [session(project: "p", plan: .init(done: 0, total: 0, current: nil))]).cards[0]
        #expect(empty.progress == nil)
    }

    @Test func activeAndQuietCards() {
        let needs = ask("n", project: "alpha")
        let working = ask("w", project: "beta", status: .waitingOnAgent, replyAt: "2026-10-06T11:00:00Z")
        let decidedToday = ask("d", project: "gamma", status: .waitingOnAgent, replyAt: "2026-10-06T08:00:00Z")
        let older = ask("q", project: "delta", status: .waitingOnAgent, at: "2026-10-04T08:00:00Z", replyAt: "2026-10-04T09:00:00Z")
        let overview = build([needs, working, decidedToday, older], active: [needs, working])
        #expect(overview.activeCards.map(\.name) == ["Alpha", "Beta", "Gamma"])
        #expect(overview.quietCards.map(\.name) == ["Delta"])
        #expect(build([older], active: []).activeCards.isEmpty)
    }

    @Test func agoPillTextAndLineWithoutTime() {
        let ctx = SessionContext(title: nil, goal: nil, said: nil, lastAction: "Ran swift test", lastActionAt: "2026-10-06T11:55:00Z", growing: true)
        let live = SessionInfo(
            id: "s", taskId: "t1", runtime: .claude, taskName: "main", project: "p", branch: "main", cwd: "/tmp/p",
            state: .live, connectedAt: "2026-10-06T09:00:00Z", lastSeenAt: "2026-10-06T11:55:00Z", context: ctx)
        let card = build([], sessions: [live]).cards[0]
        #expect(card.line == "Ran swift test")
        #expect(card.ago == "5m ago")
    }
}
