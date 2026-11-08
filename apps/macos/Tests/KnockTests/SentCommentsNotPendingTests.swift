import Testing
import AppKit
import Foundation
@testable import Knock

private struct SubmitEnvelope: Decodable { let params: PendingReply }

private func queuedReplyJSON(key: String) -> String {
    #"""
    {"id":"reply_1","case_id":"c1","idempotency_key":"\#(key)","choice":null,"message":"go",
     "comments":[],"captures":[],"state":"queued","created_at":"2026-10-10T10:00:00Z"}
    """#
}

/// WAG-358: comments and captures that went out with a sent reply are not pending in a later round.
@Suite(.serialized)
@MainActor
struct SentCommentsNotPendingTests {
    private static let rect = Rect(x: 0.1, y: 0.2, w: 0.3, h: 0.1)
    private static let image = NSImage(size: NSSize(width: 4, height: 4))

    private func tempHome() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock_sent_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func comment(_ store: CommentsSessionStore, on screen: CaptureRecord, _ text: String) -> Knock.Comment {
        store.selectCapture(id: screen.id)
        store.beginDraft(rect: Self.rect)
        store.updateDraftText(text)
        return store.commitDraft()!
    }

    @Test func aSentScreenCommentIsNotPendingAfterTheRevisionChanges() {
        let store = CommentsSessionStore()
        let screens = store.addScreenshotsCaptures(images: [(Self.image, nil), (Self.image, nil)], revision: 3)
        let sent = comment(store, on: screens[0], "round 3")

        store.dropSent(commentIds: [sent.id])
        _ = store.replaceScreenshotsCaptures(images: [(Self.image, nil), (Self.image, nil)], revision: 9)

        #expect(store.model.comments.isEmpty)
        #expect(store.model.captures.allSatisfy { $0.revision == 9 }, "no capture 'from v3' stays behind")
        #expect(store.screens.count == 2)
    }

    @Test func withoutDropSentACommentedScreenStaysOnItsOldRevision() {
        // The old behaviour the fix guards: an unsent pin stays on the revision it was made on.
        let store = CommentsSessionStore()
        let screens = store.addScreenshotsCaptures(images: [(Self.image, nil)], revision: 3)
        _ = comment(store, on: screens[0], "unsent")

        _ = store.replaceScreenshotsCaptures(images: [(Self.image, nil)], revision: 9)

        #expect(store.model.comments.count == 1)
    }

    @Test func aSentCommentDoesNotComeBackAfterAChangeOfArtifactKind() {
        let store = CommentsSessionStore()
        let screens = store.addScreenshotsCaptures(images: [(Self.image, nil)], revision: 3)
        let sent = comment(store, on: screens[0], "round 3")
        let keptLater = comment(store, on: screens[0], "typed after the send")

        store.dropSent(commentIds: [sent.id])
        #expect(store.model.comments.map(\.id) == [keptLater.id], "a comment added after the send stays")

        // screenshots -> html_bundle (the store resets) -> screenshots again
        store.resetArtifactCaptures()
        _ = store.addScreenshotsCaptures(images: [(Self.image, nil)], revision: 7)
        #expect(store.model.comments.isEmpty)
        #expect(store.model.captures.allSatisfy { $0.revision == 7 })
    }

    @Test func dropSentRemovesALiveCaptureThatHeldOnlySentComments() async {
        let store = CommentsSessionStore()
        store.beginPendingDraft(rect: Self.rect, revision: 2, snapshot: Task { Self.image })
        store.updateDraftText("live")
        let sent = await store.commitDraftAwaitingCapture()!

        store.dropSent(commentIds: [sent.id])

        #expect(store.model.comments.isEmpty)
        #expect(store.model.captures.isEmpty)
    }

    @Test func aDeliveredSendTellsTheCoordinatorsListener() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let params = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params else { return nil }
            return jsonRPCOK(id: id, result: queuedReplyJSON(key: params.idempotencyKey))
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let store = CommentsSessionStore()
        let screens = store.addScreenshotsCaptures(images: [(Self.image, nil)], revision: 3)
        let sent = comment(store, on: screens[0], "round 3")
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        coordinator.onDelivered = { reply in store.dropSent(commentIds: Set(reply.comments.map(\.id))) }

        // The reply goes out by a path that never runs the send flow's own clean-up (a reconnect resubmit).
        try await coordinator.send(PendingReply(caseId: "c1", idempotencyKey: "k", choice: nil, message: "go", comments: [sent], captures: []))

        #expect(store.model.comments.isEmpty)
        await client.stop()
    }

    /// Retry after the daemon answered "Internal error": the saved reply is kept, and the next try succeeds.
    @Test func retryAfterAnInternalErrorSendsTheSavedReplyAndSucceeds() async throws {
        let socketPath = makeTempSocketPath()
        let calls = SentKeys()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let params = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params else { return nil }
            calls.append(params.idempotencyKey)
            if calls.values.count == 1 {
                return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32603,"message":"Internal error","data":{"message":"UNIQUE constraint failed: captures.id"}}}"#.utf8)
            }
            return jsonRPCOK(id: id, result: queuedReplyJSON(key: params.idempotencyKey))
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let pendingStore = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        let capture = Capture(id: "cap_old", revision: 3, pngBase64: "AAAA", annotatedPngBase64: "BBBB", takenAt: "2026-10-10T10:00:00Z", note: nil)
        let reply = PendingReply(caseId: "c1", idempotencyKey: "key-1", choice: nil, message: "go", comments: [], captures: [capture])
        let vm = DeliveryStateViewModel(coordinator: SendCoordinator(client: client, store: pendingStore), client: client)

        let first = await vm.send(reply)
        #expect(first == .refused(reason: "UNIQUE constraint failed: captures.id"), "the banner shows the real cause")
        #expect(pendingStore.load(caseId: "c1") != nil, "the saved reply stays recoverable")

        let second = await vm.retry()
        #expect(second == .sent)
        #expect(calls.values == ["key-1", "key-1"], "Retry reuses the same key")
        #expect(pendingStore.load(caseId: "c1") == nil)
        await client.stop()
    }
}

/// The keys the fake daemon saw; its handler runs on a background thread.
private final class SentKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
