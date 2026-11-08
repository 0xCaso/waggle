import XCTest
@testable import Knock

final class WriteUpDiffTests: XCTestCase {
    private let v7 = """
    # Spec

    ## Goal

    Show the month in the URL.

    ## Cases

    - Case 1: a month inside the limits
    - Case 2: no month

    ## Risks

    The date picker is slow on old machines.
    """

    func testNoChange() {
        let result = WriteUpDiff.diff(old: v7, new: v7)
        XCTAssertTrue(result.isUnchanged)
        XCTAssertEqual(result.summary(since: 7), "Nothing changed since v7.")
        XCTAssertTrue(result.sections.allSatisfy { $0.status == .unchanged })
    }

    func testAddedSectionAndChangedParagraph() {
        let v8 = v7
            .replacingOccurrences(of: "Show the month in the URL.", with: "Show the month in the URL and keep it on reload.")
            + "\n\n## Checks\n\nA check at 320 px.\n"
        let result = WriteUpDiff.diff(old: v7, new: v8)
        XCTAssertEqual(result.changedCount, 1)
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.summary(since: 7), "1 section changed, 1 added")
        let changed = result.sections.flatMap(\.entries).first { $0.change == .changed }
        XCTAssertEqual(changed?.unit.text, "Show the month in the URL and keep it on reload.")
        let segments = changed?.segments ?? []
        XCTAssertEqual(segments.filter { $0.kind == .added }.map { $0.text.trimmingCharacters(in: .whitespaces) }, ["and keep it on reload"])
        XCTAssertTrue(segments.filter { $0.kind == .removed }.isEmpty)
        XCTAssertEqual(segments.filter { $0.kind != .removed }.map(\.text).joined(), "Show the month in the URL and keep it on reload.")
    }

    func testRemovedBlock() {
        let v8 = v7.replacingOccurrences(of: "- Case 2: no month\n", with: "")
        let result = WriteUpDiff.diff(old: v7, new: v8)
        let removed = result.sections.flatMap(\.entries).filter { $0.change == .removed }
        XCTAssertEqual(removed.map(\.unit.text), ["Case 2: no month"])
        XCTAssertEqual(result.summary(since: 7), "1 section changed")
    }

    func testChangedListItemKeepsItsPlace() {
        let v8 = v7.replacingOccurrences(of: "Case 2: no month", with: "Case 2: no month at all")
        let entries = WriteUpDiff.diff(old: v7, new: v8).sections.flatMap(\.entries)
        XCTAssertEqual(entries.filter { $0.change == .changed }.count, 1)
        XCTAssertEqual(entries.filter { $0.change == .added || $0.change == .removed }.count, 0)
    }

    func testMovedSectionIsNotRemovedAndAdded() {
        let v8 = """
        # Spec

        ## Risks

        The date picker is slow on old machines.

        ## Goal

        Show the month in the URL.

        ## Cases

        - Case 1: a month inside the limits
        - Case 2: no month
        """
        let entries = WriteUpDiff.diff(old: v7, new: v8).sections.flatMap(\.entries)
        XCTAssertFalse(entries.contains { $0.change == .added || $0.change == .removed || $0.change == .changed })
        XCTAssertTrue(entries.contains { $0.change == .moved })
        XCTAssertFalse(WriteUpDiff.diff(old: v7, new: v8).isUnchanged)
    }

    func testTableRowsDiffByRow() {
        let old = "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
        let new = "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |"
        let entries = WriteUpDiff.diff(old: old, new: new).sections.flatMap(\.entries)
        XCTAssertEqual(entries.filter { $0.change == .added }.map(\.unit.text), ["5 | 6"])
        XCTAssertEqual(entries.filter { $0.change == .unchanged }.count, 3)
    }

    func testUnrelatedParagraphIsRemovedAndAdded() {
        let entries = WriteUpDiff.diff(old: "One two three four.", new: "Completely different words here.").sections.flatMap(\.entries)
        XCTAssertEqual(entries.map(\.change), [.removed, .added])
    }

    func testWordSegmentsShowRemovedWords() {
        let segments = WriteUpDiff.words(old: "keep the old limit", new: "keep the new limit")
        XCTAssertEqual(segments.map(\.kind), [.same, .removed, .added, .same])
        XCTAssertEqual(segments[1].text, "old ")
        XCTAssertEqual(segments[2].text, "new ")
    }

    func testSummaryPlainCounts() {
        let old = "## A\n\nOne.\n\n## B\n\nTwo.\n\n## C\n\nThree."
        let new = "## A\n\nOne more.\n\n## B\n\nTwo more.\n\n## C\n\nThree more.\n\n## D\n\nNew."
        XCTAssertEqual(WriteUpDiff.diff(old: old, new: new).summary(since: 3), "3 sections changed, 1 added")
    }
}
