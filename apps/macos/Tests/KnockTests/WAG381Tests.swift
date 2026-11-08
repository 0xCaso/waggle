import AppKit
import Foundation
import Testing
@testable import Knock

/// WAG-381: full size follows the decision on screen, with the rule of the case box (`DecisionArtifactRule`).
@MainActor
struct WAG381Tests {
    private func shot(_ width: Int) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let path = dir.appendingPathComponent("shot.png").path
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func notes() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("notes.md").path
        try "# Notes".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Revision 1 is a named set of `count` images; revision 2 is a named write-up.
    private func fixture(count: Int) async throws -> (ReviewViewModel, FakeKnockServer) {
        let images = try (0..<count).map { try shot(10 + $0) }
        let items = images.map { #"{"path":"\#($0)"}"# }.joined(separator: ",")
        let setJSON = #"{"kind":"screenshots","root":"","entry":"","items":[\#(items)]}"#
        let notesJSON = #"{"kind":"markdown","root":"\#(try notes())","entry":""}"#
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id, method == "artifact.path" else { return nil }
            let text = String(decoding: line, as: UTF8.self)
            return jsonRPCOK(id: id, result: text.contains(#""revision":2"#) ? notesJSON : setJSON)
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        let json = #"""
        {"case":{"id":"c_1","task_id":"t_1","kind":"review","title":"Survey","need":"Pick.","why":"Why.",
          "recommendation":"a","recommendation_why":"x","options":[{"id":"a","label":"A"}],
          "status":"needs_you","has_artifact":true,"runtime":"claude","created_at":"2026-10-16T10:00:00Z",
          "updated_at":"2026-10-16T10:41:00Z"},
         "task":{"id":"t_1","name":"Survey","project":"omea"},
         "messages":[],"revisions":[
           {"id":"r_1","case_id":"c_1","n":1,"created_at":"2026-10-16T10:00:00Z","name":"screenshots","kind":"screenshots"},
           {"id":"r_2","case_id":"c_1","n":2,"created_at":"2026-10-16T10:01:00Z","name":"Notes","kind":"markdown"}],
         "comments":[],"replies":[]}
        """#
        let model = ReviewViewModel(client: client)
        await model.load(detail: try JSONDecoder().decode(CaseDetail.self, from: Data(json.utf8)), revision: 1)
        return (model, server)
    }

    private func focus(_ index: Int, count: Int = 3, options: [Option] = []) -> DecisionFocus {
        DecisionFocus(index: index, count: count, options: options, chosen: [], recommended: [])
    }

    @Test func fullSizeFlipsToImageKForDecisionK() async throws {
        let (model, server) = try await fixture(count: 3)
        defer { server.stop() }
        let store = model.commentsStore
        await model.follow(decision: focus(1))
        #expect(store.currentCapture?.id == store.screens[1].id)
        await model.follow(decision: focus(2))
        #expect(store.currentCapture?.id == store.screens[2].id)
        await model.follow(decision: focus(0))
        #expect(store.currentCapture?.id == store.screens[0].id)
    }

    @Test func aManualFlipStaysUntilTheDecisionChanges() async throws {
        let (model, server) = try await fixture(count: 3)
        defer { server.stop() }
        let store = model.commentsStore
        await model.follow(decision: focus(1))
        model.stepScreen(by: 1)
        #expect(store.currentCapture?.id == store.screens[2].id, "the person's flip")
        await model.follow(decision: focus(0))
        #expect(store.currentCapture?.id == store.screens[0].id)
    }

    @Test func aTabAndAnAnchorTargetWorkInFullSize() async throws {
        let (model, server) = try await fixture(count: 3)
        defer { server.stop() }
        let option = Option(id: "a", label: "A", artifactRef: "Notes", anchor: "intro")
        await model.follow(decision: focus(0, options: [option]))
        #expect(model.artifactState.revision == 2)
        #expect(model.shownTab?.id == "name:notes")
        #expect(model.anchorRequest?.anchor == "intro")
        // Back to the set: the decision names no tab and the images are as many as the decisions.
        await model.follow(decision: focus(1, options: [Option(id: "b", label: "B", artifactRef: "screenshots", anchor: "3")]))
        #expect(model.artifactState.revision == 1)
        #expect(model.commentsStore.currentCapture?.id == model.commentsStore.screens[2].id)
    }
}
