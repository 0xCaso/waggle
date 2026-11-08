import AppKit
import Testing
@testable import Knock

/// WAG-347: Comment on a screenshot, a set, a prototype or a diagram in the case box opens it full size, on the same screen or page.
@MainActor
struct WAG347Tests {
    private let client = KnockClient(socketPath: "/nonexistent.sock", startDaemon: {})

    private func tab(_ id: String, _ kind: ArtifactKind, revision: Int = 1) -> ArtifactTab {
        ArtifactTab(id: id, title: id, revision: revision, kind: kind, hasName: true)
    }

    private func image() -> (image: NSImage, caption: String?) { (NSImage(size: NSSize(width: 40, height: 30)), nil) }

    private func box(_ kind: ArtifactKind) async -> (LiveArtifactModel, CommentsSessionStore) {
        let store = CommentsSessionStore()
        let tabs = [tab("one", kind)]
        let model = LiveArtifactModel(caseId: "c1", client: client, tabs: tabs, commentsStore: store)
        await model.load(tabs[0])
        model.setCanComment(true)
        return (model, store)
    }

    @Test func everyKindOfTheBoxHasItsRouteAndOnlyAWriteUpStaysInline() {
        let model = LiveArtifactModel(caseId: "c1", client: client, tabs: [], commentsStore: CommentsSessionStore())
        #expect(model.commentRoute(for: tab("a", .screenshot)) == .fullSize)
        #expect(model.commentRoute(for: tab("b", .screenshots)) == .fullSize)
        #expect(model.commentRoute(for: tab("c", .htmlBundle)) == .fullSize)
        #expect(model.commentRoute(for: tab("d", .diagram)) == .fullSize)
        #expect(model.commentRoute(for: tab("e", .markdown)) == .inline)
    }

    @Test func commentOnASetOpensFullSizeOnTheSameScreenAndLeavesTheBoxInInteract() async {
        let (model, store) = await box(.screenshots)
        let records = store.addScreenshotsCaptures(images: [image(), image(), image()], revision: 1)
        store.selectCapture(id: records[1].id)
        var opened = 0
        await model.startComment { opened += 1 }
        #expect(opened == 1)
        #expect(model.mode == .interact)
        #expect(store.selectedCaptureId == records[1].id)
    }

    @Test func commentOnAScreenshotOpensFullSize() async {
        let (model, _) = await box(.screenshot)
        var opened = 0
        await model.startComment { opened += 1 }
        #expect(opened == 1)
        #expect(model.mode == .interact)
    }

    @Test func aLockedAnswerOpensNothing() async {
        let (model, _) = await box(.screenshots)
        model.setCanComment(false)
        var opened = 0
        await model.startComment { opened += 1 }
        #expect(opened == 0)
    }

    @Test func aPrototypeRoutesCommentToFullSize() {
        let model = LiveArtifactModel(caseId: "c1", client: client, tabs: [], commentsStore: CommentsSessionStore())
        #expect(model.commentRoute(for: tab("p", .htmlBundle)) == .fullSize)
    }

    @Test func aDiagramRoutesCommentToFullSize() {
        let model = LiveArtifactModel(caseId: "c1", client: client, tabs: [], commentsStore: CommentsSessionStore())
        #expect(model.commentRoute(for: tab("g", .diagram)) == .fullSize)
    }

    @Test func aWriteUpKeepsCommentingInTheBox() {
        let model = LiveArtifactModel(caseId: "c1", client: client, tabs: [], commentsStore: CommentsSessionStore())
        #expect(model.commentRoute(for: tab("m", .markdown)) == .inline)
    }

    @Test func aScreenshotLeavesNoPageHandoff() async {
        let (model, _) = await box(.screenshot)
        await model.startComment {}
        #expect(model.takeCommentHandoff() == nil)
    }
}
