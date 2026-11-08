import XCTest
@testable import Knock

final class PageViewTests: XCTestCase {
    private func view(_ hash: String, _ text: String) -> PageView { PageView.make(hash: hash, text: text) }

    func testFingerprintIgnoresWhitespaceAndIsStable() {
        XCTAssertEqual(PageView.fingerprint(ofText: "Pricing  plans\n\n Pro"), PageView.fingerprint(ofText: " Pricing plans Pro "))
        XCTAssertNotEqual(PageView.fingerprint(ofText: "Pricing"), PageView.fingerprint(ofText: "Settings"))
        XCTAssertEqual(PageView.fingerprint(ofText: "abc"), "e71fa2190541574b")
        XCTAssertEqual(PageView.fingerprint(ofText: "  \n "), "")
    }

    func testMakeStripsTheLeadingHash() {
        XCTAssertEqual(view("#a", "x").hash, "a")
        XCTAssertEqual(view("", "x").hash, "")
    }

    func testHashRuleWinsWhenTheCommentHasAHash() {
        let comment = view("#a", "same text")
        XCTAssertTrue(PageView.shows(comment: comment, current: view("#a", "other text")))
        XCTAssertFalse(PageView.shows(comment: comment, current: view("#b", "same text")))
        XCTAssertFalse(PageView.shows(comment: comment, current: view("", "same text")))
    }

    func testFingerprintRuleWhenTheCommentHasNoHash() {
        let comment = view("", "tab one")
        XCTAssertTrue(PageView.shows(comment: comment, current: view("", "tab one")))
        XCTAssertFalse(PageView.shows(comment: comment, current: view("", "tab two")))
    }

    func testOldCommentsAndUnreadViewsAlwaysShow() {
        XCTAssertTrue(PageView.shows(comment: nil, current: view("#b", "x")))
        XCTAssertTrue(PageView.shows(comment: view("#a", "x"), current: nil))
        XCTAssertTrue(PageView.shows(comment: PageView(hash: "", fingerprint: ""), current: view("#b", "x")))
    }

    func testModelStoresTheViewPerCaptureAndCountsOffViewComments() {
        var model = CommentsModel()
        let a = model.addCapture(revision: 1, view: view("#a", "A"))
        let b = model.addCapture(revision: 1, view: view("#b", "B"))
        let old = model.addCapture(revision: 1)
        let rect = Rect(x: 0.1, y: 0.1, w: 0.1, h: 0.1)
        let onA = model.addComment(captureId: a.id, rect: rect, text: "a")
        let onB = model.addComment(captureId: b.id, rect: rect, text: "b")
        let legacy = model.addComment(captureId: old.id, rect: rect, text: "old")
        XCTAssertEqual(model.view(of: onA)?.hash, "a")
        XCTAssertNil(model.view(of: legacy))
        XCTAssertEqual(model.commentsOffView(onRevision: 1, current: view("#a", "A")).map(\.id), [onB.id])
        XCTAssertEqual(model.commentsOffView(onRevision: 1, current: view("#b", "B")).map(\.id), [onA.id])
        XCTAssertEqual(model.commentsOffView(onRevision: 1, current: nil).count, 0)
        // Deleting a capture renumbers the others and keeps their views.
        model.deleteCapture(id: a.id)
        XCTAssertEqual(model.captures.first?.view?.hash, "b")
    }
}
