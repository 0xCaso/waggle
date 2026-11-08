import Testing
import Foundation
import AppKit
@testable import Knock

/// The pin model: numbering, renumbering after a delete, and normalized-rect
/// storage (docs/stories/KNOCK-11.md "Verification").
struct CommentsModelTests {
    @Test func capturesNumberSequentiallyInCreationOrder() {
        var model = CommentsModel()
        let first = model.addCapture(revision: 1)
        let second = model.addCapture(revision: 1)
        let third = model.addCapture(revision: 2)

        #expect(first.n == 1)
        #expect(second.n == 2)
        #expect(third.n == 3, "a new revision does not restart capture numbering")
    }

    @Test func commentsNumberFromOnePerCaptureInCreationOrder() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        let rectA = Rect(x: 0.1, y: 0.2, w: 0.3, h: 0.1)
        let rectB = Rect(x: 0.5, y: 0.6, w: 0.2, h: 0.1)

        let first = model.addComment(captureId: capture.id, rect: rectA, text: "Default this to Monthly.")
        let second = model.addComment(captureId: capture.id, rect: rectB, text: "Keep the pay button above the fold.")

        #expect(first.n == 1)
        #expect(second.n == 2)
        #expect(model.comments(on: capture.id).map(\.id) == [first.id, second.id])
    }

    /// HAIL-75: one list, one numbering for the whole case.
    @Test func aSecondCaptureContinuesTheCaseWideNumbering() {
        var model = CommentsModel()
        let captureA = model.addCapture(revision: 1)
        let captureB = model.addCapture(revision: 1)
        model.addComment(captureId: captureA.id, rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), text: "on capture A")
        let onB = model.addComment(captureId: captureB.id, rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), text: "on capture B")

        #expect(onB.n == 2, "numbers run across captures, so the list, the pin and the annotated image agree")
    }

    @Test func deletingAMiddleCommentRenumbersTheRestInTheirOriginalOrder() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        let a = model.addComment(captureId: capture.id, rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), text: "a")
        let b = model.addComment(captureId: capture.id, rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), text: "b")
        let c = model.addComment(captureId: capture.id, rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), text: "c")

        model.deleteComment(id: b.id)

        let remaining = model.comments(on: capture.id)
        #expect(remaining.map(\.id) == [a.id, c.id])
        #expect(remaining.map(\.n) == [1, 2], "numbers stay in order after a delete (renumbered, no gap)")
    }

    @Test func deletingACommentRenumbersTheWholeCaseWithoutGaps() {
        var model = CommentsModel()
        let a = model.addCapture(revision: 1)
        let b = model.addCapture(revision: 1)
        let rect = Rect(x: 0, y: 0, w: 0.1, h: 0.1)
        let c1 = model.addComment(captureId: a.id, rect: rect, text: "1")
        let c2 = model.addComment(captureId: a.id, rect: rect, text: "2")
        let c3 = model.addComment(captureId: b.id, rect: rect, text: "3")
        let c4 = model.addComment(captureId: b.id, rect: rect, text: "4")
        #expect(model.orderedComments.map(\.n) == [1, 2, 3, 4])

        model.deleteComment(id: c2.id)

        #expect(model.orderedComments.map(\.id) == [c1.id, c3.id, c4.id])
        #expect(model.orderedComments.map(\.n) == [1, 2, 3])
        model.deleteCapture(id: b.id)
        #expect(model.orderedComments.map(\.n) == [1])
    }

    @Test func editingACommentsTextKeepsItsIdRectAndNumber() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        let rect = Rect(x: 0.12, y: 0.31, w: 0.76, h: 0.06)
        let original = model.addComment(captureId: capture.id, rect: rect, text: "first draft")

        model.updateCommentText(id: original.id, text: "edited text")

        let edited = model.comments(on: capture.id).first
        #expect(edited?.id == original.id)
        #expect(edited?.n == original.n)
        #expect(edited?.rect == rect)
        #expect(edited?.text == "edited text")
    }
}

/// `CommentsSessionStore`: the draft lifecycle (begin, edit, commit/cancel)
/// and the rule that an empty note never becomes a comment.
@MainActor
struct CommentsSessionStoreTests {
    @Test func aCaptureStartsWithNoImageUntilOneIsAdded() {
        let store = CommentsSessionStore()
        #expect(store.currentCapture == nil)
        #expect(store.currentImage == nil)
    }

    @Test func addingACaptureMakesItCurrentAndClearsAnyOpenDraft() {
        let store = CommentsSessionStore()
        store.addCapture(image: NSImage(), revision: 1)
        store.beginDraft(rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1))
        #expect(store.draftPin != nil)

        store.addCapture(image: NSImage(), revision: 1)
        #expect(store.draftPin == nil, "a new capture (a new C) drops any draft left open on the previous one")
        #expect(store.currentCapture?.n == 2)
        #expect(store.currentComments.isEmpty)
    }

    @Test func commitWithANonEmptyNoteSavesANumberedComment() {
        let store = CommentsSessionStore()
        store.addCapture(image: NSImage(), revision: 2)
        store.beginDraft(rect: Rect(x: 0.1, y: 0.2, w: 0.3, h: 0.1))
        store.updateDraftText("Default this to Monthly.")

        let saved = store.commitDraft()

        #expect(saved?.n == 1)
        #expect(saved?.text == "Default this to Monthly.")
        #expect(store.draftPin == nil)
        #expect(store.currentComments.map(\.id) == [saved?.id].compactMap { $0 })
    }

    @Test func commitWithAnEmptyNoteDiscardsTheDraftWithoutSavingAComment() {
        let store = CommentsSessionStore()
        store.addCapture(image: NSImage(), revision: 1)
        store.beginDraft(rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1))
        store.updateDraftText("   ")

        let saved = store.commitDraft()

        #expect(saved == nil, "a note per pin is required before it counts as a comment")
        #expect(store.draftPin == nil)
        #expect(store.currentComments.isEmpty)
    }

    @Test func cancelDropsTheDraftWithoutSavingAComment() {
        let store = CommentsSessionStore()
        store.addCapture(image: NSImage(), revision: 1)
        store.beginDraft(rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1))
        store.updateDraftText("would have been a note")

        store.cancelDraft()

        #expect(store.draftPin == nil)
        #expect(store.currentComments.isEmpty)
    }

    @Test func onlyOneDraftCanBeOpenAtATime() {
        let store = CommentsSessionStore()
        store.addCapture(image: NSImage(), revision: 1)
        store.beginDraft(rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1))
        let firstDraftRect = store.draftPin?.rect

        store.beginDraft(rect: Rect(x: 0.5, y: 0.5, w: 0.1, h: 0.1))

        #expect(store.draftPin?.rect == firstDraftRect, "a second begin while one is open is ignored")
    }

    /// HAIL-35 contract: "the Comment column lists the comments of EVERY
    /// capture of this session, grouped by capture" - every capture and its
    /// own comments must stay independently queryable, not just the latest.
    @Test func everyCapturesOwnCommentsStayQueryableAfterALaterCaptureIsAdded() {
        let store = CommentsSessionStore()
        store.addCapture(image: NSImage(), revision: 1)
        store.beginDraft(rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1))
        store.updateDraftText("first capture's note")
        let firstCaptureComment = store.commitDraft()
        let firstCaptureId = store.currentCapture!.id

        store.addCapture(image: NSImage(), revision: 1)
        store.beginDraft(rect: Rect(x: 0.2, y: 0.2, w: 0.1, h: 0.1))
        store.updateDraftText("second capture's note")
        let secondCaptureComment = store.commitDraft()

        #expect(store.model.captures.count == 2, "both captures of this session stay in the model, not just the latest")
        #expect(store.model.comments(on: firstCaptureId).map(\.id) == [firstCaptureComment?.id].compactMap { $0 }, "the first capture's own comment is still there after a second capture was taken")
        #expect(store.model.comments.count == 2, "the footer's total counts every comment across every capture")
        #expect(secondCaptureComment != nil)
    }

    /// HAIL-35 contract: "Selecting a group ... shows that capture on the
    /// stage with its pins; new pins go on the capture shown."
    @Test func selectingAnEarlierCaptureShowsItsOwnPinsAndTargetsNewOnesToIt() {
        let store = CommentsSessionStore()
        let first = store.addCapture(image: NSImage(), revision: 1)
        store.addCapture(image: NSImage(), revision: 1)
        #expect(store.currentCapture?.id != first.id, "a fresh capture is shown by default")

        store.selectCapture(id: first.id)
        #expect(store.currentCapture?.id == first.id)

        store.beginDraft(rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1))
        #expect(store.draftPin?.captureId == first.id, "a new pin targets whichever capture is currently shown")
    }

    /// A capture taken after interaction (or a fresh screenshot capture)
    /// always becomes the one shown - matches the pre-HAIL-35 "always jump
    /// to the newest capture" behaviour when nothing was explicitly selected.
    @Test func addingACaptureResetsTheSelectionBackToTheNewestOne() {
        let store = CommentsSessionStore()
        let first = store.addCapture(image: NSImage(), revision: 1)
        store.selectCapture(id: first.id)

        let second = store.addCapture(image: NSImage(), revision: 1)

        #expect(store.currentCapture?.id == second.id, "a new capture always becomes the one shown, even over an earlier explicit selection")
    }

    // HAIL-40: `addScreenshotsCaptures` adds every image as its own capture
    // up front, in order, with the first screen shown by default - no
    // interactive "take a capture" step, unlike a live prototype.
    @Test func addScreenshotsCapturesAddsEveryImageUpFrontInOrder() {
        let store = CommentsSessionStore()
        let records = store.addScreenshotsCaptures(
            images: [(NSImage(), "Home"), (NSImage(), nil), (NSImage(), "Checkout")],
            revision: 1
        )

        #expect(records.map(\.n) == [1, 2, 3])
        #expect(store.model.captures.count == 3)
        #expect(store.isScreenshotsCase)
        #expect(store.currentCapture?.id == records.first?.id, "opens on screen 1, not the newest")
    }

    @Test func screenLabelReadsTheCaptionForItsOwnCaptureOnly() {
        let store = CommentsSessionStore()
        let records = store.addScreenshotsCaptures(
            images: [(NSImage(), "Verify email"), (NSImage(), nil)],
            revision: 1
        )

        #expect(store.screenLabel(for: records[0]) == "Screen 1 · Verify email")
        #expect(store.screenLabel(for: records[1]) == "Screen 2", "no caption for this screen falls back to the bare number")
    }

    @Test func screenLabelIsNilOutsideAScreenshotsCase() {
        let store = CommentsSessionStore()
        let capture = store.addCapture(image: NSImage(), revision: 1)
        #expect(store.screenLabel(for: capture) == nil)
    }

    /// HAIL-40 fold of the HAIL-35 grouping contract: comments on different
    /// screens stay independently queryable, same as ordinary captures.
    @Test func commentsOnDifferentScreensStaySeparate() {
        let store = CommentsSessionStore()
        let records = store.addScreenshotsCaptures(images: [(NSImage(), "A"), (NSImage(), "B")], revision: 1)

        store.selectCapture(id: records[0].id)
        store.beginDraft(rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1))
        store.updateDraftText("comment on screen 1")
        store.commitDraft()

        store.selectCapture(id: records[1].id)
        store.beginDraft(rect: Rect(x: 0.2, y: 0.2, w: 0.1, h: 0.1))
        store.updateDraftText("comment on screen 2")
        store.commitDraft()

        #expect(store.model.comments(on: records[0].id).map(\.text) == ["comment on screen 1"])
        #expect(store.model.comments(on: records[1].id).map(\.text) == ["comment on screen 2"])
    }

    @Test func deletingASavedCommentRenumbersTheRest() {
        let store = CommentsSessionStore()
        store.addCapture(image: NSImage(), revision: 1)
        store.beginDraft(rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1))
        store.updateDraftText("first")
        let first = store.commitDraft()
        store.beginDraft(rect: Rect(x: 0.2, y: 0.2, w: 0.1, h: 0.1))
        store.updateDraftText("second")
        _ = store.commitDraft()

        store.deleteComment(id: first!.id)

        #expect(store.currentComments.map(\.n) == [1])
        #expect(store.currentComments.first?.text == "second")
    }
}

/// `CommentCaptureStageView`'s pure geometry helpers: fitting the capture
/// image into the stage, and converting between normalized (0..1) rects and
/// on-screen point rects (docs/stories/KNOCK-11.md AC: "Region rects are
/// stored normalized (0..1) relative to the capture").
@MainActor
struct CommentCaptureStageGeometryTests {
    /// HAIL-35 contract: the capture is a full page, fit to the column's
    /// width and left to run taller than the container - the enclosing
    /// `ScrollView` handles the rest, so there is no letterboxing/centering
    /// to compute here any more.
    @Test func fitWidthFrameScalesToContainerWidthAndPreservesAspectRatio() {
        let frame = CommentCaptureStageView.fitWidthFrame(containerWidth: 200, image: NSSize(width: 400, height: 100))
        #expect(frame.width == 200)
        #expect(frame.height == 50)
        #expect(frame.minX == 0)
        #expect(frame.minY == 0)
    }

    @Test func fitWidthFrameLetsATallPageRunPastTheContainerHeight() {
        let frame = CommentCaptureStageView.fitWidthFrame(containerWidth: 300, image: NSSize(width: 300, height: 4000))
        #expect(frame.width == 300)
        #expect(frame.height == 4000, "a full-page capture stays uncropped - the ScrollView, not this fit math, is what makes it scroll")
    }

    @Test func pointRectAndItsInverseRoundTripANormalizedRect() {
        let frame = CGRect(x: 10, y: 20, width: 400, height: 200)
        let rect = Rect(x: 0.25, y: 0.5, w: 0.5, h: 0.25)

        let pointRect = CommentCaptureStageView.pointRect(for: rect, in: frame)
        #expect(pointRect == CGRect(x: 110, y: 120, width: 200, height: 50))

        let normalizedBack = Rect(
            x: (pointRect.minX - frame.minX) / frame.width,
            y: (pointRect.minY - frame.minY) / frame.height,
            w: pointRect.width / frame.width,
            h: pointRect.height / frame.height
        )
        #expect(normalizedBack == rect)
    }

    /// HAIL-35 fold: a pin placed low on a tall, full-page capture must map
    /// to a stage point near the bottom of the fitted frame - and that same
    /// point must land inside the visible viewport once the stage's
    /// `ScrollViewReader` anchor scrolls to the capture's own
    /// `scrollFraction` (the "first scrolled to where the operator was"
    /// contract), the exact place attempt 1's evidence found the pin
    /// missing from the capture.
    @Test func pinPositionMathOnATallCaptureAtItsOwnScrollOffset() {
        // A 3-screen-tall capture (matches the HAIL-35 evidence fixture:
        // 954x650 viewport, 3x900px sections -> 2700pt full-page capture),
        // fit to a narrower column.
        let frame = CommentCaptureStageView.fitWidthFrame(containerWidth: 430, image: NSSize(width: 954, height: 2700))
        #expect(frame.height.rounded() == 1217, "954->430 scale (0.4508...) applied to the full 2700pt page")

        // A pin dropped near the bottom of the page (y: 0.92, matching the
        // evidence hook's "low" pin), the same rect stored on `Comment`.
        let pin = Rect(x: 0.3, y: 0.92, w: 0.35, h: 0.05)
        let pinPoint = CommentCaptureStageView.pointRect(for: pin, in: frame)
        #expect(pinPoint.minY.rounded() == 1120, "92% down a 1217pt-tall frame")
        #expect(pinPoint.maxY <= frame.height, "the pin must stay inside the capture's own frame, not past its bottom edge")

        // The capture's own `scrollFraction` (read from the operator's live
        // scroll position at capture time) that the stage opens to - the
        // same value a page scrolled almost to the bottom would produce.
        let scrollFraction = 0.95
        let initialScrollAnchorY = frame.height * scrollFraction
        #expect(initialScrollAnchorY.rounded() == 1156)

        // The stage's viewport (the column's own visible height, not the
        // full scrollable content) - the pin must fall within one viewport's
        // worth of the scroll anchor for it to actually be on screen once
        // the `ScrollViewReader` scrolls there, not just present somewhere
        // in the (much taller) content.
        let viewportHeight: CGFloat = 650
        let visibleRange = (initialScrollAnchorY - viewportHeight)...(initialScrollAnchorY + viewportHeight)
        #expect(visibleRange.contains(pinPoint.midY), "a pin placed low on the page must be visible once the stage opens scrolled to where the operator was, not off past the scrolled viewport")
    }

    @Test func clampKeepsARectFullyInsideItsBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let clamped = CommentCaptureStageView.clamp(CGRect(x: 90, y: -10, width: 40, height: 40), to: bounds)
        #expect(clamped.minX == 60)
        #expect(clamped.minY == 0)
        #expect(clamped.width == 40)
        #expect(clamped.height == 40)
    }
}

/// HAIL-65: lazy captures, empty-capture filtering, delete capture.
struct CommentsModelCaptureCleanupTests {
    private static let rect = Rect(x: 0, y: 0, w: 0.1, h: 0.1)

    @Test func commentedCapturesListsOnlyCapturesWithAComment() {
        var model = CommentsModel()
        let empty = model.addCapture(revision: 1)
        let full = model.addCapture(revision: 1)
        model.addComment(captureId: full.id, rect: Self.rect, text: "a")

        #expect(model.commentedCaptures.map(\.id) == [full.id])
        #expect(!model.commentedCaptures.contains { $0.id == empty.id })
    }

    @Test func deletingACaptureRemovesItsCommentsAndRenumbersTheRest() {
        var model = CommentsModel()
        let first = model.addCapture(revision: 1)
        let second = model.addCapture(revision: 1)
        let third = model.addCapture(revision: 1)
        for capture in [first, second, third] { model.addComment(captureId: capture.id, rect: Self.rect, text: "c") }

        let deleted = model.deleteCapture(id: second.id)
        #expect(deleted)

        #expect(model.captures.map(\.id) == [first.id, third.id])
        #expect(model.captures.map(\.n) == [1, 2], "numbering renumbers only what is left")
        #expect(model.comments.count == 2)
        let deletedAgain = model.deleteCapture(id: second.id)
        #expect(!deletedAgain, "an unknown id is a no-op")
    }

    @Test func pruningDropsEmptyCapturesAndKeepsTheListedOnes() {
        var model = CommentsModel()
        let empty = model.addCapture(revision: 1)
        let full = model.addCapture(revision: 1)
        model.addComment(captureId: full.id, rect: Self.rect, text: "a")

        let removed = model.pruneEmptyCaptures()

        #expect(removed == [empty.id])
        #expect(model.captures.map(\.id) == [full.id])
        #expect(model.captures.first?.n == 1)
    }

    @Test func pruningCanKeepNamedCaptures() {
        var model = CommentsModel()
        let base = model.addCapture(revision: 1)
        let removed = model.pruneEmptyCaptures(keeping: [base.id])
        #expect(removed.isEmpty)
        #expect(model.captures.count == 1)
    }
}
