import XCTest
@testable import Knock

/// WAG-307: comments on every screen. One list, one rule for which comments have a pin on screen,
/// and what Show does per anchor kind.
final class WAG307Tests: XCTestCase {
    private let rect = Rect(x: 0.2, y: 0.3, w: 0.1, h: 0.1)
    private func view(_ hash: String, _ text: String) -> PageView { PageView.make(hash: hash, text: text) }
    private let viewport = PageViewport(scrollX: 0, scrollY: 0, width: 800, height: 600)
    private let button = PageElementContext(role: "button", text: "Pay now", selector: "main > button", heading: "")

    private func live(revision: Int = 1, hash: String = "", text: String = "first", current: String = "first") -> (CommentsModel, Comment, CommentViewContext) {
        var model = CommentsModel()
        let capture = model.addCapture(revision: revision, page: viewport, view: view(hash, text))
        let comment = model.addComment(captureId: capture.id, rect: rect, text: "Make it blue")
        let context = CommentViewContext(kind: .htmlBundle, revision: revision, pageView: view(hash, current))
        return (model, comment, context)
    }

    // MARK: Which comments have a pin

    func testLiveCommentOnTheShownStateIsOnView() {
        let (model, comment, context) = live()
        XCTAssertEqual(CommentVisibility.placement(of: comment, model: model, context: context), .onView)
    }

    func testLiveCommentOnAStateThatIsGoneIsOtherView() {
        let (model, comment, context) = live(text: "second tab", current: "first tab")
        XCTAssertEqual(
            CommentVisibility.placement(of: comment, model: model, context: context),
            .otherView(.pageView(model.captures[0].view)))
    }

    func testLiveCommentOnAnotherRevisionIsOtherView() {
        let (model, comment, _) = live(revision: 1)
        let context = CommentViewContext(kind: .htmlBundle, revision: 2, pageView: nil)
        XCTAssertEqual(CommentVisibility.placement(of: comment, model: model, context: context), .otherView(.revision(1)))
    }

    func testTextCommentIsOnViewOnlyOnItsRevisionOfAWriteUp() {
        var model = CommentsModel()
        let comment = model.addTextComment(anchor: TextAnchor(revision: 2, quote: "the plan", start: 0, end: 8), text: "Why?")
        XCTAssertEqual(CommentVisibility.placement(of: comment, model: model, context: CommentViewContext(kind: .markdown, revision: 2)), .onView)
        XCTAssertEqual(
            CommentVisibility.placement(of: comment, model: model, context: CommentViewContext(kind: .markdown, revision: 3)),
            .otherView(.revision(2)))
        XCTAssertEqual(
            CommentVisibility.placement(of: comment, model: model, context: CommentViewContext(kind: .htmlBundle, revision: 2)),
            .otherView(.revision(2)))
    }

    func testScreenCommentIsOtherViewWhileAnotherScreenShows() {
        var model = CommentsModel()
        let one = model.addCapture(revision: 1)
        let two = model.addCapture(revision: 1)
        let onTwo = model.addComment(captureId: two.id, rect: rect, text: "Too tight")
        let showingOne = CommentViewContext(kind: .screenshots, revision: 1, shownCaptureId: one.id)
        XCTAssertEqual(CommentVisibility.placement(of: onTwo, model: model, context: showingOne), .otherView(.capture(two.id)))
        let showingTwo = CommentViewContext(kind: .screenshots, revision: 1, shownCaptureId: two.id)
        XCTAssertEqual(CommentVisibility.placement(of: onTwo, model: model, context: showingTwo), .onView)
        // A set view shows every screen.
        XCTAssertEqual(CommentVisibility.placement(of: onTwo, model: model, context: CommentViewContext(kind: .screenshots, revision: 1)), .onView)
    }

    func testUnknownContextKeepsEveryCommentOnView() {
        let (model, comment, _) = live()
        XCTAssertEqual(CommentVisibility.placement(of: comment, model: model, context: .unknown), .onView)
    }

    // MARK: Rows

    func testRowsCarryNumberTextAnchorAndState() {
        var model = CommentsModel()
        let first = model.addCapture(revision: 1, page: viewport)
        let second = model.addCapture(revision: 1, page: viewport)
        model.addComment(captureId: first.id, rect: rect, text: "One")
        model.addComment(captureId: second.id, rect: rect, text: "Two")
        model.addTextComment(anchor: TextAnchor(revision: 1, quote: "q", start: 0, end: 1), text: "Three")
        let list = CommentListModel.make(model: model, context: .unknown, isScreenshotsCase: false)
        XCTAssertEqual(list.rows.map(\.number), [1, 2, 3])
        XCTAssertEqual(list.rows.map(\.text), ["One", "Two", "Three"])
        XCTAssertEqual(list.rows.map(\.anchorLabel), ["Capture 1 · region", "Capture 2 · region", "On the span"])
        XCTAssertEqual(list.rows.map(\.state), [.saved, .saved, .saved])
    }

    func testOneCaptureSaysRegionAndAScreenSaysItsNumber() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        let comment = model.addComment(captureId: capture.id, rect: rect, text: "x")
        XCTAssertEqual(CommentAnchorLabel.make(comment: comment, model: model, isScreenshotsCase: false), "region")
        XCTAssertEqual(CommentAnchorLabel.make(comment: comment, model: model, isScreenshotsCase: true), "Screen 1 · region")
    }

    func testOffViewRowsListAfterTheOnesWithAPin() {
        var model = CommentsModel()
        let one = model.addCapture(revision: 1)
        let two = model.addCapture(revision: 1)
        model.addComment(captureId: two.id, rect: rect, text: "On two")
        model.addComment(captureId: one.id, rect: rect, text: "On one")
        let list = CommentListModel.make(
            model: model, context: CommentViewContext(kind: .screenshots, revision: 1, shownCaptureId: one.id), isScreenshotsCase: true)
        XCTAssertEqual(list.onView.map(\.text), ["On one"])
        XCTAssertEqual(list.otherViews.map(\.text), ["On two"])
        XCTAssertTrue(list.otherViews[0].isOffView)
        XCTAssertEqual(CommentListModel.otherViewsTitle, "On other views")
    }

    func testEmptyList() {
        let list = CommentListModel.make(model: CommentsModel(), context: .unknown, isScreenshotsCase: false)
        XCTAssertTrue(list.isEmpty)
        XCTAssertFalse(CommentListModel.emptyLine.contains("—"))
        XCTAssertEqual(ArtifactCommentsSection.heading(count: 2), "COMMENTS · 2")
    }

    // MARK: Show

    func testShowOnATextCommentSwitchesTheRevisionThenReveals() {
        var model = CommentsModel()
        let comment = model.addTextComment(anchor: TextAnchor(revision: 1, quote: "q", start: 0, end: 1), text: "x")
        let steps = CommentShowPlan.steps(for: comment, model: model, context: CommentViewContext(kind: .markdown, revision: 2), canShowStill: true)
        XCTAssertEqual(steps, [.switchRevision(1), .reveal])
    }

    func testShowOnAScreenSelectsThatScreen() {
        var model = CommentsModel()
        let one = model.addCapture(revision: 1)
        let two = model.addCapture(revision: 1)
        let comment = model.addComment(captureId: two.id, rect: rect, text: "x")
        let context = CommentViewContext(kind: .screenshots, revision: 1, shownCaptureId: one.id)
        XCTAssertEqual(CommentShowPlan.steps(for: comment, model: model, context: context, canShowStill: false), [.showCapture(two.id), .reveal])
    }

    func testShowOnALivePageWithAnAddressSetsItAndLooksForTheElement() {
        let (model, comment, context) = live(hash: "plans", text: "plans", current: "home")
        var changed = context
        changed.pageView = view("home", "home")
        XCTAssertEqual(
            CommentShowPlan.steps(for: comment, model: model, context: changed, canShowStill: false),
            [.setHash("plans"), .findElement, .reveal])
    }

    func testShowOnALivePageWithNoAddressOpensItsStillInFullSizeAndLooksOnTheCasePage() {
        let (model, comment, context) = live(text: "second tab", current: "first tab")
        XCTAssertEqual(
            CommentShowPlan.steps(for: comment, model: model, context: context, canShowStill: true),
            [.showCapture(model.captures[0].id)])
        XCTAssertEqual(
            CommentShowPlan.steps(for: comment, model: model, context: context, canShowStill: false),
            [.findElement, .reveal])
    }

    func testShowOnAnEarlierRevisionOfALivePageOpensItsStillInFullSize() {
        let (model, comment, _) = live(revision: 1)
        let context = CommentViewContext(kind: .htmlBundle, revision: 2)
        XCTAssertEqual(
            CommentShowPlan.steps(for: comment, model: model, context: context, canShowStill: true),
            [.showCapture(model.captures[0].id)])
    }

    func testShowOnACommentWithAPinOnlyReveals() {
        let (model, comment, context) = live()
        XCTAssertEqual(CommentShowPlan.steps(for: comment, model: model, context: context, canShowStill: false), [.reveal])
    }

    @MainActor
    func testShowSaysSoWhenTheElementIsNotOnTheNowPage() async {
        var (model, comment, context) = live(text: "second tab", current: "first tab")
        model.setElementContext(button, forComment: comment.id)
        var revealed = false
        var actions = CommentShowActions()
        actions.canShowStill = false
        actions.findElement = { _ in false }
        actions.reveal = { _ in revealed = true }
        let line = await CommentShowPlan.run(comment: comment, model: model, context: context, actions: actions)
        XCTAssertEqual(line, "This part of the prototype is not on screen now. It was on: the button \"Pay now\"")
        XCTAssertFalse(revealed)
    }

    @MainActor
    func testShowScrollsToTheElementWhenItExists() async {
        let (model, comment, context) = live(hash: "plans", text: "plans", current: "home")
        var seen: [String] = []
        var actions = CommentShowActions()
        actions.canShowStill = false
        actions.setHash = { seen.append("hash:\($0)") }
        actions.findElement = { _ in seen.append("find"); return true }
        actions.reveal = { _ in seen.append("reveal") }
        var changed = context
        changed.pageView = view("home", "home")
        let line = await CommentShowPlan.run(comment: comment, model: model, context: changed, actions: actions)
        XCTAssertNil(line)
        XCTAssertEqual(seen, ["hash:plans", "find", "reveal"])
    }

    func testElementMatchNeedsTheSameRoleAndText() {
        XCTAssertTrue(CommentShowPlan.elementFound(stored: button, found: button))
        XCTAssertTrue(CommentShowPlan.elementFound(stored: nil, found: nil))
        XCTAssertFalse(CommentShowPlan.elementFound(stored: button, found: nil))
        XCTAssertFalse(CommentShowPlan.elementFound(stored: button, found: PageElementContext(role: "link", text: "Pay now", selector: "", heading: "")))
        XCTAssertFalse(CommentShowPlan.elementFound(stored: button, found: PageElementContext(role: "button", text: "Cancel", selector: "", heading: "")))
    }

    func testNotOnScreenLineNamesTheElementOrAdmitsItCannot() {
        XCTAssertEqual(
            CommentShowPlan.notOnScreenLine(element: PageElementContext(role: "image", text: "", selector: "", heading: "")),
            "This part of the prototype is not on screen now. It was on: the image")
        XCTAssertTrue(CommentShowPlan.notOnScreenLine(element: nil).hasPrefix("This part of the prototype is not on screen now. It was on:"))
    }

    // MARK: The box

    @MainActor
    func testStoreShownStillIsThePickedScreenElseTheFirst() {
        let store = CommentsSessionStore()
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let records = store.addScreenshotsCaptures(images: [(image, nil), (image, nil)], revision: 1)
        XCTAssertEqual(store.shownStill(revision: 1)?.id, records[0].id)
        store.selectCapture(id: records[1].id)
        XCTAssertEqual(store.shownStill(revision: 1)?.id, records[1].id)
        XCTAssertNil(store.shownStill(revision: 2))
    }
}
