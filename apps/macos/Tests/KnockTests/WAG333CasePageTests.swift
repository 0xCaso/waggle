import Foundation
import Testing
@testable import Knock

/// WAG-333: a done note heads the page, a narrow page puts the question first, one header on every screen.
@MainActor
struct WAG333CasePageTests {
    private func make(done: Bool, message: String?) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Which layout for the inbox?", need: "N", why: "W",
            recommendation: "R", recommendationWhy: "RW", options: [], status: .waitingOnAgent, hasArtifact: false,
            latestUpdateMessage: message, sessionState: .live,
            doneAt: done ? "2026-10-03T17:05:00.000Z" : nil,
            createdAt: "2026-10-03T16:00:00.000Z", updatedAt: "2026-10-03T17:05:00.000Z")
    }

    @Test func aDoneNoteShowsItsMessageAtTheHead() {
        let item = make(done: true, message: "  Done and live. The inbox now uses cards.\n")
        #expect(DoneNote.message(for: item) == "Done and live. The inbox now uses cards.")
    }

    @Test func noMessageOrNotDoneShowsNoNote() {
        #expect(DoneNote.message(for: make(done: true, message: nil)) == nil)
        #expect(DoneNote.message(for: make(done: true, message: "   ")) == nil)
        #expect(DoneNote.message(for: make(done: false, message: "Hello")) == nil)
    }

    @Test func thePinnedArtifactBarHasOneNameForEveryAsk() {
        let page = ArtifactTabs.tabs(revisions: [
            Revision(
                id: "r1", caseId: "c1", n: 1, createdAt: "2026-10-07T10:00:00Z", author: .agent, baseRevision: nil,
                name: nil, kind: .htmlBundle)])
        #expect(AskLayout.foldTitle(page.first) == "Prototype")
        #expect(!AskLayout.foldTitle(page.first).hasPrefix("Background"))
    }

    @Test func thePinnedArtifactBarNamesTheKindOnlyWhenTheTitleDoesNot() {
        let unnamed = ArtifactTabs.tabs(revisions: [
            Revision(
                id: "r1", caseId: "c1", n: 1, createdAt: "2026-10-07T10:00:00Z", author: .agent, baseRevision: nil,
                name: nil, kind: .htmlBundle)])
        let named = ArtifactTabs.tabs(revisions: [
            Revision(
                id: "r2", caseId: "c1", n: 2, createdAt: "2026-10-07T10:00:00Z", author: .agent, baseRevision: nil,
                name: "Cancelled page mark", kind: .htmlBundle)])
        #expect(AskLayout.barMeta(unnamed.first) == "v1")
        #expect(AskLayout.barMeta(named.first) == "Prototype · v2")
        #expect(AskLayout.barMeta(nil) == nil)
    }

    @Test func theCaseTitleShowsOnceAndStepsShowTheirQuestion() {
        #expect(AskCrumbs.showsCaseTitle(doc: nil))
    }

    @Test func oneCrumbRuleForThePageAndTheFullSizeColumn() {
        let task = KnockTask(id: "t", name: "share-link-9a8b7c6d", project: "Gym OS")
        let line = AskCrumbs.screenLine(
            task: task, sessionTitle: "Share link settings", runtime: "Claude Code", askNumber: 3, doc: nil)
        #expect(line == "Gym OS / Share link settings · Claude Code · 3rd decision in this session")
        #expect(AskCrumbs.screenLine(task: task, sessionTitle: nil, runtime: "Claude Code", askNumber: 1, doc: nil)
            == "Gym OS · Claude Code")
    }
}
