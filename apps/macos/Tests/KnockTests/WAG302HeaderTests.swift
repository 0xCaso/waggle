import Foundation
import Testing
@testable import Knock

/// WAG-302: one header and crumb on every screen.
@MainActor
struct WAG302HeaderTests {
    private let worktree = KnockTask(id: "t", name: "fragrant-hospital-fc8f1973", project: "fragrant-hospital-fc8f1973")

    @Test func crumbNeverShowsAWorktreeName() {
        let crumb = AskCrumbs.breadcrumb(task: worktree, sessionTitle: "Issue 4 fix and 0.2.18 release")
        #expect(crumb == "Fragrant hospital / Issue 4 fix and 0.2.18 release")
        #expect(!crumb.contains("fc8f1973"))
        #expect(AskCrumbs.projectName(worktree) == "Fragrant hospital")
        #expect(AskCrumbs.breadcrumb(task: worktree, sessionTitle: nil) == "Fragrant hospital")
        let topic = KnockTask(id: "t", name: "share-link-9a8b7c6d", project: "Gym OS")
        #expect(AskCrumbs.projectName(topic) == "Gym OS")
        #expect(AskCrumbs.breadcrumb(task: topic, sessionTitle: nil) == "Gym OS")
    }

    @Test func workspaceTitlebarUsesTheSameCrumbAsThePane() {
        let task = KnockTask(id: "t", name: "share-link-9a8b7c6d", project: "Gym OS")
        #expect(ReviewTitlebarView.crumbText(task: task, sessionTitle: "Share link settings") == "Gym OS · Share link settings")
        #expect(ReviewTitlebarView.crumbText(task: task, sessionTitle: nil) == "Gym OS")
        #expect(ReviewTitlebarView.crumbText(task: worktree, sessionTitle: nil) == "Fragrant hospital")
        #expect(AskCrumbs.titlePart(task: task, sessionTitle: nil) == nil)
    }

    @Test func titleSizeFollowsTheColumnWidth() {
        #expect(AskHeaderWidth.wide.titleStyle.size == 28)
        #expect(AskHeaderWidth.narrow.titleStyle.size == 19)
    }

    @Test func aNeedThatRepeatsTheTitleIsHidden() {
        #expect(NeedText.repeats("I added two new ways after your question.", title: "I added two new ways after your question."))
        #expect(NeedText.repeats("**I added two new ways.**", title: "i added two new ways"))
        #expect(!NeedText.repeats("It sits after sign-in.", title: "Where does the intake go?"))
        #expect(!NeedText.repeats("", title: ""))
    }

    private func detail(_ name: String) throws -> CaseDetail {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wag-282/\(name).json")
        return try JSONDecoder().decode(CaseDetail.self, from: Data(contentsOf: url))
    }

    @Test func aRoundWithOnlyAQuestionHasNoSeparateNeed() throws {
        let heading = try #require(RoundHeading.make(
            seq: 1, question: nil, message: "I added two new ways after your question.", originalTitle: "Old", answer: nil))
        #expect(NeedText.repeats(heading.need, title: heading.title))
        let c = try detail("question-options").case
        #expect(c.displayNeed(planRounds: nil) == "It sits after the sign-in screen.")
    }

    @Test func whyBelongsToTheFirstRound() throws {
        // A message-only update opens no round: the reason stays. A later round has none (WAG-335).
        let first = try detail("message-only").case
        #expect(first.currentWhy == first.why)
        for name in ["question-options", "plan-rounds", "round-artifact"] {
            #expect(try detail(name).case.currentWhy == nil, "\(name)")
        }
    }

    @Test func activityTextIsPlain() {
        #expect(SessionContextDisplay.plainAction("Ran (perl") == "Ran a command")
        #expect(SessionContextDisplay.plainAction("Ran ls | grep $HOME") == "Ran a command")
        #expect(SessionContextDisplay.plainAction("Ran swift test") == "Ran swift test")
        #expect(SessionContextDisplay.plainAction("Edited CasePaneView.swift") == "Edited CasePaneView.swift")
        #expect(SessionContextDisplay.plainAction("Read /Users/me/secret/x") == nil)
        #expect(SessionContextDisplay.plainAction("  ") == nil)
        #expect(SessionContextDisplay.plainAction(nil) == nil)
    }

    @Test func workingRowNeverShowsRawCommandText() {
        let ctx = SessionContext(title: nil, goal: nil, said: nil, lastAction: "Ran (perl", lastActionAt: "2026-10-06T11:55:00Z", growing: true)
        let live = SessionInfo(
            id: "s", taskId: "t1", runtime: .claude, taskName: "main", project: "WAG 301", branch: "main", cwd: "/tmp/p",
            state: .live, connectedAt: "2026-10-06T09:00:00Z", lastSeenAt: "2026-10-06T11:55:00Z", context: ctx)
        let now = KnockDateFormat.date(from: "2026-10-06T12:00:00Z")!
        let card = HomeCards.build(allCases: [], activeCases: [], sessions: [live], now: now).cards[0]
        #expect(card.state == .working)
        #expect(card.line == "Ran a command")
        #expect(!card.line.contains("("))
    }
}
