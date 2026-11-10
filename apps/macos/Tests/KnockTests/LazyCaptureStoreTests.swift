import Testing
import Foundation
import AppKit
@testable import Knock

/// HAIL-65: a capture exists only once it has a comment; comments and
/// captures can be deleted and edited, with the counts following at once.
@MainActor
struct LazyCaptureStoreTests {
    private static let rect = Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.1)

    private static func snapshot(_ image: NSImage? = NSImage(size: NSSize(width: 4, height: 4))) -> Task<NSImage?, Never> {
        Task { image }
    }

    private static func place(_ store: CommentsSessionStore, text: String, revision: Int = 1) async -> Knock.Comment? {
        store.beginPendingDraft(rect: rect, revision: revision, snapshot: snapshot())
        store.updateDraftText(text)
        return await store.commitDraftAwaitingCapture()
    }

    @Test func aPendingDraftCreatesNoCaptureUntilItsNoteIsSaved() async {
        let store = CommentsSessionStore()
        store.beginPendingDraft(rect: Self.rect, revision: 1, snapshot: Self.snapshot())

        #expect(store.model.captures.isEmpty)
        #expect(store.commentedCaptures.isEmpty)
        #expect(store.pending != nil)

        store.updateDraftText("Make it blue")
        let comment = await store.commitDraftAwaitingCapture()

        #expect(comment?.text == "Make it blue")
        #expect(store.model.captures.count == 1)
        #expect(store.commentedCaptures.count == 1)
        #expect(store.imagesByCaptureId[comment!.captureId] != nil)
        #expect(store.pending == nil)
    }

    @Test func cancellingOrSavingAnEmptyNoteLeavesNoCapture() async {
        let store = CommentsSessionStore()
        store.beginPendingDraft(rect: Self.rect, revision: 1, snapshot: Self.snapshot())
        store.cancelDraft()
        #expect(store.model.captures.isEmpty)
        #expect(store.pending == nil)

        store.beginPendingDraft(rect: Self.rect, revision: 1, snapshot: Self.snapshot())
        store.updateDraftText("   ")
        let comment = await store.commitDraftAwaitingCapture()
        #expect(comment == nil)
        #expect(store.model.captures.isEmpty)
    }

    /// HAIL-112: root cause. The save used to wait for the snapshot, so the
    /// comment did not count (and Send stayed unlabelled) until it arrived.
    @Test func aCommentCountsBeforeItsSnapshotArrives() async {
        let store = CommentsSessionStore()
        let gate = AsyncStream<Void>.makeStream()
        let slow = Task<NSImage?, Never> {
            for await _ in gate.stream { break }
            return NSImage(size: NSSize(width: 4, height: 4))
        }
        store.beginPendingDraft(rect: Self.rect, revision: 1, snapshot: slow)
        store.updateDraftText("Make it blue")

        let comment = store.commitDraftNow()

        #expect(comment?.text == "Make it blue")
        #expect(store.model.comments.count == 1, "counts at once, synchronously")
        #expect(store.draftPin == nil)

        gate.continuation.yield()
        await store.settleCaptures()
        #expect(store.imagesByCaptureId[comment!.captureId] != nil, "the picture fills in afterwards")
        #expect(store.captureNotice == nil)
    }

    @Test func aFailedSnapshotKeepsTheCommentAndSaysSo() async {
        let store = CommentsSessionStore()
        store.beginPendingDraft(rect: Self.rect, revision: 1, snapshot: Self.snapshot(nil))
        store.updateDraftText("no image")
        let comment = await store.commitDraftAwaitingCapture()

        #expect(comment?.text == "no image")
        #expect(store.model.comments.count == 1)
        #expect(store.imagesByCaptureId[comment!.captureId] != nil, "a stand-in keeps the reply sendable")
        #expect(store.captureNotice != nil)
    }

    @Test func aSecondCommentOnTheSameCaptureReusesIt() async {
        let store = CommentsSessionStore()
        let first = await Self.place(store, text: "one")
        store.beginDraft(rect: Self.rect, on: first!.captureId)
        store.updateDraftText("two")
        let second = await store.commitDraftAwaitingCapture()

        #expect(second?.captureId == first?.captureId)
        #expect(store.model.captures.count == 1)
        #expect(second?.n == 2)
    }

    @Test func deletingTheLastCommentRemovesItsCaptureAndRenumbers() async {
        let store = CommentsSessionStore()
        let a = await Self.place(store, text: "a")
        let b = await Self.place(store, text: "b")
        let c = await Self.place(store, text: "c")
        #expect(store.model.captures.map(\.n) == [1, 2, 3])

        store.deleteComment(id: b!.id)

        #expect(store.model.captures.map(\.id) == [a!.captureId, c!.captureId])
        #expect(store.model.captures.map(\.n) == [1, 2])
        #expect(store.imagesByCaptureId[b!.captureId] == nil)
        #expect(store.model.comments.count == 2, "the badge count follows at once")
    }

    @Test func deletingACaptureDropsItsCommentsAndImage() async {
        let store = CommentsSessionStore()
        let a = await Self.place(store, text: "a")
        store.beginDraft(rect: Self.rect, on: a!.captureId)
        store.updateDraftText("a2")
        await store.commitDraftAwaitingCapture()
        let b = await Self.place(store, text: "b")
        #expect(store.model.comments.count == 3)

        store.deleteCapture(id: a!.captureId)

        #expect(store.model.comments.map(\.id) == [b!.id])
        #expect(store.model.captures.map(\.n) == [1])
        #expect(store.imagesByCaptureId[a!.captureId] == nil)
    }

    @Test func aBaseCaptureIsNeverListedWhileEmptyAndSurvivesItsLastDelete() {
        let store = CommentsSessionStore()
        let base = store.addCapture(image: NSImage(), revision: 1, isBase: true)
        #expect(store.commentedCaptures.isEmpty, "an empty capture is not listed")

        store.beginDraft(rect: Self.rect)
        store.updateDraftText("on the screenshot")
        let comment = store.commitDraft()
        #expect(store.commentedCaptures.map(\.id) == [base.id])

        store.deleteComment(id: comment!.id)

        #expect(store.model.captures.map(\.id) == [base.id], "the screenshot itself must stay to comment on")
        #expect(store.commentedCaptures.isEmpty)
    }

    @Test func deletingABaseCaptureOnlyClearsItsComments() {
        let store = CommentsSessionStore()
        let base = store.addCapture(image: NSImage(), revision: 1, isBase: true)
        store.beginDraft(rect: Self.rect)
        store.updateDraftText("x")
        store.commitDraft()

        store.deleteCapture(id: base.id)

        #expect(store.model.captures.count == 1)
        #expect(store.model.comments.isEmpty)
    }

    @Test func editingACommentChangesOnlyItsText() async {
        let store = CommentsSessionStore()
        let comment = await Self.place(store, text: "old")

        store.updateComment(id: comment!.id, text: "new")

        let edited = store.model.comments(on: comment!.captureId).first
        #expect(edited?.text == "new")
        #expect(edited?.rect == comment?.rect)
        #expect(edited?.n == 1)
    }

    @Test func restoringAReplyDropsCapturesWithoutComments() throws {
        let store = CommentsSessionStore()
        let png = try #require(NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }.pngData())
        let base64 = png.base64EncodedString()
        func capture(_ id: String) -> Capture {
            Capture(id: id, revision: 1, pngBase64: base64, annotatedPngBase64: base64, takenAt: "2026-09-29T10:00:00Z", note: nil)
        }
        let reply = Reply(
            id: "r1", caseId: "c1", idempotencyKey: "k",
            comments: [Comment(id: "k1", captureId: "full", n: 1, rect: Rect(x: 0, y: 0, w: 0.5, h: 0.5), text: "hi")],
            captures: [capture("empty"), capture("full")],
            state: .queued, createdAt: "2026-09-29T10:00:00Z"
        )

        store.restore(from: reply)

        #expect(store.model.captures.map(\.id) == ["full"])
        #expect(store.model.captures.first?.n == 1)
        #expect(store.imagesByCaptureId["empty"] == nil)
    }
}
