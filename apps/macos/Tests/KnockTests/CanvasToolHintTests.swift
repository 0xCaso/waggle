import Testing
import Foundation
@testable import Knock

/// HAIL-58: the hover-card copy per tool and the "Drag to flag" tag rule.
struct CanvasToolHintTests {
    @Test func interactCardContent() {
        let hint = CanvasToolHint.content(for: .interact)
        #expect(hint.title == "Interact · I")
        #expect(hint.detail == "Click through it like a user.")
    }

    @Test func commentCardContent() {
        let hint = CanvasToolHint.content(for: .comment)
        #expect(hint.title == "Comment · C")
        #expect(hint.detail == "Drag over anything to flag it.")
    }

    @Test func hoverDelayIsAboutFourTenths() {
        #expect(CanvasToolHint.hoverDelay == 0.4)
    }

    @Test func cursorTagShowsOnlyInCommentModeBeforeTheFirstComment() {
        #expect(CommentCursorTag.isVisible(mode: .comment, hasPlacedComment: false))
        #expect(!CommentCursorTag.isVisible(mode: .comment, hasPlacedComment: true))
        #expect(!CommentCursorTag.isVisible(mode: .interact, hasPlacedComment: false))
        #expect(!CommentCursorTag.isVisible(mode: .interact, hasPlacedComment: true))
    }

    @Test func placedFlagPersistsInItsOwnDefaultsDomain() throws {
        let suite = "knock-hail58-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CommentCursorTag.defaultsKey == "review.hasPlacedComment")
        #expect(!CommentCursorTag.hasPlacedComment(defaults: defaults))
        CommentCursorTag.markPlaced(defaults: defaults)
        #expect(CommentCursorTag.hasPlacedComment(defaults: defaults))
    }

    @Test func evidenceHookParsing() {
        #expect(CanvasToolHintEvidence.pinnedTool(["KNOCK_EVIDENCE_TOOL_HINT": "comment"]) == .comment)
        #expect(CanvasToolHintEvidence.pinnedTool(["KNOCK_EVIDENCE_TOOL_HINT": "interact"]) == .interact)
        #expect(CanvasToolHintEvidence.pinnedTool(["KNOCK_EVIDENCE_TOOL_HINT": "cursor"]) == nil)
        #expect(CanvasToolHintEvidence.pinsCursorTag(["KNOCK_EVIDENCE_TOOL_HINT": "cursor"]))
        #expect(!CanvasToolHintEvidence.pinsCursorTag([:]))
    }
}
