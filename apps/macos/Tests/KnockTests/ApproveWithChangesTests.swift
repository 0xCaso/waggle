import Foundation
import Testing
@testable import Knock

/// WAG-353: a chosen option plus text reads as "approve with changes".
@Suite(.serialized)
@MainActor
struct ApproveWithChangesTests {
    private let approve = Option(id: "approve", label: "Approve: ship it", title: "Approve")
    private let changes = Option(id: "request_changes", label: "Request changes", title: "Request changes")
    private let compact = Option(id: "a", label: "Compact layout", title: "Compact")

    private func makeCase(kind: Case.Kind = .review, options: [Option]? = nil) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: kind, title: "Ship it?", need: "Need", why: "Why",
            recommendation: "approve", recommendationWhy: "Because", options: options ?? [approve, changes, compact],
            status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-10T10:00:00Z", updatedAt: "2026-10-10T10:00:00Z")
    }

    private func composer(pick: String?, text: String) -> ComposerViewModel {
        let model = ComposerViewModel(knockCase: makeCase(), draftStore: ComposerDraftStore())
        model.selectedOptionId = pick
        model.draftText = text
        return model
    }

    @Test func kindOfTheChosenOption() {
        #expect(WithChanges.kind(of: approve) == .approve)
        #expect(WithChanges.kind(of: compact) == .decide)
        #expect(WithChanges.kind(of: changes) == nil)
        #expect(WithChanges.kind(of: compact, planStage: .design) == .approve)
        #expect(WithChanges.kind(of: compact, planStage: .approaches) == .decide)
        #expect(WithChanges.kind(of: Option(id: "x", label: "Change the layout", title: "Change the layout"), planStage: .design) == nil)
    }

    @Test func theButtonMatrix() {
        // Approval option with text.
        #expect(composer(pick: "approve", text: "Also fix X").withChangesKind == .approve)
        // Other option with text.
        #expect(composer(pick: "a", text: "Also fix X").withChangesKind == .decide)
        // Request changes keeps its meaning.
        #expect(composer(pick: "request_changes", text: "Fix X").withChangesKind == nil)
        // No option chosen.
        #expect(composer(pick: nil, text: "Fix X").withChangesKind == nil)
        // No text, or blank text: the button reads as before.
        #expect(composer(pick: "approve", text: "").withChangesKind == nil)
        #expect(composer(pick: "approve", text: "  \n ").withChangesKind == nil)
    }

    @Test func labelsWithAndWithoutComments() {
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, withChanges: .approve) == ["Approve with changes", "Approve"])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, withChanges: .decide) == ["Decide with changes", "Decide"])
        #expect(
            PromptBarLogic.sendPillLabels(commentCount: 2, withChanges: .approve)
                == ["Approve with changes + 2 comments", "Approve with changes", "Approve"])
        #expect(
            PromptBarLogic.sendPillLabels(commentCount: 1, decideTitle: "Compact", withChanges: .decide)
                == ["Decide with changes + 1 comment", "Decide with changes", "Decide"])
    }

    @Test func noKindKeepsTheOldWords() {
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, decideTitle: "Compact") == ["Decide"])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, planLabel: "Approve section") == ["Approve section"])
        // An edit keeps its own mark.
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, hasEdit: true, withChanges: .approve).first == "Send + edit")
    }

    @Test func aNarrowRowNeverCutsTheButton() {
        let forms = PromptBarLogic.sendPillLabels(commentCount: 2, withChanges: .approve)
        let narrow = PromptBarLogic.controlsPlan(rowWidth: 300, quietLabels: ["Ask for more detail"], pillLabels: forms)
        let shown = narrow.sendPillLabel
        #expect(shown != nil && forms.contains(shown!))
        #expect(narrow.width <= 300 - PromptBarLogic.controlSize - PromptBarLogic.controlGap || narrow.ownRow)
        let tight = PromptBarLogic.controlsPlan(rowWidth: 200, quietLabels: ["Ask for more detail"], pillLabels: forms)
        #expect(tight.sendPillLabel == "Approve")
    }

    @Test func answeredWords() {
        func answered(choice: String, message: String?, intent: ReplyIntent? = .decision) -> Case {
            Case(
                id: "a", taskId: "t", kind: .review, title: "T", need: "N", why: "W", recommendation: "approve",
                recommendationWhy: "RW", options: [approve, changes, compact],
                status: .waitingOnAgent, hasArtifact: true, latestReplyId: "r1", latestReplyState: .queued,
                latestReplyAt: "2026-10-10T13:02:00Z", latestReplyChoice: choice, latestReplyMessage: message,
                latestReplyIntent: intent, createdAt: "2026-10-10T11:00:00Z", updatedAt: "2026-10-10T13:02:00Z")
        }
        let a = answered(choice: "approve", message: "Rename the tab")
        #expect(a.latestReplyWithChangesWords == "Approved with changes")
        #expect(SentAnswerCopy.answer(for: a) == .init(label: "YOU PICKED", title: "Approved with changes", note: "Rename the tab"))
        #expect(a.answeredSummaryLine == "you → Approved with changes · Rename the tab")
        #expect(answered(choice: "a", message: "Use blue").latestReplyWithChangesWords == "Compact, with changes")
        #expect(answered(choice: "a", message: "Use blue").lastAnswerShortTitle == "Compact, with changes")
        #expect(answered(choice: "request_changes", message: "Fix").latestReplyWithChangesWords == nil)
        #expect(answered(choice: "approve", message: nil).latestReplyWithChangesWords == nil)
        #expect(answered(choice: "approve", message: " ").latestReplyWithChangesWords == nil)
        #expect(answered(choice: "approve", message: "Q?", intent: .discuss).latestReplyWithChangesWords == nil)
        #expect(SentAnswerCopy.answer(for: answered(choice: "approve", message: nil)).title == "1 · Approve")
    }
}
