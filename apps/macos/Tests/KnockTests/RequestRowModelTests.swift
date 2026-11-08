import Foundation
import Testing
@testable import Knock

/// HAIL-191: the two-line queue row (state dot, title, meta line, icon) and the project name.
struct RequestRowModelTests {
    private func ask(
        status: CaseStatus = .needsYou, title: String = "Which pricing card should we ship?", project: String = "pricing-page",
        taskName: String = "feature/branch-x", doneAt: String? = nil, client: String? = nil, canNudge: Bool? = nil,
        kind: ArtifactKind? = nil
    ) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: title, need: "Need preview", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [], status: status, hasArtifact: kind != nil, doneAt: doneAt,
            sessionCanNudge: canNudge, sessionClientName: client, taskName: taskName, project: project,
            createdAt: "2026-10-06T10:00:00Z", updatedAt: "2026-10-06T10:00:00Z", artifactKind: kind)
    }

    @Test func dotFollowsTheState() {
        #expect(RequestRowModel.dotState(for: ask(status: .needsYou)) == .needsYou)
        #expect(RequestRowModel.dotState(for: ask(status: .waitingOnAgent)) == .working)
        #expect(RequestRowModel.dotState(for: ask(status: .waitingOnAgent, doneAt: "2026-10-06T11:00:00Z")) == .done)
    }

    @Test func metaLineHoldsProjectAgentAndTimeNeverTheBranch() {
        let row = RequestRowModel(item: ask(), timeLabel: "2m ago", artifactKind: nil)
        #expect(row.title == "Which pricing card should we ship?")
        #expect(row.meta == "Pricing page · Claude Code · 2m ago")
        #expect(!row.meta.contains("branch"))
    }

    @Test func agentNameFollowsTheClient() {
        let cowork = RequestRowModel(
            item: ask(client: "local-agent-mode-x", canNudge: false), timeLabel: "1h ago", artifactKind: nil)
        #expect(cowork.meta == "Pricing page · Cowork · 1h ago")
        let app = RequestRowModel(item: ask(client: "claude-ai", canNudge: false), timeLabel: "1h ago", artifactKind: nil)
        #expect(app.meta.contains("Claude app"))
    }

    @Test func emptyPartsDropOut() {
        #expect(RequestRowModel.meta(project: "", agent: "Codex", time: "now") == "Codex · now")
    }

    @Test func iconSaysWhatYouWillReview() {
        #expect(RequestRowModel.iconFor(.htmlBundle) == .prototype)
        #expect(RequestRowModel.iconFor(.markdown) == .doc)
        #expect(RequestRowModel.iconFor(.diagram) == .chart)
        #expect(RequestRowModel.iconFor(.screenshot) == .screenshots)
        #expect(RequestRowModel.iconFor(.screenshots) == .screenshots)
        #expect(RequestRowModel.iconFor(nil) == nil)
        #expect(RequestRowModel(item: ask(), timeLabel: "", artifactKind: .htmlBundle).icon == .prototype)
        #expect(RequestRowModel(item: ask(), timeLabel: "", artifactKind: nil).icon == nil)
    }

    // MARK: Project name

    @Test func topicShowsAsWritten() {
        #expect(ProjectName.display(project: "Syllotips launch email") == "Syllotips launch email")
    }

    @Test func folderNameIsReadable() {
        #expect(ProjectName.display(project: "fragrant-hospital-fc8f1973") == "Fragrant hospital")
        #expect(ProjectName.display(project: "pricing-page") == "Pricing page")
        #expect(ProjectName.display(project: "avatar_app") == "Avatar app")
        #expect(ProjectName.readable(folder: "/Users/me/work/sky-onboarding-0a1b2c3d") == "Sky onboarding")
    }

    @Test func wordsThatLookLikeHashesStay() {
        // No digit: a real word, not a hash.
        #expect(ProjectName.display(project: "my-defaced") == "My defaced")
        #expect(ProjectName.display(project: "waggleApp") == "waggleApp")
    }
}
