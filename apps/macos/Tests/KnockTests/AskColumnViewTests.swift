import Testing
@testable import Knock

/// `AskColumnView.commentsSummaryPrefix`: the Interact column's "N comments
/// on M captures · Show" line (HAIL-35 contract test list: "the footer
/// count" - this is that same total, read from the Interact side).
struct AskColumnViewTests {
    @Test func hidesTheLineWithNoCommentsYet() {
        #expect(AskColumnView.commentsSummaryPrefix(commentCount: 0, captureCount: 0) == nil)
    }

    @Test func singularWordingForOneCommentOnOneCapture() {
        #expect(AskColumnView.commentsSummaryPrefix(commentCount: 1, captureCount: 1) == "1 comment on 1 capture")
    }

    @Test func pluralWordingForMultipleCommentsAcrossMultipleCaptures() {
        #expect(AskColumnView.commentsSummaryPrefix(commentCount: 3, captureCount: 2) == "3 comments on 2 captures")
    }

    /// `captureCount` is always the session's total capture count (matches
    /// the Comment column's own grouping), not a "captures with comments"
    /// count - plural comments can still land on a singular capture.
    @Test func pluralCommentsSingularCapture() {
        #expect(AskColumnView.commentsSummaryPrefix(commentCount: 2, captureCount: 1) == "2 comments on 1 capture")
    }
}
