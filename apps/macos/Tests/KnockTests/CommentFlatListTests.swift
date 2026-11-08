import Testing
import Foundation
import AppKit
@testable import Knock

/// HAIL-75: one flat list, pins from every capture on the page, and a single
/// highlight shared by the list and the artifact.
@MainActor
struct CommentFlatListTests {
    private static let rect = Rect(x: 0.1, y: 0.2, w: 0.3, h: 0.1)
    private static let image = NSImage(size: NSSize(width: 4, height: 4))

    private static func place(_ store: CommentsSessionStore, _ text: String, page: PageViewport? = nil, revision: Int = 1) async -> Knock.Comment? {
        store.beginPendingDraft(rect: rect, revision: revision, page: page, snapshot: Task { image })
        store.updateDraftText(text)
        return await store.commitDraftAwaitingCapture()
    }

    // MARK: numbering

    @Test func commentsOnDifferentCapturesNumberOneToFour() async {
        let store = CommentsSessionStore()
        var made: [Knock.Comment] = []
        for text in ["a", "b", "c", "d"] { made.append(await Self.place(store, text)!) }

        #expect(made.map(\.n) == [1, 2, 3, 4])
        #expect(store.model.captures.count == 4)
        #expect(store.model.orderedComments.map(\.text) == ["a", "b", "c", "d"])
        #expect(store.nextPinNumber == 5)
    }

    @Test func deletingACommentRenumbersAcrossCapturesInTheStore() async {
        let store = CommentsSessionStore()
        let a = await Self.place(store, "a")!
        let b = await Self.place(store, "b")!
        let c = await Self.place(store, "c")!

        store.deleteComment(id: b.id)

        #expect(store.model.orderedComments.map(\.id) == [a.id, c.id])
        #expect(store.model.orderedComments.map(\.n) == [1, 2])
    }

    // MARK: page mapping

    @Test func aCaptureRectMapsToPageCoordinatesAtTwoScrollPositions() {
        let comment = Rect(x: 0.25, y: 0.5, w: 0.5, h: 0.1)
        let top = PageViewport(scrollX: 0, scrollY: 0, width: 800, height: 600)
        let scrolled = PageViewport(scrollX: 0, scrollY: 1000, width: 800, height: 600)

        let pageTop = CommentPageMapping.pageRect(for: comment, capture: top, fallbackSize: .zero)
        let pageScrolled = CommentPageMapping.pageRect(for: comment, capture: scrolled, fallbackSize: .zero)

        #expect(pageTop == CGRect(x: 200, y: 300, width: 400, height: 60))
        #expect(pageScrolled == CGRect(x: 200, y: 1300, width: 400, height: 60))
    }

    @Test func aPinFollowsThePageWhenItScrolls() {
        let page = CGRect(x: 200, y: 1300, width: 400, height: 60)
        let size = CGSize(width: 800, height: 600)

        let atOrigin = CommentPageMapping.layerRect(forPageRect: page, scroll: .zero)
        let near = CommentPageMapping.layerRect(forPageRect: page, scroll: CGPoint(x: 0, y: 1000))

        #expect(!CommentPageMapping.pinIsVisible(atOrigin, in: size), "off-screen pins are not drawn")
        #expect(near.origin == CGPoint(x: 200, y: 300))
        #expect(CommentPageMapping.pinIsVisible(near, in: size))
    }

    // MARK: page mapping at a zoom (operator, 4 Oct: Comment mode zooms)

    /// A 1000 x 600 pt layer. At zoom `z` the page's viewport is (1000 / z) x
    /// (600 / z) CSS px, as `innerWidth`/`innerHeight` read under `pageZoom`.
    private static func viewport(zoom: Double, scroll: CGPoint = .zero, anchor: CGPoint = .zero) -> PageViewport {
        PageViewport(
            scrollX: scroll.x, scrollY: scroll.y, width: 1000 / zoom, height: 600 / zoom,
            zoom: zoom, anchorX: anchor.x, anchorY: anchor.y
        )
    }
    private static let layer = CGSize(width: 1000, height: 600)

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001 && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    /// A region dragged at any zoom and scroll is stored as 0...1 of the layer
    /// (and of the snapshot), and draws back exactly where it was dragged.
    @Test func aRegionDraggedAtAnyZoomDrawsWhereItWasDragged() {
        let dragged = CGRect(x: 300, y: 120, width: 200, height: 90)
        let stored = Rect(x: dragged.minX / 1000, y: dragged.minY / 600, w: dragged.width / 1000, h: dragged.height / 600)
        for zoom in [0.25, 0.5, 0.8, 1, 1.25, 2, 4] {
            for scroll in [CGPoint.zero, CGPoint(x: 40, y: 900), CGPoint(x: 1200, y: 3000)] {
                let at = Self.viewport(zoom: zoom, scroll: scroll)
                let drawn = CommentPageMapping.layerRect(for: stored, capture: at, current: at, layerSize: Self.layer)
                #expect(Self.close(drawn, dragged), "zoom \(zoom) scroll \(scroll)")
            }
        }
    }

    /// A comment made at 100% (scrolled 1000 down) marks page rect
    /// (300, 1120, 200, 90). At 200% scrolled to (250, 1000) it sits at
    /// ((300 - 250) x 2, (1120 - 1000) x 2) and is twice the size; at 50%
    /// from the top it sits at half its page position and half its size.
    @Test func aCommentFromOneHundredPercentLandsOnItsSpotAtTwoHundredAndFiftyPercent() {
        let capture = Self.viewport(zoom: 1, scroll: CGPoint(x: 0, y: 1000))
        let rect = Rect(x: 0.3, y: 0.2, w: 0.2, h: 0.15)
        let page = CommentPageMapping.pageRect(for: rect, capture: capture, fallbackSize: .zero)
        #expect(Self.close(page, CGRect(x: 300, y: 1120, width: 200, height: 90)))

        let atTwo = CommentPageMapping.layerRect(for: rect, capture: capture, current: Self.viewport(zoom: 2, scroll: CGPoint(x: 250, y: 1000)), layerSize: Self.layer)
        #expect(Self.close(atTwo, CGRect(x: 100, y: 240, width: 400, height: 180)))

        let atHalf = CommentPageMapping.layerRect(for: rect, capture: capture, current: Self.viewport(zoom: 0.5), layerSize: Self.layer)
        #expect(Self.close(atHalf, CGRect(x: 150, y: 560, width: 100, height: 45)))
    }

    /// The other way round: a comment made at 200% (and one at 50%) shows at
    /// the same page spot at 100%.
    @Test func commentsMadeAtTwoHundredAndFiftyPercentLandAtOneHundredPercent() {
        let rect = Rect(x: 0.5, y: 0.5, w: 0.1, h: 0.1)
        let now = Self.viewport(zoom: 1)
        // At 200% the viewport is 500 x 300 CSS px: the rect is page (250, 150, 50, 30).
        let fromTwo = CommentPageMapping.layerRect(for: rect, capture: Self.viewport(zoom: 2), current: now, layerSize: Self.layer)
        #expect(Self.close(fromTwo, CGRect(x: 250, y: 150, width: 50, height: 30)))
        // At 50% the viewport is 2000 x 1200 CSS px: the rect is page (1000, 600, 200, 120).
        let fromHalf = CommentPageMapping.layerRect(for: rect, capture: Self.viewport(zoom: 0.5), current: now, layerSize: Self.layer)
        #expect(Self.close(fromHalf, CGRect(x: 1000, y: 600, width: 200, height: 120)))
        #expect(!CommentPageMapping.pinIsVisible(fromHalf, in: Self.layer), "it is off to the right at 100%")
    }

    /// Interact mode (operator, 4 Oct) draws the same layer at every zoom: a
    /// pin made at 100% lands on its page spot at 50% and 200%, and a click
    /// there hits the pin (the only thing the Interact layer catches).
    @Test func anInteractPinAtFiftyAndTwoHundredPercentLandsOnItsSpot() {
        let capture = Self.viewport(zoom: 1, scroll: CGPoint(x: 0, y: 400))
        let rect = Rect(x: 0.2, y: 0.5, w: 0.1, h: 0.1)   // page (200, 700, 100, 60)
        let comment = Knock.Comment(id: "p", captureId: "c", n: 1, rect: rect, text: "pin")
        let cases: [(PageViewport, CGRect)] = [
            (Self.viewport(zoom: 0.5, scroll: CGPoint(x: 0, y: 100)), CGRect(x: 100, y: 300, width: 50, height: 30)),
            (Self.viewport(zoom: 2, scroll: CGPoint(x: 150, y: 650)), CGRect(x: 100, y: 100, width: 200, height: 120)),
        ]
        for (current, expected) in cases {
            let drawn = CommentPageMapping.layerRect(for: rect, capture: capture, current: current, layerSize: Self.layer)
            #expect(Self.close(drawn, expected), "zoom \(current.zoom)")
            let hit = CommentPageMapping.pinHit(at: drawn.origin, comments: [comment], layerRects: ["p": drawn], size: Self.layer)
            #expect(hit?.id == "p")
        }
    }

    /// A centred diagram moves when a zoom changes the layout width; its pins
    /// move with it (the SVG's page position is the anchor).
    @Test func diagramPinsFollowTheCentredSvgAcrossZooms() {
        // At 100% a 600 px SVG sits centred at x 200 in a 1000 px viewport.
        let capture = Self.viewport(zoom: 1, anchor: CGPoint(x: 200, y: 0))
        let rect = Rect(x: 0.25, y: 0.1, w: 0.05, h: 0.05)   // page x 250: 50 px into the SVG
        // At 50% the viewport is 2000 CSS px, so the SVG sits at x 700.
        let atHalf = CommentPageMapping.layerRect(for: rect, capture: capture, current: Self.viewport(zoom: 0.5, anchor: CGPoint(x: 700, y: 0)), layerSize: Self.layer)
        #expect(abs(atHalf.minX - (700 + 50) * 0.5) < 0.001, "still 50 px into the SVG")
        // At 200% the SVG overflows the 500 px viewport and sits at x 0.
        let atTwo = CommentPageMapping.layerRect(for: rect, capture: capture, current: Self.viewport(zoom: 2, anchor: .zero), layerSize: Self.layer)
        #expect(abs(atTwo.minX - 50 * 2) < 0.001)
    }

    @Test func aViewportReadingCarriesItsZoomAndAnchor() {
        let reading = PageViewport.make(values: [10, 20, 500, 300, 40, 8], zoom: 2)
        #expect(reading == PageViewport(scrollX: 10, scrollY: 20, width: 500, height: 300, zoom: 2, anchorX: 40, anchorY: 8))
        #expect(PageViewport.make(values: [10, 20, 500, 300], zoom: 1)?.anchor == .zero)
        #expect(PageViewport.make(values: [10, 20], zoom: 1) == nil)
        // The view's own size over the zoom, not the whole CSS px innerHeight (699 / 2 = 349.5, read as 349).
        #expect(PageViewport.make(values: [0, 0, 281, 349], zoom: 2, viewSize: CGSize(width: 562, height: 699))?.size == CGSize(width: 281, height: 349.5))
        let a = PageViewport(scrollX: 0, scrollY: 0, width: 500, height: 300, zoom: 2)
        var b = a
        b.zoom = 1.25
        #expect(!a.matches(b), "a zoom change needs a new capture")
    }

    @Test func revealScrollsInPageUnitsAtAZoom() {
        // At 200% the viewport is 500 x 300 CSS px; a rect at page y 1500 is off screen.
        let viewport = Self.viewport(zoom: 2)
        let far = CGRect(x: 100, y: 1500, width: 100, height: 40)
        #expect(CommentPageMapping.scrollTarget(forPageRect: far, scroll: .zero, viewport: viewport.size) == CGPoint(x: 0, y: 1425))
    }

    @Test func aCaptureWithoutAViewportReadsAsTakenAtTheTop() {
        let rect = CommentPageMapping.pageRect(for: Rect(x: 0.5, y: 0.5, w: 0.1, h: 0.1), capture: nil, fallbackSize: CGSize(width: 400, height: 200))
        #expect(rect == CGRect(x: 200, y: 100, width: 40, height: 20))
    }

    @Test func revealScrollsOnlyWhenThePinIsOffScreen() {
        let size = CGSize(width: 800, height: 600)
        let visible = CGRect(x: 100, y: 200, width: 100, height: 40)
        let far = CGRect(x: 100, y: 1500, width: 100, height: 40)

        #expect(CommentPageMapping.scrollTarget(forPageRect: visible, scroll: .zero, viewport: size) == nil)
        #expect(CommentPageMapping.scrollTarget(forPageRect: far, scroll: .zero, viewport: size) == CGPoint(x: 0, y: 1350))
    }

    @Test func aPinClickHitsTheNewestPinUnderThePointOnly() {
        let older = Knock.Comment(id: "a", captureId: "c", n: 1, rect: Self.rect, text: "a")
        let newer = Knock.Comment(id: "b", captureId: "c", n: 2, rect: Self.rect, text: "b")
        let rects = ["a": CGRect(x: 50, y: 50, width: 80, height: 40), "b": CGRect(x: 52, y: 52, width: 80, height: 40)]
        let size = CGSize(width: 400, height: 400)

        #expect(CommentPageMapping.pinHit(at: CGPoint(x: 52, y: 52), comments: [older, newer], layerRects: rects, size: size)?.id == "b")
        #expect(CommentPageMapping.pinHit(at: CGPoint(x: 300, y: 300), comments: [older, newer], layerRects: rects, size: size) == nil)
    }

    // MARK: selection

    @Test func clickingAListCardHighlightsItsPinAndAskForAReveal() async {
        let store = CommentsSessionStore()
        let a = await Self.place(store, "a")!
        let b = await Self.place(store, "b")!

        store.selectComment(id: a.id, origin: .list)
        store.selectComment(id: b.id, origin: .list)

        #expect(store.selectedCommentId == b.id, "only one highlight at a time")
        #expect(store.revealRequest?.commentId == b.id)
        #expect(store.revealRequest?.origin == .list)
    }

    @Test func clickingAPinSelectsTheSameCardAndAsksTheListToScroll() async {
        let store = CommentsSessionStore()
        let a = await Self.place(store, "a")!
        _ = await Self.place(store, "b")

        store.selectComment(id: a.id, origin: .artifact)

        #expect(store.selectedCommentId == a.id)
        #expect(store.revealRequest?.origin == .artifact)
        store.clearCommentSelection()
        #expect(store.selectedCommentId == nil)
    }

    @Test func deletingTheHighlightedCommentClearsTheHighlight() async {
        let store = CommentsSessionStore()
        let a = await Self.place(store, "a")!
        store.selectComment(id: a.id, origin: .list)

        store.deleteComment(id: a.id)

        #expect(store.selectedCommentId == nil)
    }

    @Test func clickingACommentOnAnotherScreenSwitchesToThatScreen() {
        let store = CommentsSessionStore()
        let screens = store.addScreenshotsCaptures(images: [(Self.image, nil), (Self.image, nil), (Self.image, nil)], revision: 1)
        store.selectCapture(id: screens[2].id)
        store.beginDraft(rect: Self.rect)
        store.updateDraftText("on three")
        let onThree = store.commitDraft()!
        store.selectCapture(id: screens[0].id)

        store.selectComment(id: onThree.id, origin: .list)

        #expect(store.currentCapture?.id == screens[2].id)
        #expect(store.selectedCommentId == onThree.id)
    }

    // MARK: revisions

    @Test func aCaptureViewportIsKeptOnTheCapture() async {
        let store = CommentsSessionStore()
        let viewport = PageViewport(scrollX: 0, scrollY: 640, width: 900, height: 700)
        let comment = await Self.place(store, "a", page: viewport)!

        #expect(store.model.captures.first { $0.id == comment.captureId }?.page == viewport)
    }

    @Test func capturesFromAnOlderRevisionAreNotDrawnOnANewerOne() async {
        let store = CommentsSessionStore()
        _ = await Self.place(store, "v1 note", revision: 1)
        let onV2 = await Self.place(store, "v2 note", revision: 2)!

        #expect(store.model.comments(onRevision: 2).map(\.id) == [onV2.id], "the live layer draws this")
        #expect(store.model.orderedComments.count == 2, "the flat list still holds both")
    }
}

/// HAIL-75 pass 2: comments live on the artifact as pins with an inline card.
@MainActor
struct InlineCommentCardTests {
    private static let rect = Rect(x: 0.1, y: 0.2, w: 0.3, h: 0.1)
    private static let image = NSImage(size: NSSize(width: 4, height: 4))

    private static func storeWithComments(_ texts: [String]) async -> (CommentsSessionStore, [Knock.Comment]) {
        let store = CommentsSessionStore()
        store.hoverPreviewDelay = .milliseconds(10)
        var made: [Knock.Comment] = []
        for text in texts {
            store.beginPendingDraft(rect: rect, revision: 1, snapshot: Task { image })
            store.updateDraftText(text)
            made.append(await store.commitDraftAwaitingCapture()!)
        }
        return (store, made)
    }

    @Test func hoveringAPinShowsThePreviewAfterTheDelayAndLeavingHidesIt() async throws {
        let (store, made) = await Self.storeWithComments(["a", "b"])
        store.pinHoverChanged(made[1].id, inside: true)
        #expect(store.hoveredCommentId == made[1].id)
        #expect(store.previewCommentId == nil, "not before the delay")
        #expect(store.showsRegion(of: made[1].id), "the box shows while hovered")
        #expect(!store.showsRegion(of: made[0].id))

        // Wait for the delayed preview without a fixed sleep: under a full
        // parallel test run the main actor can be busy for well over 120 ms.
        _ = try await pollUntil(.seconds(20)) { store.previewCommentId != nil }
        #expect(store.previewCommentId == made[1].id)

        store.pinHoverChanged(made[1].id, inside: false)
        #expect(store.previewCommentId == nil)
        #expect(!store.showsRegion(of: made[1].id), "a saved comment shows only its pin again")
    }

    @Test func aQuickPassOverAPinNeverShowsThePreview() async throws {
        let (store, made) = await Self.storeWithComments(["a"])
        store.hoverPreviewDelay = .milliseconds(80)
        store.pinHoverChanged(made[0].id, inside: true)
        store.pinHoverChanged(made[0].id, inside: false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.previewCommentId == nil)
    }

    @Test func clickingAPinOpensItsCardAndOnlyOneIsOpen() async {
        let (store, made) = await Self.storeWithComments(["a", "b"])
        store.selectComment(id: made[0].id, origin: .artifact)
        #expect(store.openCommentId == made[0].id)
        store.selectComment(id: made[1].id, origin: .artifact)
        #expect(store.openCommentId == made[1].id, "opening another closes the first")
        #expect(store.previewCommentId == nil)
    }

    @Test func clickingAListCardAlsoOpensTheInlineCard() async {
        let (store, made) = await Self.storeWithComments(["a"])
        store.selectComment(id: made[0].id, origin: .list)
        #expect(store.openCommentId == made[0].id)
        #expect(store.selectedCommentId == made[0].id)
    }

    @Test func editingSavesTheTextAndClosesTheCard() async {
        let (store, made) = await Self.storeWithComments(["old"])
        store.openComment(id: made[0].id)
        #expect(store.saveComment(id: made[0].id, text: "  new text \n"))
        #expect(store.model.comments.first?.text == "new text")
        #expect(store.openCommentId == nil)
    }

    @Test func anEmptyEditIsRefusedAndKeepsTheSavedText() async {
        let (store, made) = await Self.storeWithComments(["keep me"])
        store.openComment(id: made[0].id)
        #expect(!store.saveComment(id: made[0].id, text: "   "))
        #expect(store.model.comments.first?.text == "keep me")
    }

    @Test func closingTheCardKeepsTheSavedText() async {
        let (store, made) = await Self.storeWithComments(["keep me"])
        store.openComment(id: made[0].id)
        store.closeComment()
        #expect(store.openCommentId == nil)
        #expect(store.model.comments.first?.text == "keep me")
    }

    @Test func deletingFromTheCardRenumbersAndClosesIt() async {
        let (store, made) = await Self.storeWithComments(["a", "b", "c"])
        store.openComment(id: made[1].id)
        store.deleteComment(id: made[1].id)
        #expect(store.openCommentId == nil)
        #expect(store.model.orderedComments.map(\.text) == ["a", "c"])
        #expect(store.model.orderedComments.map(\.n) == [1, 2])
    }

    @Test func startingANewNoteClosesTheOpenCard() async {
        let (store, made) = await Self.storeWithComments(["a"])
        store.openComment(id: made[0].id)
        store.beginPendingDraft(rect: Self.rect, revision: 1, snapshot: Task { Self.image })
        #expect(store.openCommentId == nil)
        store.openComment(id: made[0].id)
        #expect(store.openCommentId == nil, "no second card while a note is being written")
    }

    // MARK: zoomed stage (HAIL-73 + HAIL-75)

    @Test func cardAndRevealUseTheZoomedFrame() {
        let comment = Knock.Comment(id: "c", captureId: "k", n: 1, rect: Self.rect, text: "t")
        let container = CGSize(width: 400, height: 300)
        let fit = ScreenshotViewport.frame(container: container, image: CGSize(width: 200, height: 400), zoom: .fit)
        let big = ScreenshotViewport.frame(container: container, image: CGSize(width: 200, height: 400), zoom: .scale(3))
        #expect(big.width > fit.width)

        // The pin, and so the card anchored to it, sits on the same image spot.
        let bigPin = CommentCaptureStageView.pointRect(for: comment.rect, in: big)
        #expect(abs((bigPin.minX - big.minX) / big.width - Self.rect.x) < 0.0001)
        #expect(abs((bigPin.minY - big.minY) / big.height - Self.rect.y) < 0.0001)

        // Reveal scrolls both axes on the zoomed stage, only down on a fit-width page.
        let zoomed = CommentCaptureStageView.revealOffset(comment: comment, frame: big, viewport: container, horizontal: true)
        #expect(zoomed.width == max(0, bigPin.minX - container.width / 4))
        #expect(zoomed.height == max(0, bigPin.minY - container.height / 4))
        let fitWidth = CommentCaptureStageView.revealOffset(comment: comment, frame: big, viewport: container, horizontal: false)
        #expect(fitWidth.width == 0)

        // The card is placed inside the zoomed content, not the viewport.
        let content = CGSize(width: max(container.width, big.width), height: max(container.height, big.height))
        let pos = CommentCaptureStageView.popoverPosition(for: bigPin, in: content, height: CommentCaptureStageView.editCardHeight)
        #expect(pos.y <= content.height && pos.x <= content.width)
        #expect(pos.y >= bigPin.minY - 1)
    }
}
