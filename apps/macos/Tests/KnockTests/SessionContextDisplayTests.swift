import Foundation
import SwiftUI
import Testing
@testable import Knock

/// HAIL-72: the sessions popover's context lines: the row's line 3 ladder,
/// the top alignment of the grid and the time, and the detail's hidden sections.
struct SessionContextDisplayTests {
    private let now = KnockDateFormat.date(from: "2026-09-30T12:00:00Z")!

    private func session(_ context: SessionContext?) -> SessionInfo {
        SessionInfo(
            id: "s1", taskId: "t1", runtime: .claude, taskName: "main", project: "knock", branch: "main",
            cwd: "/tmp/knock", state: .live, connectedAt: "2026-09-30T09:00:00Z",
            lastSeenAt: "2026-09-30T11:59:40Z", context: context)
    }

    private func ask(_ status: CaseStatus, replyState: ReplyStatus? = nil, replyAt: String? = nil) -> Case {
        Case(
            id: "a", taskId: "t1", kind: .question, title: "Pick one", need: "N", why: "W",
            recommendation: "R", recommendationWhy: "RW", options: [], status: status, hasArtifact: false,
            latestReplyState: replyState, latestReplyAt: replyAt, createdAt: "2026-09-30T11:00:00Z",
            updatedAt: "2026-09-30T11:00:00Z")
    }

    private func activity(_ s: SessionInfo, _ cases: [Case] = []) -> SessionActivity {
        SessionActivity.make(session: s, cases: cases, now: now)
    }

    private let plan = SessionContext.Plan(done: 2, total: 5, current: "Writing the parser")

    // MARK: Row line 3 ladder

    @Test func needsYouWinsOverPlanAndAction() {
        let s = session(SessionContext(lastAction: "Ran fleet board", plan: plan))
        #expect(SessionContextDisplay.rowLine(activity: activity(s, [ask(.needsYou)]), context: s.context) == .status)
    }

    @Test func waitingForPickupWinsOverContext() {
        let s = session(SessionContext(lastAction: "Ran fleet board", plan: plan))
        let cases = [ask(.waitingOnAgent, replyState: .queued, replyAt: "2026-09-30T11:59:00Z")]
        #expect(SessionContextDisplay.rowLine(activity: activity(s, cases), context: s.context) == .status)
    }

    @Test func planBeatsLastAction() {
        let s = session(SessionContext(lastAction: "Ran fleet board", plan: plan))
        #expect(SessionContextDisplay.rowLine(activity: activity(s), context: s.context)
            == .plan(done: 2, total: 5, text: "2 of 5 · Writing the parser"))
    }

    @Test func lastActionWhenNoPlan() {
        let s = session(SessionContext(lastAction: "Ran fleet board"))
        #expect(SessionContextDisplay.rowLine(activity: activity(s), context: s.context) == .lastAction("Ran fleet board"))
    }

    @Test func nothingFallsBackToTodaysLine() {
        for context in [nil, SessionContext(), SessionContext(title: "Only a title")] {
            let s = session(context)
            #expect(SessionContextDisplay.rowLine(activity: activity(s), context: s.context) == .status)
        }
    }

    // MARK: Alignment

    @Test func gridAndTimeAreTopAligned() {
        #expect(SessionRowLayout.rowAlignment == .top)
        #expect(SessionRowLayout.rowAlignment != .center)
        #expect(SessionRowLayout.trailingAlignment == .trailing)
        // The grid (13.5 pt at cell 4) sits within the first text line, not below it.
        #expect(SessionRowLayout.gridTopInset >= 0 && SessionRowLayout.gridTopInset <= 3)
        #expect(SessionRowLayout.timeTopInset >= 0 && SessionRowLayout.timeTopInset <= 3)
    }

    // MARK: Header

    @Test func titleReplacesProjectInTheHeader() {
        let s = session(SessionContext(title: "Session context in the popover"))
        #expect(SessionContextDisplay.headerTitle(session: s) == "Session context in the popover")
        #expect(SessionContextDisplay.headerSubtitle(session: s, now: now) == "Knock · Claude Code · seen 20s ago")
        let plain = session(nil)
        #expect(SessionContextDisplay.headerTitle(session: plain) == "Knock")
        #expect(SessionContextDisplay.headerSubtitle(session: plain, now: now).hasPrefix("Claude Code · up "))
    }

    // MARK: Detail sections

    @Test func emptySectionsAreHidden() {
        for context in [nil, SessionContext(), SessionContext(recent: [""], changes: nil)] {
            let sections = SessionContextDisplay.sections(session: session(context), now: now)
            #expect(sections == SessionContextDisplay.Sections(goal: nil, said: nil, lastLine: nil, recent: [], changes: nil))
            #expect(!sections.hasNowContext)
        }
    }

    @Test func fullContextFillsEverySection() {
        let context = SessionContext(
            title: "T", goal: "Show what each session is doing", said: "Done with the parser.",
            lastAction: "Edited Bar.ts", lastActionAt: "2026-09-30T11:59:00Z",
            recent: ["Ran fleet board", "Count the files", "Edited Bar.ts"],
            changes: .init(files: 3, added: 120, removed: 4, clean: false, lastCommit: "Fix the thing"))
        let sections = SessionContextDisplay.sections(session: session(context), now: now)
        #expect(sections.goal == "Show what each session is doing")
        #expect(sections.said == "Done with the parser.")
        #expect(sections.lastLine == "Last: Edited Bar.ts · 1m ago")
        #expect(sections.recent == ["Edited Bar.ts", "Count the files", "Ran fleet board"])
        #expect(sections.changes == "3 files · +120 \u{2212}4 · Fix the thing")
    }

    @Test func changesLineVariants() {
        typealias C = SessionContext.Changes
        #expect(SessionContextDisplay.changesLine(C(files: 0, added: 0, removed: 0, clean: true, lastCommit: "Fix")) == "Clean · Fix")
        #expect(SessionContextDisplay.changesLine(C(files: 0, added: 0, removed: 0, clean: true, lastCommit: nil)) == "Clean")
        #expect(SessionContextDisplay.changesLine(C(files: 1, added: 2, removed: 0, clean: false, lastCommit: nil)) == "1 file · +2 \u{2212}0")
    }

    // MARK: Decoding

    @Test func decodesContextAndToleratesItsAbsence() throws {
        let base = """
        {"id":"s","task_id":"t","runtime":"claude","task_name":"n","project":"p","branch":null,"cwd":"/x",
         "state":"live","connected_at":"2026-09-30T09:00:00Z","last_seen_at":"2026-09-30T09:00:00Z"
        """
        let old = try JSONDecoder().decode(SessionInfo.self, from: Data((base + "}").utf8))
        #expect(old.context == nil)
        let withContext = try JSONDecoder().decode(SessionInfo.self, from: Data((base + """
        ,"context":{"title":"T","goal":null,"said":null,"last_action":"Ran x","last_action_at":null,
         "recent":["Ran x"],"plan":{"done":1,"total":2,"current":null},
         "changes":{"files":1,"added":2,"removed":3,"clean":false,"last_commit":"c"}}}
        """).utf8))
        #expect(withContext.context?.title == "T")
        #expect(withContext.context?.plan?.total == 2)
        #expect(withContext.context?.changes?.lastCommit == "c")
        let bad = try JSONDecoder().decode(SessionInfo.self, from: Data((base + ",\"context\":{\"recent\":5}}").utf8))
        #expect(bad.context == nil) // an unreadable context never hides the session
    }
}
