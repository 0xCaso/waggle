import AppKit
import Foundation
import Testing
@testable import Knock

/// PERF-2: `cases.get` carries no capture images. The app fetches one with
/// `capture.image` when it shows it, and keeps it in memory per capture id.
@MainActor
struct CaptureImageOnDemandTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func hit(_ key: String) { lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
        func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key, default: 0] }
        var total: Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }
    }

    private struct ImageEnvelope: Decodable {
        struct Params: Decodable { let capture_id: String; let which: String }
        let params: Params
    }

    private func png(_ color: NSColor) throws -> String {
        let data = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            color.setFill(); rect.fill(); return true
        }.pngData()
        return try #require(data).base64EncodedString()
    }

    private func startServer(counter: Counter, images: [String: String]) async throws -> (FakeKnockServer, KnockClient) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "capture.image", let id,
                  let params = try? JSONDecoder().decode(ImageEnvelope.self, from: line).params else { return nil }
            counter.hit("\(params.capture_id)|\(params.which)")
            guard let base64 = images["\(params.capture_id)|\(params.which)"] else {
                return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32001,"message":"capture not found"}}"#.utf8 + [10])
            }
            return jsonRPCOK(id: id, result: #"{"capture_id":"\#(params.capture_id)","which":"\#(params.which)","png_base64":"\#(base64)"}"#)
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        return (server, client)
    }

    @Test func aSlimCaptureDecodesWithoutImagesAndNeedsAFetch() throws {
        let json = #"{"id":"cap_1","revision":2,"taken_at":"2026-10-04T10:00:00Z","note":"n","has_image":true}"#
        let capture = try JSONDecoder().decode(Capture.self, from: Data(json.utf8))
        #expect(capture.id == "cap_1")
        #expect(capture.pngBase64.isEmpty && capture.annotatedPngBase64.isEmpty)
        #expect(capture.needsImageFetch)
        let sent = try JSONEncoder().encode(Capture(id: "c", revision: 1, pngBase64: "AA==", annotatedPngBase64: "BB==", takenAt: "t", note: nil))
        #expect(String(decoding: sent, as: UTF8.self).contains("annotated_png_base64"), "a request still carries the images")
    }

    @Test func theClientFetchesAnImageOnceAndServesLaterCallsFromMemory() async throws {
        let counter = Counter()
        let red = try png(.red)
        let (server, client) = try await startServer(counter: counter, images: ["cap_1|raw": red])
        defer { server.stop() }

        let first = await client.captureImageData(captureId: "cap_1", which: .raw)
        let second = await client.captureImageData(captureId: "cap_1", which: .raw)

        #expect(first == Data(base64Encoded: red))
        #expect(second == first)
        #expect(counter.count("cap_1|raw") == 1, "the second read comes from the cache")
        await client.stop()
    }

    @Test func rawAndAnnotatedAreCachedSeparatelyAndAFailureIsNotCached() async throws {
        let counter = Counter()
        let (server, client) = try await startServer(
            counter: counter, images: ["cap_1|raw": try png(.red), "cap_1|annotated": try png(.blue)])
        defer { server.stop() }

        let raw = await client.captureImageData(captureId: "cap_1", which: .raw)
        let annotated = await client.captureImageData(captureId: "cap_1", which: .annotated)
        #expect(raw != annotated)
        #expect(await client.captureImageData(captureId: "missing", which: .raw) == nil)
        #expect(await client.captureImageData(captureId: "missing", which: .raw) == nil)
        #expect(counter.count("missing|raw") == 2, "an unknown capture is asked again")
        await client.stop()
    }

    @Test func changeAnswerRestoresPinnedCapturesFetchingOnlyTheirImages() async throws {
        let counter = Counter()
        let (server, client) = try await startServer(
            counter: counter, images: ["pinned|raw": try png(.red), "empty|raw": try png(.red)])
        defer { server.stop() }
        func slim(_ id: String) -> Capture {
            Capture(id: id, revision: 1, pngBase64: "", annotatedPngBase64: "", takenAt: "2026-10-04T10:00:00Z", note: nil)
        }
        let reply = Reply(
            id: "r1", caseId: "c1", idempotencyKey: "k",
            comments: [Comment(id: "k1", captureId: "pinned", n: 1, rect: Rect(x: 0, y: 0, w: 0.5, h: 0.5), text: "hi")],
            captures: [slim("empty"), slim("pinned")], state: .queued, createdAt: "2026-10-04T10:00:00Z")
        #expect(CommentsSessionStore.restoreNeedsImages(for: reply))

        let store = CommentsSessionStore()
        await store.restore(from: reply, loadingImagesWith: client)

        #expect(store.model.captures.map(\.id) == ["pinned"])
        #expect(store.imagesByCaptureId["pinned"] != nil)
        #expect(store.model.comments.map(\.id) == ["k1"])
        #expect(counter.count("empty|raw") == 0, "a capture without pins is never fetched")
        #expect(counter.count("pinned|raw") == 1)
        await client.stop()
    }

    @Test func anOlderRevisionLoadsItsAnnotatedImagesOnDemand() async throws {
        let counter = Counter()
        let (server, client) = try await startServer(counter: counter, images: ["cap_a|annotated": try png(.green)])
        defer { server.stop() }
        let captures = [
            OlderRevisionCapture(id: "cap_a", image: nil, comments: []),
            OlderRevisionCapture(id: "cap_done", image: NSImage(size: NSSize(width: 1, height: 1)), comments: []),
        ]

        let images = await OlderRevisionDisplay.loadedImages(for: captures, with: client)

        #expect(Set(images.keys) == ["cap_a"])
        #expect(counter.total == 1, "a capture that already has its image is not fetched")
        await client.stop()
    }
}
