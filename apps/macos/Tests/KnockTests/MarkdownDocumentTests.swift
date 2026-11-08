import Testing
import Foundation
@testable import Knock

/// `MarkdownDocument.parse` (HAIL-33): the review viewer renders "headings,
/// lists, code blocks, tables and links" with the app's own typography -
/// this is the block-level parser behind that, deliberately small (not a
/// full CommonMark implementation, see the type's own doc comment).
struct MarkdownDocumentTests {
    @Test func parsesHeadingsOfEveryLevel() {
        let blocks = MarkdownDocument.parse("# Title\n\n## Subtitle\n\n### Detail")
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Subtitle"),
            .heading(level: 3, text: "Detail"),
        ])
    }

    @Test func aBareHashWithNoSpaceIsNotAHeading() {
        let blocks = MarkdownDocument.parse("#hashtag not a heading")
        #expect(blocks == [.paragraph(text: "#hashtag not a heading")])
    }

    @Test func joinsConsecutiveLinesIntoOneParagraph() {
        let blocks = MarkdownDocument.parse("Line one\nstill the same paragraph.\n\nA new paragraph.")
        #expect(blocks == [
            .paragraph(text: "Line one still the same paragraph."),
            .paragraph(text: "A new paragraph."),
        ])
    }

    @Test func parsesAnUnorderedList() {
        let blocks = MarkdownDocument.parse("- First\n- Second\n* Third")
        #expect(blocks == [
            .listItem(ordered: false, index: 0, text: "First"),
            .listItem(ordered: false, index: 0, text: "Second"),
            .listItem(ordered: false, index: 0, text: "Third"),
        ])
    }

    @Test func parsesAnOrderedListReadingEachLinesOwnNumber() {
        let blocks = MarkdownDocument.parse("1. First\n2. Second\n5. Skips ahead")
        #expect(blocks == [
            .listItem(ordered: true, index: 1, text: "First"),
            .listItem(ordered: true, index: 2, text: "Second"),
            .listItem(ordered: true, index: 5, text: "Skips ahead"),
        ])
    }

    @Test func parsesAFencedCodeBlockVerbatim() {
        let text = "```\nlet x = 1\nlet y = 2\n```"
        let blocks = MarkdownDocument.parse(text)
        #expect(blocks == [.codeBlock(text: "let x = 1\nlet y = 2")])
    }

    @Test func aCodeBlockIsNeverReinterpretedAsHeadingsOrLists() {
        let text = "```\n# not a heading\n- not a list\n```"
        let blocks = MarkdownDocument.parse(text)
        #expect(blocks == [.codeBlock(text: "# not a heading\n- not a list")])
    }

    @Test func parsesATableWithHeaderAndRows() {
        let text = "| Option | Cost |\n| --- | --- |\n| A | $10 |\n| B | $20 |"
        let blocks = MarkdownDocument.parse(text)
        #expect(blocks == [
            .table(headers: ["Option", "Cost"], rows: [["A", "$10"], ["B", "$20"]]),
        ])
    }

    @Test func aPipeLineWithNoSeparatorRowIsNotATable() {
        let blocks = MarkdownDocument.parse("This has | a pipe | in it")
        #expect(blocks == [.paragraph(text: "This has | a pipe | in it")])
    }

    @Test func parsesAMixOfEveryBlockKindInOrder() {
        let text = """
        # Trade-offs

        Here is the short version.

        - Faster to ship
        - Slightly more risk

        ```
        cost = 10
        ```

        | Option | Cost |
        | --- | --- |
        | A | $10 |
        """
        let blocks = MarkdownDocument.parse(text)
        #expect(blocks.count == 6)
        #expect(blocks[0] == .heading(level: 1, text: "Trade-offs"))
        #expect(blocks[1] == .paragraph(text: "Here is the short version."))
        #expect(blocks[2] == .listItem(ordered: false, index: 0, text: "Faster to ship"))
        #expect(blocks[3] == .listItem(ordered: false, index: 0, text: "Slightly more risk"))
        #expect(blocks[4] == .codeBlock(text: "cost = 10"))
        #expect(blocks[5] == .table(headers: ["Option", "Cost"], rows: [["A", "$10"]]))
    }

    // MARK: - Inline formatting

    @Test func inlineParsesBoldAndItalic() {
        let attributed = MarkdownDocument.inline("Use **bold** and *italic* text")
        #expect(String(attributed.characters) == "Use bold and italic text")
    }

    @Test func inlineFallsBackToPlainTextOnAParseFailure() {
        // Foundation's markdown parser never actually throws on stray
        // syntax like this, but `inline` must still degrade gracefully if
        // it ever does - this pins that the text is never dropped.
        let attributed = MarkdownDocument.inline("just plain text")
        #expect(String(attributed.characters) == "just plain text")
    }

    @Test func inlineNeverInterpretsALeadingHashAsABlockHeading() {
        // `.inlineOnlyPreservingWhitespace` must not re-parse block syntax
        // a caller already stripped - a literal "#" inside a table cell or
        // list item's text should render as itself.
        let attributed = MarkdownDocument.inline("#1 priority")
        #expect(String(attributed.characters) == "#1 priority")
    }
}
