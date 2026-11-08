import Foundation
import Testing
@testable import Knock

/// HAIL-119: the "← Home" rule and its Esc guard, and the session summary.
@MainActor
struct HomeExpansionTests {
    private let now = KnockDateFormat.date(from: "2026-09-29T12:00:00Z")!

    private func session(title: String? = nil, goal: String? = nil, said: String? = nil, project: String = "knock") -> SessionInfo {
        SessionInfo(
            id: "s", taskId: "task-s", runtime: .claude, taskName: "main", project: project, branch: "main",
            cwd: "/tmp", state: .live, connectedAt: "2026-09-29T09:00:00Z", lastSeenAt: "2026-09-29T11:00:00Z",
            context: SessionContext(title: title, goal: goal, said: said))
    }

    private func ask(
        _ id: String, at: String, status: CaseStatus = .waitingOnAgent, title: String? = nil, choice: String? = nil,
        replyAt: String? = nil, dismissedAt: String? = nil, task: String = "task-s"
    ) -> Case {
        Case(
            id: id, taskId: task, kind: .question, title: title ?? "Ask \(id)", need: "N", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [Option(id: "o1", label: "Approve it fully", title: "Approve")],
            status: status, hasArtifact: false, latestReplyAt: replyAt, latestReplyChoice: choice,
            dismissedAt: dismissedAt, createdAt: at, updatedAt: at)
    }

    // MARK: Home link

    @Test func homeShowsOnlyForACaseOutsideNeedsYou() {
        let needs = [ask("n", at: "2026-09-29T09:00:00Z", status: .needsYou)]
        #expect(HomeLink.isVisible(caseId: "n", needsYou: needs) == false)
        #expect(HomeLink.isVisible(caseId: "answered", needsYou: needs))
        #expect(HomeLink.isVisible(caseId: "x", needsYou: []))
    }

    /// HAIL-121: the visual split shows Home under the same rule, via `SplitFoldHeaderView.onHome`.
    @Test func splitHeaderShowsHomeOnlyWhenGivenTheAction() {
        let needs = [ask("n", at: "2026-09-29T09:00:00Z", status: .needsYou)]
        #expect(HomeLink.isVisible(caseId: "n", needsYou: needs) == false, "a Needs you prototype has no Home")
        #expect(HomeLink.isVisible(caseId: "proto-answered", needsYou: needs), "an answered prototype ask has Home")
    }

    @Test func escapeGoesHomeOnlyWhenNothingElseOwnsTheKey() {
        func go(
            visible: Bool = true, text: Bool = false, unsent: Bool = false, dialog: Bool = false, folded: Bool = false
        ) -> Bool {
            HomeLink.escapeGoesHome(
                isVisible: visible, textInputFocused: text, holdsUnsentWork: unsent, dialogOpen: dialog, isBothFolded: folded)
        }
        #expect(go())
        #expect(!go(visible: false), "a Needs you ask has no Home")
        #expect(!go(text: true), "a focused text field keeps Esc")
        #expect(!go(unsent: true), "unsent text, a comment, a detail or a Change answer edit keeps Esc")
        #expect(!go(dialog: true))
        #expect(!go(folded: true), "Esc leaves the both-sides fold first")
    }

    // MARK: Model

    @Test func goHomeClearsTheSelection() {
        let client = KnockClient(socketPath: "/tmp/knock-hail119-none.sock", backoffSchedule: [0.02])
        let model = AppModel(client: client, environment: isolatedKnockEnvironment())
        model.goHome()
        #expect(model.selectedCaseId == nil && model.selectedCaseDetail == nil)
    }

    // MARK: Summary

    @Test func summaryPrefersTitleThenGoalThenProjectNeverSaid() {
        let said = "0.1.44 is out (build 47): https://example.com"
        #expect(SessionContextDisplay.summary(session(title: "Fix the check-in", goal: "Fix it", said: said)) == "Fix the check-in")
        #expect(SessionContextDisplay.summary(session(title: "  ", goal: "Fix the check-in flow.", said: said)) == "Fix the check-in flow.")
        #expect(SessionContextDisplay.summary(session(said: said)) == "knock")
        #expect(SessionContextDisplay.summary(SessionInfo(
            id: "s", taskId: "t", runtime: .claude, taskName: "m", project: "gym", branch: nil, cwd: "/", state: .live,
            connectedAt: "2026-09-29T09:00:00Z", lastSeenAt: "2026-09-29T09:00:00Z", context: nil)) == "gym")
    }

    @Test func theContextCardLineUsesTheSummary() {
        let current = ask("c", at: "2026-09-29T11:00:00Z", status: .needsYou)
        let line = SessionContextBlock.line(
            item: current, session: session(title: "Fix the check-in", said: "Release is out"), cases: [current], now: now)
        #expect(line?.summary == "Fix the check-in")
        let noTitle = SessionContextBlock.line(item: current, session: session(said: "Release is out"), cases: [current], now: now)
        #expect(noTitle?.summary == "knock")
    }
}
