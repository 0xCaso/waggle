import XCTest
@testable import Knock

/// HAIL-150: rendered selection <-> markdown source offsets, as pure code.
final class MarkdownSourceMapTests: XCTestCase {
    /// The source text a selection of `phrase` (found in the rendered string) maps to.
    private func quote(_ source: String, selecting phrase: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let doc = RenderedMarkdown.parse(source)
        guard let r = doc.string.range(of: phrase) else {
            XCTFail("rendered text \(doc.string.debugDescription) lacks \(phrase)", file: file, line: line)
            return nil
        }
        let ns = NSRange(r, in: doc.string)
        guard let src = doc.sourceRange(forRendered: ns.location..<(ns.location + ns.length)) else { return nil }
        return doc.quote(forSource: src)
    }

    func testPlainParagraphMapsOneToOne() {
        let md = "Hello there, world."
        let doc = RenderedMarkdown.parse(md)
        XCTAssertEqual(doc.string, md)
        XCTAssertEqual(quote(md, selecting: "there"), "there")
    }

    func testBoldKeepsInnerMarksButDropsEdgeMarks() {
        let md = "A **bold move** here."
        XCTAssertEqual(RenderedMarkdown.parse(md).string, "A bold move here.")
        XCTAssertEqual(quote(md, selecting: "bold move"), "bold move")
        XCTAssertEqual(quote(md, selecting: "A bold"), "A **bold")
        XCTAssertEqual(quote(md, selecting: "bold move here."), "bold move** here.")
    }

    func testItalicsAndUnderscores() {
        let md = "An *italic* and _under_ test, snake_case stays."
        let doc = RenderedMarkdown.parse(md)
        XCTAssertEqual(doc.string, "An italic and under test, snake_case stays.")
        XCTAssertEqual(quote(md, selecting: "italic and under"), "italic* and _under")
    }

    func testInlineCode() {
        let md = "Run `bun test` now."
        XCTAssertEqual(RenderedMarkdown.parse(md).string, "Run bun test now.")
        XCTAssertEqual(quote(md, selecting: "bun test"), "bun test")
        XCTAssertEqual(quote(md, selecting: "Run bun"), "Run `bun")
    }

    func testListItemsSkipTheBulletAndNumber() {
        let md = "- first item\n- second **item**\n3. third"
        let doc = RenderedMarkdown.parse(md)
        XCTAssertEqual(doc.string, "•\tfirst item\n•\tsecond item\n3.\tthird")
        XCTAssertEqual(quote(md, selecting: "first item"), "first item")
        // A selection that starts on the bullet starts at the first source character after it.
        let start = doc.string.startIndex
        let ns = NSRange(start..<doc.string.index(start, offsetBy: 12), in: doc.string)
        let src = doc.sourceRange(forRendered: ns.location..<(ns.location + ns.length))!
        XCTAssertEqual(doc.quote(forSource: src), "first item")
        XCTAssertEqual(quote(md, selecting: "item\n•\tsecond"), "item\n- second")
    }

    func testMultiParagraphSelection() {
        let md = "First paragraph here.\n\nSecond **paragraph** there.\n\n## A heading\n\nLast one."
        let doc = RenderedMarkdown.parse(md)
        XCTAssertEqual(doc.string, "First paragraph here.\nSecond paragraph there.\nA heading\nLast one.")
        XCTAssertEqual(
            quote(md, selecting: "here.\nSecond paragraph there."),
            "here.\n\nSecond **paragraph** there."
        )
        XCTAssertEqual(quote(md, selecting: "A heading"), "A heading")
    }

    func testSoftLineBreaksInAParagraphRenderAsSpaces() {
        let md = "one line\ntwo line\n   three line"
        let doc = RenderedMarkdown.parse(md)
        XCTAssertEqual(doc.string, "one line two line three line")
        XCTAssertEqual(quote(md, selecting: "line two"), "line\ntwo")
    }

    func testCodeBlockIsVerbatim() {
        let md = "Before\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nAfter"
        let doc = RenderedMarkdown.parse(md)
        XCTAssertEqual(doc.string, "Before\nlet a = 1\nlet b = 2\nAfter")
        XCTAssertEqual(quote(md, selecting: "a = 1\nlet b"), "a = 1\nlet b")
    }

    func testTableCells() {
        let md = "| Name | Value |\n| --- | --- |\n| a | **1** |"
        let doc = RenderedMarkdown.parse(md)
        XCTAssertEqual(doc.string, "Name\nValue\na\n1")
        XCTAssertEqual(quote(md, selecting: "1"), "1")
        XCTAssertEqual(doc.blocks.count, 4)
    }

    func testLinksKeepOnlyWebSchemesAndImagesStayText() {
        let doc = RenderedMarkdown.parse("See [the docs](https://example.com) and [x](javascript:alert(1)) and ![pic](http://e.com/a.png).")
        XCTAssertEqual(doc.links, [URL(string: "https://example.com")!])
        XCTAssertEqual(doc.string, "See the docs and [x](javascript:alert(1)) and ![pic](http://e.com/a.png).")
    }

    func testEscapesAndUnmatchedMarksStayLiteral() {
        let doc = RenderedMarkdown.parse("2 * 3 and \\*star\\* and **open")
        XCTAssertEqual(doc.string, "2 * 3 and *star* and **open")
    }

    func testSourceToRenderedRoundTrip() {
        let md = "Intro **bold text** outro."
        let doc = RenderedMarkdown.parse(md)
        let start = (md as NSString).range(of: "bold").location
        let r = doc.renderedRange(forSource: start..<(start + 4))!
        XCTAssertEqual((doc.string as NSString).substring(with: NSRange(location: r.lowerBound, length: r.count)), "bold")
        // A range that is all syntax marks has no rendered text.
        XCTAssertNil(doc.renderedRange(forSource: 6..<8))
    }

    func testSelectionOfOnlyWhitespaceOrBulletHasNoSource() {
        let doc = RenderedMarkdown.parse("- a")
        XCTAssertNil(doc.sourceRange(forRendered: 0..<2))
        XCTAssertNil(doc.sourceRange(forRendered: 0..<0))
    }

    func testOffsetsAreUTF16() {
        let md = "Emoji 😀 then **bold**"
        let doc = RenderedMarkdown.parse(md)
        guard let src = doc.sourceRange(forRendered: 0..<(doc.text.count)) else { return XCTFail() }
        XCTAssertEqual(src.upperBound, md.utf16.count - 2)
        XCTAssertEqual(doc.quote(forSource: src), "Emoji 😀 then **bold")
    }
}
