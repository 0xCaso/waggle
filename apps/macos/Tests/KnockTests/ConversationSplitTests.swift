import Testing
import Foundation
@testable import Knock

/// HAIL-71: the split pane's message list, words and collapse threshold.
struct ConversationSplitTests {
    // WAG-299: the column starts closed, the header icon opens it. The pane keeps the open flag
    // in per-case state (it starts false, and the pane is keyed by case id), so these tests cover
    // the rule that decides what shows.
    @Test func columnIsClosedWhenACaseOpensEvenWithAThread() {
        #expect(!ConversationSplit.isShown(hasThread: true, isOpen: false, isBothFolded: false))
    }

    @Test func toggleOpensAndClosesTheColumn() {
        var isOpen = false
        isOpen.toggle()
        #expect(ConversationSplit.isShown(hasThread: true, isOpen: isOpen, isBothFolded: false))
        isOpen.toggle()
        #expect(!ConversationSplit.isShown(hasThread: true, isOpen: isOpen, isBothFolded: false))
    }

    @Test func aNewCaseStartsClosedAgain() {
        // A new case is a new pane with a fresh `isOpen == false`: whatever the last case had.
        let previousCaseOpen = true
        #expect(ConversationSplit.isShown(hasThread: true, isOpen: previousCaseOpen, isBothFolded: false))
        let nextCaseOpen = false
        #expect(!ConversationSplit.isShown(hasThread: true, isOpen: nextCaseOpen, isBothFolded: false))
    }

    @Test func noColumnWithoutAThreadOrWhileBothSidesAreFolded() {
        #expect(!ConversationSplit.isShown(hasThread: false, isOpen: true, isBothFolded: false))
        #expect(!ConversationSplit.isShown(hasThread: true, isOpen: true, isBothFolded: true))
    }

    private let utc = TimeZone(identifier: "UTC")!
    private func iso(_ hhmm: String) -> String { "2026-09-29T\(hhmm):00.000Z" }

    private func twoRoundDetail() -> CaseDetail {
        let c = Case(
            id: "c1", taskId: "t1", kind: .review, title: "Do the screens match?", need: "Review the screens.",
            why: "W", recommendation: "a", recommendationWhy: "RW",
            options: [Option(id: "a", label: "A · Approve"), Option(id: "b", label: "B · Changes needed")],
            status: .needsYou, hasArtifact: true, taskName: "OME-534", project: "app",
            createdAt: iso("21:10"), updatedAt: iso("21:24"))
        let capture = Capture(id: "cap", revision: 1, pngBase64: "", annotatedPngBase64: "", takenAt: iso("21:23"), note: nil)
        let comment = Comment(id: "cm", captureId: "cap", n: 1, rect: Rect(x: 0, y: 0, w: 1, h: 1), text: "t")
        let reply = Reply(
            id: "r1", caseId: "c1", idempotencyKey: "r1", choice: "b", message: "Why both links?", comments: [comment],
            captures: [capture], intent: .decision, state: .delivered, createdAt: iso("21:23"), deliveredAt: iso("21:23"))
        return CaseDetail(
            case: c, task: KnockTask(id: "t1", name: "OME-534", project: "app"),
            messages: [Message(id: "m1", caseId: "c1", role: .agent, text: "They overlap.", createdAt: iso("21:24"))],
            revisions: [
                Revision(id: "v1", caseId: "c1", n: 1, createdAt: iso("21:10")),
                Revision(id: "v2", caseId: "c1", n: 2, createdAt: iso("21:24"))],
            comments: [comment], replies: [reply])
    }

    @Test func collapsesBelowEightHundredPoints() {
        #expect(ConversationSplit.isCollapsed(paneWidth: 799.5))
        #expect(!ConversationSplit.isCollapsed(paneWidth: 800))
        #expect(!ConversationSplit.isCollapsed(paneWidth: 876), "a 1512 pt laptop screen keeps the split")
        #expect(!ConversationSplit.isCollapsed(paneWidth: 1200))
    }

    @Test func aFreshAskHasNoConversation() {
        var d = twoRoundDetail()
        d = CaseDetail(case: d.case, task: d.task, messages: [], revisions: d.revisions, comments: [], replies: [])
        #expect(d.threadModel() == nil)
    }

    @Test func theColumnExistsOnlyFromTheSecondRound() throws {
        let two = twoRoundDetail()
        #expect(ConversationSplit.hasColumn(thread: two.threadModel()))
        let one = CaseDetail(case: two.case, task: two.task, messages: [], revisions: two.revisions, comments: [], replies: [])
        #expect(!ConversationSplit.hasColumn(thread: one.threadModel()))
        // No thread means no icon and no column, even if the open flag were set.
        #expect(!ConversationSplit.isShown(
            hasThread: ConversationSplit.hasColumn(thread: one.threadModel()), isOpen: true, isBothFolded: false))
    }

    @Test func messageListIsAskReplyUpdateInOrder() throws {
        let model = try #require(twoRoundDetail().threadModel())
        #expect(model.steps.count == 3)
        guard case .asked = model.steps[0], case .replied = model.steps[1], case .updated = model.steps[2] else {
            Issue.record("wrong order"); return
        }
        #expect(model.roundCount == 2)
        #expect(ConversationCopy.title(model) == "CONVERSATION · 2 ROUNDS")
        #expect(ConversationCopy.roundBadge(model.roundCount) == "2")
        #expect(ConversationCopy.iconHelp == "Conversation (⌘ ])")
    }

    @Test func headersUseTheDesignWords() throws {
        let model = try #require(twoRoundDetail().threadModel())
        guard case .asked(let asked) = model.steps[0], case .replied(let replied) = model.steps[1],
              case .updated(let updated) = model.steps[2] else { Issue.record("wrong steps"); return }
        #expect(ConversationCopy.askedHeader(asked, runtime: "Claude Code", timeZone: utc) == "CLAUDE CODE · 21:10")
        #expect(ConversationCopy.repliedHeader(replied, timeZone: utc) == "YOU · 21:23 · 1 comment on v1")
        #expect(ConversationCopy.updatedHeader(updated, runtime: "Claude Code", timeZone: utc) == "CLAUDE CODE · 21:24 · v2")
        #expect(ConversationCopy.pickedUpLine(try #require(replied.pickedUp), timeZone: utc) == "✓ picked up 21:23 · worked 1m")
        #expect(ConversationCopy.priorVersionLink(updated) == "v1 · see in review")
    }

    @Test func turnLabelDropsTheHintWhileItIsYourTurn() {
        let yours = ThreadTurn(status: .needsYou, label: "Your turn: approve v2 or ask for changes", since: nil)
        #expect(ConversationCopy.turnLabel(yours) == "Your turn")
        let working = ThreadTurn(status: .working, label: "Claude Code is working", since: nil)
        #expect(ConversationCopy.turnLabel(working) == "Claude Code is working")
    }

    @Test func previewChipDropsTheVersionFromTheMeta() {
        #expect(ArtifactPreviewCard.metaWithoutVersion("v2 · still preview", revision: 2) == "still preview")
        #expect(ArtifactPreviewCard.metaWithoutVersion("v2", revision: 2) == "")
    }
}
