import Testing
import Foundation
import AppKit
@testable import Knock

/// HAIL-114: an open ask shows a newer revision at once. Each test loads revision 1, then sends
/// the detail with revision 2 (the staged files reuse the same names in another folder, as the
/// daemon stages them) and checks the viewer holds revision 2.
private final class Served: @unchecked Sendable {
    var json = ""
}

private func detail(revisions: Int) throws -> CaseDetail {
    let list = (1...revisions).map { n in
        #"{"id":"r_\#(n)","case_id":"c_1","n":\#(n),"created_at":"2026-09-26T10:00:00Z"}"#
    }.joined(separator: ",")
    let json = #"""
    {"case":{"id":"c_1","task_id":"t_1","kind":"review","title":"Checkout layout",
      "need":"Pick A or B.","why":"Both meet spec.","recommendation":"a","recommendation_why":"68%","options":[{"id":"a","label":"Compact"}],
      "status":"needs_you","has_artifact":true,"runtime":"claude","created_at":"2026-09-26T10:00:00Z",
      "updated_at":"2026-09-26T10:41:00Z"},
     "task":{"id":"t_1","name":"Checkout redesign","project":"omea-web"},
     "messages":[],"revisions":[\#(list)],"comments":[],"replies":[]}
    """#
    return try JSONDecoder().decode(CaseDetail.self, from: Data(json.utf8))
}

/// A PNG of the given size, written as `shot.png` in a fresh folder.
private func writeShot(width: Int) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let path = dir.appendingPathComponent("shot.png").path
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    return path
}

private func writeBundle() throws -> (dir: URL, entry: String) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "<!doctype html><title>x</title>".write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    return (dir, dir.appendingPathComponent("index.html").path)
}

private func screenshotsJSON(_ paths: [String]) -> String {
    let items = paths.map { #"{"path":"\#($0)"}"# }.joined(separator: ",")
    return #"{"kind":"screenshots","root":"","entry":"","items":[\#(items)]}"#
}

@MainActor
struct RevisionRefreshTests {
    private func makeModel(served: Served) async throws -> (ReviewViewModel, FakeKnockServer) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: served.json)
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        return (ReviewViewModel(client: client), server)
    }

    @Test func aNewScreenshotRevisionReplacesTheImageInPlace() async throws {
        let served = Served()
        let first = try writeShot(width: 10), second = try writeShot(width: 40)
        served.json = #"{"kind":"screenshot","root":"\#(first)","entry":""}"#
        let (model, server) = try await makeModel(served: served)
        defer { server.stop() }
        await model.load(detail: try detail(revisions: 1))
        #expect(model.commentsStore.currentImage?.size.width == 10)

        served.json = #"{"kind":"screenshot","root":"\#(second)","entry":""}"#
        await model.refresh(detail: try detail(revisions: 2))

        #expect(model.artifactState.revision == 2)
        #expect(model.commentsStore.currentCapture?.revision == 2)
        #expect(model.commentsStore.currentImage?.size.width == 40, "the new image shows, not the old one")
        #expect(model.mode == .comment)
    }

    @Test func aNewGalleryKeepsTheScreenIndexAndDropsTheOldScreens() async throws {
        let served = Served()
        let old = try (0..<3).map { try writeShot(width: 10 + $0) }
        let new = try (0..<3).map { try writeShot(width: 50 + $0) }
        served.json = screenshotsJSON(old)
        let (model, server) = try await makeModel(served: served)
        defer { server.stop() }
        await model.load(detail: try detail(revisions: 1))
        model.stepScreen(by: 1)

        served.json = screenshotsJSON(new)
        await model.refresh(detail: try detail(revisions: 2))

        let store = model.commentsStore
        #expect(model.artifactState.revision == 2)
        #expect(store.screens.count == 3)
        #expect(store.screens.allSatisfy { $0.revision == 2 })
        #expect(store.currentCapture?.id == store.screens[1].id, "still on screen 2")
        #expect(store.currentImage?.size.width == 51)
        #expect(store.model.captures.count == 3, "the old empty screens are gone")
    }

    @Test func aGalleryUpdateKeepsPinsOnTheRevisionTheyWereMadeOn() async throws {
        let served = Served()
        let old = try (0..<2).map { try writeShot(width: 10 + $0) }
        served.json = screenshotsJSON(old)
        let (model, server) = try await makeModel(served: served)
        defer { server.stop() }
        await model.load(detail: try detail(revisions: 1))
        let store = model.commentsStore
        let firstId = store.screens[0].id
        store.selectCapture(id: firstId)
        store.beginDraft(rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.2))
        store.updateDraftText("Add a dashed line.")
        store.commitDraft()

        served.json = screenshotsJSON([try writeShot(width: 70), try writeShot(width: 71), try writeShot(width: 72)])
        await model.refresh(detail: try detail(revisions: 2))

        #expect(store.model.comments.count == 1)
        #expect(store.model.captures.first { $0.id == firstId }?.revision == 1, "the pin stays on revision 1")
        #expect(store.screens.count == 3)
        #expect(store.screens.allSatisfy { $0.revision == 2 })
        #expect(store.screenTitle(for: store.screens[0]) == "Screen 1", "screen numbers count the new gallery only")
    }

    @Test func aNewPrototypeRevisionPointsTheViewerAtTheNewBundle() async throws {
        let served = Served()
        let one = try writeBundle(), two = try writeBundle()
        served.json = #"{"kind":"html_bundle","root":"\#(one.dir.path)","entry":"\#(one.entry)"}"#
        let (model, server) = try await makeModel(served: served)
        defer { server.stop() }
        await model.load(detail: try detail(revisions: 1))

        served.json = #"{"kind":"html_bundle","root":"\#(two.dir.path)","entry":"\#(two.entry)"}"#
        await model.refresh(detail: try detail(revisions: 2))

        guard case .htmlBundle(let entry, _, let revision, _) = model.artifactState else {
            Issue.record("expected .htmlBundle, got \(model.artifactState)")
            return
        }
        #expect(revision == 2)
        #expect(entry.path == URL(fileURLWithPath: two.entry).resolvingSymlinksInPath().path)
        #expect(model.mode == .interact, "the mode stays")
    }

    @Test func aDetailWithoutANewRevisionChangesNothing() async throws {
        let served = Served()
        let first = try writeShot(width: 10)
        served.json = #"{"kind":"screenshot","root":"\#(first)","entry":""}"#
        let (model, server) = try await makeModel(served: served)
        defer { server.stop() }
        await model.load(detail: try detail(revisions: 2))
        let count = model.commentsStore.model.captures.count
        await model.refresh(detail: try detail(revisions: 2))
        #expect(model.commentsStore.model.captures.count == count)
    }

    @Test func theWebViewReloadsOnlyForAnotherEntry() {
        let a = URL(fileURLWithPath: "/b/c/r1/index.html"), b = URL(fileURLWithPath: "/b/c/r2/index.html")
        #expect(!SandboxedHTMLView.needsReload(loaded: a, entry: a))
        #expect(SandboxedHTMLView.needsReload(loaded: a, entry: b))
    }

}
