import Testing
import Foundation
import AppKit
@testable import Knock

/// Delete then Undo for a comment: it returns with its text and place, and the Undo ends after its window.
@MainActor
struct CommentUndoTests {
    private let rect = Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.2)

    private func addComment(_ store: CommentsSessionStore, on captureId: String, _ text: String) -> Knock.Comment? {
        store.beginDraft(rect: rect, on: captureId)
        store.updateDraftText(text)
        return store.commitDraft()
    }

    @Test func modelRestoresTextAndPlace() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        let a = model.addComment(captureId: capture.id, rect: rect, text: "A")
        let b = model.addComment(captureId: capture.id, rect: rect, text: "B")
        let c = model.addComment(captureId: capture.id, rect: rect, text: "C")

        let deleted = model.deleteComment(id: b.id)
        #expect(model.orderedComments.map(\.text) == ["A", "C"])
        #expect(model.orderedComments.map(\.n) == [1, 2])

        model.restoreComment(try! #require(deleted))
        #expect(model.orderedComments.map(\.id) == [a.id, b.id, c.id])
        #expect(model.orderedComments.map(\.text) == ["A", "B", "C"])
        #expect(model.orderedComments.map(\.n) == [1, 2, 3])
    }

    @Test func storeUndoRestoresTheCommentAndItsCapture() throws {
        let store = CommentsSessionStore()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        let capture = store.addCapture(image: image, revision: 1)
        let comment = try #require(addComment(store, on: capture.id, "Keep this"))

        store.deleteCommentWithUndo(id: comment.id)
        #expect(store.model.comments.isEmpty)
        #expect(store.commentUndo != nil)

        store.undoDeleteComment()
        #expect(store.commentUndo == nil)
        #expect(store.model.comments.map(\.text) == ["Keep this"])
        #expect(store.model.captures.map(\.id) == [capture.id])
        #expect(store.imagesByCaptureId[capture.id] != nil)
    }

    @Test func undoEndsAfterItsWindow() async throws {
        let store = CommentsSessionStore()
        store.undoWindow = .milliseconds(30)
        let capture = store.addCapture(image: NSImage(size: NSSize(width: 4, height: 4)), revision: 1)
        let comment = try #require(addComment(store, on: capture.id, "Gone"))
        store.deleteCommentWithUndo(id: comment.id)
        #expect(store.commentUndo != nil)

        // A loaded full run can hold the main actor for seconds.
        let deadline = Date().addingTimeInterval(30)
        while store.commentUndo != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.commentUndo == nil)

        store.undoDeleteComment()
        #expect(store.model.comments.isEmpty, "Undo after the window does nothing")
    }
}
