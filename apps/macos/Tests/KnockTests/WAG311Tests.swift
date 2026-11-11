import AppKit
import Testing
@testable import Knock

/// WAG-311: Comment mode on the case page box, and the Recommended pill in a tight row.
@MainActor
struct WAG311Tests {
    private let client = KnockClient(socketPath: "/nonexistent.sock", startDaemon: {})
    private let rect = Rect(x: 0.2, y: 0.3, w: 0.1, h: 0.1)

    private func tab(_ id: String, _ kind: ArtifactKind, revision: Int = 1) -> ArtifactTab {
        ArtifactTab(id: id, title: id, revision: revision, kind: kind, hasName: true)
    }

    /// A box on two screenshot tabs; each tab loads as a still because the fake socket has no artifact.
    private func box(canComment: Bool = true) async -> (LiveArtifactModel, CommentsSessionStore) {
        let store = CommentsSessionStore()
        let tabs = [tab("one", .screenshot, revision: 1), tab("two", .screenshots, revision: 2)]
        let model = LiveArtifactModel(caseId: "c1", client: client, tabs: tabs, commentsStore: store)
        for tab in tabs { await model.load(tab) }
        model.setCanComment(canComment)
        return (model, store)
    }

    @Test func aScreenshotOffersCommentAloneAndALockedAnswerOffersNothing() async {
        let (model, _) = await box()
        #expect(model.tools(for: model.selectedTab) == [.comment])
        model.setCanComment(false)
        #expect(model.tools(for: model.selectedTab).isEmpty)
    }

    @Test func aBoxWithoutAStoreOffersNoTool() async {
        let model = LiveArtifactModel(caseId: "c1", client: client, tabs: [tab("one", .screenshot)])
        await model.load(tab("one", .screenshot))
        model.setCanComment(true)
        #expect(model.tools(for: model.selectedTab).isEmpty)
    }

    @Test func aWriteUpAndAPageStillLoadingHaveNoTool() {
        let model = LiveArtifactModel(
            caseId: "c1", client: client, tabs: [tab("doc", .markdown)], commentsStore: CommentsSessionStore())
        model.setCanComment(true)
        #expect(model.tools(for: model.selectedTab).isEmpty)
    }

    @Test func theCKeyTogglesCommentModeAndTheLockTurnsItOff() async {
        let (model, _) = await box()
        #expect(model.mode == .interact)
        await model.toggleCommentMode()
        #expect(model.mode == .comment)
        await model.toggleCommentMode()
        #expect(model.mode == .interact)
        await model.enterCommentMode()
        model.setCanComment(false)
        #expect(model.mode == .interact)
        await model.enterCommentMode()
        #expect(model.mode == .interact)
    }

    @Test func escLeavesCommentModeButNotWhileANoteIsOpen() async {
        let (model, store) = await box()
        #expect(!model.handleEscape())
        await model.enterCommentMode()
        let capture = store.addCapture(image: NSImage(size: NSSize(width: 40, height: 30)), revision: 1, isBase: true)
        store.beginDraft(rect: rect, on: capture.id)
        #expect(!model.handleEscape())
        #expect(model.mode == .comment)
        store.cancelDraft()
        #expect(model.handleEscape())
        #expect(model.mode == .interact)
    }

    @Test func anotherTabPutsTheBoxBackToInteractAndDropsTheNote() async {
        let (model, store) = await box()
        await model.enterCommentMode()
        let capture = store.addCapture(image: NSImage(size: NSSize(width: 40, height: 30)), revision: 1, isBase: true)
        store.beginDraft(rect: rect, on: capture.id)
        model.select("one")
        #expect(model.mode == .interact)
        #expect(store.draftPin == nil)
    }

    @Test func aCapturedScreenshotShowsItsStageOnlyInCommentMode() async {
        let (model, store) = await box()
        let capture = store.addCapture(image: NSImage(size: NSSize(width: 40, height: 30)), revision: 1, isBase: true)
        model.select("one")
        let one = model.selectedTab!
        #expect(!model.showsCaptureStage(for: one))
        await model.enterCommentMode()
        #expect(model.showsCaptureStage(for: one))
        #expect(store.shownStill(revision: 1)?.id == capture.id)
    }

    @Test func theSavedNoteIsACommentOnTheCapture() async {
        let (model, store) = await box()
        model.select("one")
        await model.enterCommentMode()
        let capture = store.addCapture(image: NSImage(size: NSSize(width: 40, height: 30)), revision: 1, isBase: true)
        store.beginDraft(rect: rect, on: capture.id)
        store.updateDraftText("Too tight")
        _ = store.commitDraft()
        #expect(store.model.comments.count == 1)
        #expect(store.model.comments(on: capture.id).first?.text == "Too tight")
    }

    // MARK: Recommended pill

    @Test func thePillShowsTheWholeWordWhenItFitsAndOnlyTheMarkWhenItDoesNot() {
        #expect(CalmOption.recommendedPillText(availableWidth: 100, fullWidth: 96) == "★ Recommended")
        #expect(CalmOption.recommendedPillText(availableWidth: 96, fullWidth: 96) == "★ Recommended")
        #expect(CalmOption.recommendedPillText(availableWidth: 95.5, fullWidth: 96) == "★")
        #expect(CalmOption.recommendedPillText(availableWidth: 0, fullWidth: 96) == "★")
    }

    @Test func thePillNeverShowsACutWord() {
        for width in stride(from: CGFloat(0), through: 140, by: 1) {
            let text = CalmOption.recommendedPillText(availableWidth: width, fullWidth: 96)
            #expect(text == "★" || text == "★ Recommended")
        }
    }
}
