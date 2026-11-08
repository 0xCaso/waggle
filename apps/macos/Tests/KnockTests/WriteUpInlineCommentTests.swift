import XCTest
@testable import Knock

/// WAG-322: select-to-comment in the inline changes view. A comment anchors to the new version's source;
/// removed words are shown but are not part of it.
final class WriteUpInlineCommentTests: XCTestCase {
    private let old = "# Spec\n\nThe nearest current allowed value wins.\n\n- keep this\n- drop this item\n"
    private let new = "# Spec\n\nThe nearest allowed value wins, always.\n\n- keep this\n\nA brand new closing sentence.\n"

    private func marked() -> RenderedMarkdown {
        RenderedMarkdown.parse(new).markingChanges(WriteUpDiff.diff(old: old, new: new))
    }

    private func anchor(_ doc: RenderedMarkdown, selecting phrase: String) -> String? {
        guard let r = doc.string.range(of: phrase) else { return nil }
        let ns = NSRange(r, in: doc.string)
        return doc.sourceRange(forRendered: ns.location..<(ns.location + ns.length)).map { doc.quote(forSource: $0) }
    }

    func testRemovedWordsShowInPlaceAndAddedWordsAreMarked() {
        let doc = marked()
        XCTAssertTrue(doc.string.contains("nearest current allowed"), doc.string)
        let current = (doc.string as NSString).range(of: "current")
        XCTAssertTrue(doc.styles[current.location].contains(.removed))
        XCTAssertEqual(doc.source[current.location], -1)
        let always = (doc.string as NSString).range(of: "always")
        XCTAssertTrue(doc.styles[always.location].contains(.added))
        XCTAssertGreaterThanOrEqual(doc.source[always.location], 0)
    }

    func testCommentOnAddedSentenceAnchorsToTheNewSource() throws {
        let doc = marked()
        let quote = try XCTUnwrap(anchor(doc, selecting: "A brand new closing sentence."))
        XCTAssertEqual(quote, "A brand new closing sentence.")
        let range = try XCTUnwrap(doc.sourceText.count > 0 ? (new as NSString).range(of: quote) : nil)
        let src = try XCTUnwrap(doc.sourceRange(forRendered: (doc.string as NSString).range(of: quote).location..<((doc.string as NSString).range(of: quote).location + range.length)))
        XCTAssertEqual(src, range.location..<(range.location + range.length))
        // The saved range lands back on the same characters.
        let back = try XCTUnwrap(doc.renderedRange(forSource: src))
        XCTAssertEqual((doc.string as NSString).substring(with: NSRange(location: back.lowerBound, length: back.count)), quote)
    }

    func testSelectionOverRemovedWordsAnchorsToNewTextOnly() throws {
        let doc = marked()
        XCTAssertEqual(anchor(doc, selecting: "nearest current allowed value"), "nearest allowed value")
        XCTAssertNil(anchor(doc, selecting: "current "))
    }

    func testRemovedBlockIsShownAndNotCommentable() {
        let doc = marked()
        XCTAssertTrue(doc.string.contains("drop this item"))
        XCTAssertNil(anchor(doc, selecting: "drop this item"))
        XCTAssertEqual(anchor(doc, selecting: "keep this"), "keep this")
    }

    func testBlocksCarryTheirEntryAndTheBar() {
        let doc = marked()
        let entries = WriteUpDiff.diff(old: old, new: new).entries
        XCTAssertEqual(Set(doc.blocks.compactMap(\.entry)), Set(entries.indices))
        XCTAssertEqual(doc.blocks.filter(\.marked).compactMap(\.entry).sorted(), entries.indices.filter { entries[$0].change != .unchanged })
        // The blocks still tile the text.
        var at = 0
        for block in doc.blocks { XCTAssertEqual(block.range.lowerBound, at); at = block.range.upperBound }
        XCTAssertEqual(at, doc.text.count)
    }

    func testMapsStayTheSameLength() {
        let doc = marked()
        XCTAssertEqual(doc.text.count, doc.source.count)
        XCTAssertEqual(doc.text.count, doc.styles.count)
        XCTAssertEqual(doc.text.count, doc.linkIndex.count)
    }

    func testNoChangesLeavesThePlainMap() {
        let plain = RenderedMarkdown.parse(new)
        let doc = plain.markingChanges(WriteUpDiff.diff(old: new, new: new))
        XCTAssertEqual(doc.text, plain.text)
        XCTAssertEqual(doc.source, plain.source)
    }
}
