import Testing
@testable import Knock

/// HAIL-147: the words of a "more detail" request, shared by the thread and the delivery banner.
struct MoreDetailCopyTests {
    @Test func chipOrFreeTextOnly() {
        #expect(MoreDetailCopy.banner(format: nil, message: "Show me a prototype") == "Asked for more detail · Show me a prototype")
        #expect(MoreDetailCopy.thread(format: nil, message: "Show me a prototype") == "Asked for more detail\n\nShow me a prototype")
    }

    @Test func formatOnly() {
        #expect(MoreDetailCopy.banner(format: .diagram, message: nil) == "Asked for more detail · as a diagram")
        #expect(MoreDetailCopy.thread(format: .eli5, message: nil) == "Asked for more detail · like I'm five")
    }

    @Test func formatAndText() {
        #expect(MoreDetailCopy.banner(format: .diagram, message: "Show me") == "Asked for more detail · as a diagram · Show me")
        #expect(MoreDetailCopy.thread(format: .diagram, message: "Show me") == "Asked for more detail · as a diagram\n\nShow me")
    }

    @Test func neitherReadsAsALeadNeverEmpty() {
        #expect(MoreDetailCopy.banner(format: nil, message: nil) == "Asked for more detail")
        #expect(MoreDetailCopy.banner(format: nil, message: "  \n ") == "Asked for more detail")
    }

    @Test func bubbleNeverShowsAnEmptyYou() {
        #expect(DeliveryBubbleCopy.text(for: "") == "You: your reply")
        #expect(DeliveryBubbleCopy.text(for: "  ") == "You: your reply")
    }

    @Test func decisionSummaryIsUnchanged() {
        #expect(DeliveryBubbleCopy.text(for: "Go with A. Two fixes") == "You: Go with A. Two fixes")
    }
}
