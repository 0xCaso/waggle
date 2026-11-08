import Testing
import CoreGraphics
@testable import Knock

/// WAG-411: the chip row never drops a chip. It scrolls, and fades the side that has more.
struct PillFitTests {
    @Test func noFadeWhenEverythingFits() {
        let fades = ChipRowEdges.fades(offset: 0, content: 400, container: 500)
        #expect(!fades.leading && !fades.trailing)
    }

    @Test func noFadeBeforeTheWidthIsKnown() {
        let fades = ChipRowEdges.fades(offset: 0, content: 800, container: 0)
        #expect(!fades.leading && !fades.trailing)
    }

    @Test func fadeOnTheEndAtTheStart() {
        let fades = ChipRowEdges.fades(offset: 0, content: 800, container: 400)
        #expect(!fades.leading && fades.trailing)
    }

    @Test func fadeOnBothSidesInTheMiddle() {
        let fades = ChipRowEdges.fades(offset: 150, content: 800, container: 400)
        #expect(fades.leading && fades.trailing)
    }

    @Test func fadeOnTheStartAtTheEnd() {
        let fades = ChipRowEdges.fades(offset: 400, content: 800, container: 400)
        #expect(fades.leading && !fades.trailing)
    }

    @Test func aTypedDraftStaysBeforeTheQuickReply() {
        #expect(QuickReply.message(draft: nil, reply: .letsDiscuss) == "Let's discuss")
        #expect(QuickReply.message(draft: "  \n", reply: .showMeMore) == "Show me more")
        #expect(QuickReply.message(draft: "Use the socket.", reply: .letsDiscuss) == "Use the socket.\nLet's discuss")
        #expect(QuickReply.message(draft: nil, reply: .lookAtMyComments) == "Look at my comments and act on each one.")
    }

    @Test func theChipsComeInOrderAndLookAtMyCommentsNeedsComments() {
        #expect(QuickReply.visible(hasComments: false).map(\.label) == ["Let's discuss", "Show me more"])
        #expect(QuickReply.visible(hasComments: true).map(\.label) == ["Let's discuss", "Look at my comments", "Show me more"])
    }

    @MainActor @Test func eachQuickReplyWritesACodeOnlyUsageWord() {
        #expect(QuickReply.allCases.map(\.usageName) == ["lets_discuss", "my_comments", "show_more"])
        let recorder = UsageRecorder()
        let before = UsageReporter.current
        UsageReporter.current = recorder.reporter
        defer { UsageReporter.current = before }
        for reply in QuickReply.allCases { reply.report() }
        #expect(recorder.records.map(\.event) == [.quickReplyPicked, .quickReplyPicked, .quickReplyPicked])
        #expect(recorder.records.map(\.variant) == ["lets_discuss", "my_comments", "show_more"])
    }
}
