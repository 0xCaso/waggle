import AppKit
import Testing
@testable import Knock

/// One ask can hold single screenshots and a screenshots set, each under its own name. The set must
/// load when the comment store holds the stills of the single screenshots already.
@MainActor
struct ScreenSetBesideScreenshotsTests {
    private func image() -> NSImage { NSImage(size: NSSize(width: 40, height: 30)) }
    private func set(_ count: Int) -> [(image: NSImage, caption: String?)] {
        (1...count).map { (image: image(), caption: "Variant \($0)") }
    }

    /// A store that holds the stills of three single screenshots (revisions 2, 3 and 4).
    private func storeWithSingleScreenshots() -> CommentsSessionStore {
        let store = CommentsSessionStore()
        for revision in 2...4 { store.addCapture(image: image(), revision: revision, isBase: true) }
        return store
    }

    @Test func theBoxLoadsTheSetBesideSingleScreenshots() {
        let store = storeWithSingleScreenshots()
        let records = store.replaceScreenshotsCaptures(images: set(2), revision: 5)
        #expect(records.count == 2)
        #expect(store.screens.map(\.id) == records.map(\.id))
        #expect(store.currentCapture?.id == records.first?.id)
        #expect(store.model.captures.count == 5)
    }

    @Test func fullSizeLoadsTheSetBesideSingleScreenshots() {
        let store = storeWithSingleScreenshots()
        let records = store.addScreenshotsCaptures(images: set(2), revision: 5)
        #expect(records.count == 2)
        #expect(store.screens.map(\.id) == records.map(\.id))
        #expect(records.last.flatMap(store.screenLabel(for:)) == "Screen 2 · Variant 2")
    }

    @Test func aSecondLoadOfTheSameSetAddsNothing() {
        let store = storeWithSingleScreenshots()
        store.replaceScreenshotsCaptures(images: set(2), revision: 5)
        #expect(store.addScreenshotsCaptures(images: set(2), revision: 5).isEmpty)
        #expect(store.replaceScreenshotsCaptures(images: set(2), revision: 5).isEmpty)
        #expect(store.screens.count == 2)
    }

    @Test func aSingleScreenshotLoadedAfterTheSetIsNotAScreen() {
        let store = CommentsSessionStore()
        store.addScreenshotsCaptures(images: set(2), revision: 5)
        store.addCapture(image: image(), revision: 5, isBase: false)
        store.addCapture(image: image(), revision: 4, isBase: true)
        #expect(store.screens.count == 2)
    }

    @Test func aCommentOnAnEarlierScreenshotStaysWhenTheSetLoads() {
        let store = storeWithSingleScreenshots()
        let old = store.model.captures[2]
        store.selectCapture(id: old.id)
        store.beginDraft(rect: Rect(x: 0.1, y: 0.2, w: 0.3, h: 0.1))
        store.updateDraftText("Keep this")
        _ = store.commitDraft()
        store.replaceScreenshotsCaptures(images: set(2), revision: 5)
        #expect(store.model.comments.count == 1)
        #expect(store.screens.count == 2)
        #expect(!store.screens.contains { $0.id == old.id })
    }
}
