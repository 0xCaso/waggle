import Testing
@testable import Knock

struct MarkdownDocumentCardTests {
    @Test func readingTimeRoundsAndNeverDropsBelowOneMinute() {
        #expect(MarkdownDocumentCard.readingTime(for: "short") == "1 min read")
        let words = Array(repeating: "word", count: 660).joined(separator: " ")
        #expect(MarkdownDocumentCard.readingTime(for: words) == "3 min read")
    }
}
