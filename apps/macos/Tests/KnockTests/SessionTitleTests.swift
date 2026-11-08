import Foundation
import Testing
@testable import Knock

/// WAG-279: the descriptive session title in the sidebar rows and the session detail.
struct SessionTitleTests {
    private let now = KnockDateFormat.date(from: "2026-10-07T12:00:00Z")!

    private func session(
        agent: String? = nil, claude: String? = nil, goal: String? = nil, project: String = "shaded-town",
        branch: String? = "story/WAG-279", task: String = "t1", state: SessionState = .live, id: String = "s-abc12345"
    ) -> SessionInfo {
        SessionInfo(
            id: id, taskId: task, runtime: .claude, taskName: "story/WAG-279", project: project, branch: branch,
            cwd: "/tmp/\(project)", state: state, connectedAt: "2026-10-07T09:00:00Z", lastSeenAt: "2026-10-07T11:59:00Z",
            context: SessionContext(
                title: claude, goal: goal, lastAction: "Ran swift test", lastActionAt: "2026-10-07T11:55:00Z", growing: true),
            sessionTitle: agent)
    }

    // MARK: Order

    @Test func theAgentsTitleComesFirst() {
        let s = session(agent: "Pricing page copy", claude: "Fix the pricing bug", goal: "Please fix the pricing page")
        #expect(SessionTitle.pick(s) == "Pricing page copy")
    }

    @Test func claudesOwnTitleComesSecond() {
        #expect(SessionTitle.pick(session(claude: "Fix the pricing bug", goal: "Please fix it")) == "Fix the pricing bug")
    }

    @Test func theFirstPromptComesThirdAndIsShortened() {
        let goal = "Please look at the checkout page and make the totals row easier to read on small screens"
        let title = SessionTitle.pick(session(goal: goal))
        #expect(title?.hasSuffix("…") == true)
        #expect((title?.count ?? 0) <= SessionTitle.goalMaxLength)
        #expect(goal.hasPrefix(String((title ?? "").dropLast())))
        #expect(SessionTitle.pick(session(goal: "Fix the totals row")) == "Fix the totals row")
    }

    @Test func noTitleMeansTheFolderName() {
        #expect(SessionTitle.pick(session()) == nil)
        #expect(SessionTitle.pick(session(agent: "  ", claude: "")) == nil)
    }

    @Test func aTitleThatOnlyRepeatsTheFolderFallsThrough() {
        #expect(SessionTitle.pick(session(agent: "Shaded town", claude: "Fix the bug")) == "Fix the bug")
    }

    // MARK: Slug filter

    @Test func codeLookingTitlesFallThroughToTheNextSource() {
        for bad in ["knock-waggle-xza23H", "WAG-275", "story/WAG-279", "/Users/me/app", "~/work/app", "fc8f19731b2c", "feature_branch_x"] {
            #expect(SessionTitle.looksLikeCode(bad), "\(bad) should look like code")
            #expect(SessionTitle.pick(session(agent: bad, claude: "Fix the pricing bug")) == "Fix the pricing bug")
        }
    }

    @Test func theBranchTheTaskNameAndTheSessionIdNeverShow() {
        let s = session(agent: "main", claude: "s-abc12345", goal: "Fix the pricing page", branch: "main")
        #expect(SessionTitle.pick(s) == "Fix the pricing page")
        #expect(SessionTitle.looksLikeCode("Main", session: s))
    }

    @Test func plainWordsAreNotCode() {
        for ok in ["Pricing", "Pricing page copy", "Launch email, v2", "Fix WAG-275 sidebar", "Q4 plan"] {
            #expect(!SessionTitle.looksLikeCode(ok), "\(ok) is plain")
        }
    }

    // MARK: Task lookup

    @Test func aTaskGetsItsLiveSessionsTitle() {
        let ended = session(agent: "Old work", state: .ended, id: "s-old")
        let live = session(agent: "New work", id: "s-new")
        #expect(SessionTitle.forTask("t1", in: [ended, live]) == "New work")
        #expect(SessionTitle.forTask("t2", in: [live]) == nil)
        #expect(SessionTitle.forTask("", in: [live]) == nil)
    }

    // MARK: Rows

    private func ask(_ id: String, project: String, status: CaseStatus = .needsYou, task: String = "t1") -> Case {
        Case(
            id: id, taskId: task, kind: .question, title: "Which card?", need: "N", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [], status: status, hasArtifact: false, project: project,
            createdAt: "2026-10-07T10:00:00Z", updatedAt: "2026-10-07T10:00:00Z")
    }

    @Test func aWorkingRowShowsTheTitleOverTheFolderDetail() {
        let working = ask("w", project: "shaded-town", status: .waitingOnAgent)
        let overview = HomeCards.build(
            allCases: [working], activeCases: [working], sessions: [session(agent: "Pricing page copy")], now: now)
        let row = SidebarSections.workingRows(overview).first
        #expect(row?.name == "Pricing page copy")
        #expect(row?.meta.hasPrefix("Shaded town · ") == true)
    }

    @Test func aWorkingRowWithoutATitleKeepsTheFolderAsTitle() {
        let working = ask("w", project: "shaded-town", status: .waitingOnAgent)
        let overview = HomeCards.build(allCases: [working], activeCases: [working], sessions: [session()], now: now)
        let row = SidebarSections.workingRows(overview).first
        #expect(row?.name == "Shaded town")
        #expect(row?.meta.hasPrefix("Shaded town") == false)
    }

    @Test func aNeedsYouRowKeepsTheQuestionAndAddsTheTitleAfterTheFolder() {
        let row = RequestRowModel(
            item: ask("n", project: "shaded-town"), timeLabel: "just now", artifactKind: nil, sessionTitle: "Pricing page copy")
        #expect(row.title == "Which card?")
        #expect(row.meta == "Shaded town · Pricing page copy · Claude Code · just now")
    }

    @Test func aNeedsYouRowDropsATitleThatIsTheFolderName() {
        let row = RequestRowModel(
            item: ask("n", project: "shaded-town"), timeLabel: "just now", artifactKind: nil, sessionTitle: "shaded town")
        #expect(row.meta == "Shaded town · Claude Code · just now")
        let none = RequestRowModel(item: ask("n", project: "shaded-town"), timeLabel: "just now", artifactKind: nil)
        #expect(none.meta == "Shaded town · Claude Code · just now")
    }

    // MARK: Detail

    @Test func theSessionDetailHeaderUsesTheTitle() {
        let s = session(agent: "Pricing page copy")
        #expect(SessionContextDisplay.headerTitle(session: s) == "Pricing page copy")
        #expect(SessionContextDisplay.summary(s) == "Pricing page copy")
        #expect(SessionContextDisplay.summary(session()) == "shaded-town")
    }

    // MARK: Headers

    @Test func everySectionHeaderIsCapsWithACount() {
        #expect(SidebarSections.sectionTitle("Needs you", count: 1) == "NEEDS YOU · 1")
        #expect(SidebarSections.sectionTitle("Working", count: 2) == "WORKING · 2")
        #expect(SidebarSections.sectionTitle("In planning", count: 3) == "IN PLANNING · 3")
        #expect(SidebarSections.sectionTitle("Answered", count: 12) == "ANSWERED · 12")
    }

    // MARK: Wire

    @Test func sessionTitleDecodesAndMissingIsNil() throws {
        let base = """
        {"id":"s","task_id":"t","runtime":"claude","task_name":"n","project":"p","branch":null,"cwd":"/x","pid":1,
         "can_nudge":false,"client_name":null,"state":"live","connected_at":"2026-10-07T09:00:00Z",
         "last_seen_at":"2026-10-07T09:00:00Z"
        """
        let with = try JSONDecoder().decode(SessionInfo.self, from: Data((base + #","session_title":"Pricing"}"#).utf8))
        #expect(with.sessionTitle == "Pricing")
        let without = try JSONDecoder().decode(SessionInfo.self, from: Data((base + "}").utf8))
        #expect(without.sessionTitle == nil)
    }
}
