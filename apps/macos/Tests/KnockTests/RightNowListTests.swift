import Foundation
import Testing
@testable import Knock

/// HAIL-124: what a session is really doing.
struct RightNowBusyTests {
    private let now = KnockDateFormat.date(from: "2026-09-29T12:00:00Z")!

    private func session(
        project: String = "knock", branch: String? = "main", context: SessionContext? = nil
    ) -> SessionInfo {
        SessionInfo(
            id: "s", taskId: "task-s", runtime: .claude, taskName: "main", project: project, branch: branch,
            cwd: "/tmp", state: .live, connectedAt: "2026-09-29T09:00:00Z", lastSeenAt: "2026-09-29T11:00:00Z",
            context: context)
    }

    @Test func aGrowingSessionWithNoAskIsWorking() {
        let busy = session(context: SessionContext(growing: true))
        #expect(AgentStatus.forSession(busy, cases: []) == .working)
        #expect(AgentStatus.isBusy(busy, cases: []))
    }

    @Test func aQuietSessionStaysIdle() {
        for context in [SessionContext(growing: false), SessionContext(), nil] {
            let s = session(context: context)
            #expect(AgentStatus.forSession(s, cases: []) == .connected)
            #expect(!AgentStatus.isBusy(s, cases: []))
        }
    }

    /// HAIL-178: idle starts at the latest activity, not at the last ask or reply.
    @Test func idleCountsFromTheLatestActivity() {
        let old = "2026-09-29T10:00:00Z"
        let asked = Case(
            id: "a", taskId: "task-s", kind: .question, title: "T", need: "N", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [], status: .resolved, hasArtifact: false, latestReplyAt: old,
            createdAt: old, updatedAt: old)
        let quiet = session(context: nil)
        #expect(AgentStatus.lastActivity(quiet, cases: [asked]) == KnockDateFormat.date(from: old))

        let acting = session(context: SessionContext(lastAction: "Ran tests", lastActionAt: "2026-09-29T11:52:00Z"))
        #expect(AgentStatus.lastActivity(acting, cases: [asked]) == KnockDateFormat.date(from: "2026-09-29T11:52:00Z"))

        let hooked = session(context: SessionContext(
            lastAction: "Ran tests", lastActionAt: "2026-09-29T11:52:00Z",
            live: LiveState(phase: "idle", lastEventAt: "2026-09-29T11:57:00Z")))
        #expect(AgentStatus.lastActivity(hooked, cases: [asked]) == KnockDateFormat.date(from: "2026-09-29T11:57:00Z"))

        let checked = Case(
            id: "c", taskId: "task-s", kind: .question, title: "T", need: "N", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [], status: .waitingOnAgent, hasArtifact: false,
            lastCheckAt: "2026-09-29T11:58:00Z", createdAt: old, updatedAt: old)
        #expect(AgentStatus.lastActivity(quiet, cases: [asked, checked]) == KnockDateFormat.date(from: "2026-09-29T11:58:00Z"))
    }

    /// HAIL-178: a Claude app session that connected before 0.1.61 has no client name and runs from "/".
    @Test func aDesktopSessionWithNoClientNameIsClaudeApp() {
        let app = SessionInfo(
            id: "d", taskId: "task-d", runtime: .claude, taskName: "", project: "", branch: nil, cwd: "/",
            canNudge: false, clientName: nil, state: .live, connectedAt: "2026-09-29T09:00:00Z",
            lastSeenAt: "2026-09-29T11:59:00Z")
        #expect(app.runtimeLabel == "Claude app")
        #expect(RightNowList.summary(app, hasAsks: false) == "Claude app · no decisions yet")
        // Claude Code with no name stays Claude Code: only the "/" folder marks the desktop app.
        #expect(session(context: nil).runtimeLabel == "Claude Code")
    }

    @Test func doingNowShowsTheActionWithItsAgeAndHidesWhenOld() {
        func ctx(_ at: String?) -> SessionContext { SessionContext(lastAction: "Ran swift test", lastActionAt: at) }
        #expect(SessionContextDisplay.doingNow(ctx("2026-09-29T11:59:40Z"), now: now) == "Ran swift test · 20s ago")
        #expect(SessionContextDisplay.doingNow(ctx("2026-09-29T11:50:00Z"), now: now) == "Ran swift test · 10m ago")
        #expect(SessionContextDisplay.doingNow(ctx("2026-09-29T11:49:59Z"), now: now) == nil)
        #expect(SessionContextDisplay.doingNow(ctx(nil), now: now) == nil)
        #expect(SessionContextDisplay.doingNow(SessionContext(), now: now) == nil)
    }

    @Test func theContextCardSessionDetailCarriesDoingNow() {
        let s = session(context: SessionContext(lastAction: "Edited AppModel.swift", lastActionAt: "2026-09-29T11:59:30Z", growing: true))
        let line = SessionContextBlock.line(item: Self.anAsk, session: s, cases: [], now: now)
        #expect(line?.doingNow == "Edited AppModel.swift · 30s ago")
        let card = ContextCardModel.make(block: SessionContextBlock(line: line, earlier: []), thread: nil)
        #expect(card.rows[0].details[0].caption == "Edited AppModel.swift · 30s ago")
    }

    private static let anAsk = Case(
        id: "a", taskId: "task-s", kind: .question, title: "T", need: "N", why: "W", recommendation: "R",
        recommendationWhy: "RW", options: [], status: .needsYou, hasArtifact: false,
        createdAt: "2026-09-29T10:00:00Z", updatedAt: "2026-09-29T10:00:00Z")
}
