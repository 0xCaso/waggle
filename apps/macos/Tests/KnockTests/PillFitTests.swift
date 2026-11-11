import Testing
import CoreGraphics
@testable import Knock

/// WAG-411: the quick replies. The chip row is gone (C5): they sit at the top of the "Ask for…" panel.
struct PillFitTests {
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
