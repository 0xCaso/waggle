import Foundation
import Testing
@testable import Knock

/// WAG-255: the New idea page, its prompt, and the sidebar's Working and In planning lists.
@MainActor
struct NewIdeaTests {
    private let now = KnockDateFormat.date(from: "2026-10-07T12:00:00Z")!

    private func plan(
        _ id: String, stage: PlanStageName = .questions, status: CaseStatus = .needsYou, title: String = "A plan",
        doneAt: String? = nil, dismissedAt: String? = nil, isPlan: Bool = true, project: String = "alpha"
    ) -> Case {
        Case(
            id: id, taskId: "t-\(id)", kind: .question, title: title, need: "N", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [Option(id: "o1", label: "Approve it fully", title: "Approve")],
            status: status, hasArtifact: false, dismissedAt: dismissedAt, doneAt: doneAt, project: project,
            createdAt: "2026-10-07T10:00:00Z", updatedAt: "2026-10-07T10:00:00Z",
            plan: isPlan ? PlanInfo(stage: PlanStage(name: stage), rounds: 1, answered: 0) : nil)
    }

    // MARK: In planning

    @Test func onlyOpenPlansShow() {
        let rows = SidebarSections.planRows([
            plan("a"), plan("b", status: .waitingOnAgent), plan("c", isPlan: false),
            plan("d", status: .waitingOnAgent, doneAt: "2026-10-07T11:00:00Z"),
            plan("e", dismissedAt: "2026-10-07T11:00:00Z"),
        ])
        #expect(rows.map(\.id) == ["b"])
    }

    @Test func stageWordAndMeta() {
        let rows = SidebarSections.planRows([
            plan("a", stage: .questions), plan("b", stage: .approaches, status: .waitingOnAgent),
            plan("c", stage: .design), plan("d", stage: .spec, status: .waitingOnAgent),
        ])
        #expect(rows.map(\.meta) == ["Approaches · working", "Spec · working"])
    }

    @Test func needsYouPlanIsNotInPlanningAndWorkingPlanKeepsItsTitle() {
        let rows = SidebarSections.planRows([plan("w", status: .waitingOnAgent, title: "Work"), plan("n", title: "Need")])
        #expect(rows.map(\.id) == ["w"])
        #expect(rows.first?.title == "Work")
    }

    @Test func needsYouRowMetaStartsWithPlanAndStage() {
        for (stage, word) in [(PlanStageName.questions, "Questions"), (.approaches, "Approaches"), (.design, "Design"), (.spec, "Spec")] {
            let row = RequestRowModel(item: plan("p", stage: stage), timeLabel: "2m ago", artifactKind: nil)
            #expect(row.meta.hasPrefix("Plan · \(word) · Alpha"))
        }
    }

    @Test func nonPlanRowMetaHasNoPlanPrefix() {
        let row = RequestRowModel(item: plan("p", isPlan: false), timeLabel: "2m ago", artifactKind: nil)
        #expect(!row.meta.contains("Plan"))
        #expect(row.meta.hasPrefix("Alpha"))
    }

    @Test func noPlansNoRows() {
        #expect(SidebarSections.planRows([]).isEmpty)
    }

    // MARK: Working

    @Test func workingListHoldsOnlyWorkingProjects() {
        let working = plan("w", status: .waitingOnAgent, project: "beta")
        let needs = plan("n", project: "alpha")
        let overview = HomeCards.build(allCases: [needs, working], activeCases: [needs, working], sessions: [], now: now)
        let rows = SidebarSections.workingRows(overview)
        #expect(rows.map(\.name) == ["Beta"])
        #expect(rows.first?.meta.hasPrefix("Working on your answer") == true)
        #expect(rows.first?.openCaseId == "w")
    }

    @Test func answeredAskSetsTheWorkingLineAndOpensThatAsk() {
        let answered = plan("a1", status: .waitingOnAgent, title: "Pick the flow", project: "beta")
        let overview = HomeCards.build(allCases: [answered], activeCases: [answered], sessions: [], now: now)
        let rows = SidebarSections.workingRows(overview, held: [answered])
        #expect(rows.map(\.name) == ["Beta"])
        #expect(rows.first?.meta.hasPrefix("Working on your answer: Pick the flow") == true)
        #expect(rows.first?.openCaseId == "a1")
        #expect(rows.first?.meta.contains("Needs your decision") == false)
    }

    @Test func finishedOrClosedAnswersDoNotSetTheLine() {
        let done = plan("d1", status: .waitingOnAgent, title: "Old", doneAt: "2026-10-07T11:00:00Z", project: "beta")
        let overview = HomeCards.build(allCases: [done], activeCases: [], sessions: [], now: now)
        #expect(SidebarSections.workingRows(overview, held: [done]).isEmpty)
        let closed = plan("c1", status: .waitingOnAgent, title: "Gone", dismissedAt: "2026-10-07T11:00:00Z", project: "beta")
        let other = plan("w", status: .waitingOnAgent, title: "Real", project: "beta")
        let two = HomeCards.build(allCases: [closed, other], activeCases: [closed, other], sessions: [], now: now)
        #expect(SidebarSections.workingRows(two, held: [closed]).first?.meta.contains("Gone") == false)
    }

    @Test func withoutAnAnswerTheLineStaysTheCardLine() {
        let working = plan("w", status: .waitingOnAgent, project: "beta")
        let overview = HomeCards.build(allCases: [working], activeCases: [working], sessions: [], now: now)
        #expect(SidebarSections.workingRows(overview, held: []).first?.meta == SidebarSections.workingRows(overview).first?.meta)
        #expect(SidebarSections.workingRows(overview, held: [plan("x", status: .waitingOnAgent, project: "other")]).first?.openCaseId == "w")
    }

    // WAG-343: an answered ask shows once. The Working row and the In planning row open it; Answered skips it.
    @Test func anAnswerShownInWorkingIsNotListedAgainInAnswered() {
        let answered = plan("a1", status: .waitingOnAgent, title: "Pick the flow", isPlan: false, project: "beta")
        let overview = HomeCards.build(allCases: [answered], activeCases: [answered], sessions: [], now: now)
        #expect(SidebarSections.workingRows(overview, held: [answered]).first?.openCaseId == "a1")
        #expect(SidebarSections.heldAsks([answered], overview: overview, activeCases: [answered]).isEmpty)
    }

    @Test func aPlanShownInPlanningIsNotListedAgainInAnswered() {
        let held = plan("p1", status: .waitingOnAgent, title: "The plan", project: "beta")
        let overview = HomeCards.build(allCases: [held], activeCases: [held], sessions: [], now: now)
        #expect(SidebarSections.planRows([held]).map(\.id) == ["p1"])
        #expect(SidebarSections.heldAsks([held], overview: overview, activeCases: [held]).isEmpty)
    }

    @Test func anAskNoRowOpensStaysInAnswered() {
        let shown = plan("a1", status: .waitingOnAgent, title: "Shown", isPlan: false, project: "beta")
        let other = plan("a2", status: .waitingOnAgent, title: "Other", isPlan: false, project: "gamma")
        let overview = HomeCards.build(allCases: [shown], activeCases: [shown], sessions: [], now: now)
        #expect(SidebarSections.heldAsks([shown, other], overview: overview, activeCases: [shown]).map(\.id) == ["a2"])
    }

    @Test func sidebarHasNoAgentsAreOnItSection() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Knock/Queue")
        let text = try String(contentsOf: dir.appendingPathComponent("QueueListView.swift"), encoding: .utf8)
        #expect(!text.contains("Your agents are on it"))
    }

    // MARK: Prompt

    @Test func planPromptWithIdeaOnly() {
        let text = DocumentPrompt.build(idea: "A shared shopping list", paths: [], goal: .plan)
        #expect(text.contains("My idea:\nA shared shopping list"))
        #expect(!text.contains("Attached files"))
        #expect(text.contains("Read the idea."))
        #expect(text.contains("ONE Waggle plan ask"))
        #expect(text.contains("kind \"plan\""))
        #expect(text.contains("questions, approaches, design, spec"))
        #expect(text.contains("waggle_update"))
        #expect(text.contains("markdown file in the session folder"))
        #expect(!text.contains("—"))
    }

    @Test func planPromptWithIdeaAndFiles() {
        let text = DocumentPrompt.build(idea: "Notes", paths: ["/tmp/a.png", "/tmp/my brief.pdf"], goal: .plan)
        #expect(text.contains("- /tmp/a.png"))
        #expect(text.contains("- \"/tmp/my brief.pdf\""))
        #expect(text.contains("Read the idea and the attached files."))
    }

    @Test func otherGoalsKeepTheirText() {
        let text = DocumentPrompt.build(idea: "x", paths: [], goal: .decisions)
        #expect(text.contains("Find the open decisions in it"))
        #expect(DocumentPrompt.build(idea: "", paths: ["/tmp/a.md"], goal: .review) ==
            "Attached files:\n- /tmp/a.md\n\nRead the idea and the attached files. Tell me what is unclear or missing in it, one point at a time, as asks in Waggle.")
    }

    @Test func planIsFirstGoal() {
        #expect(DocumentGoal.allCases.first == .plan)
        #expect(DocumentGoal.ideaGoals.map(\.chipTitle) == ["Plan it with me", "Options to decide on", "Clickable prototype", "Review"])
    }
}
