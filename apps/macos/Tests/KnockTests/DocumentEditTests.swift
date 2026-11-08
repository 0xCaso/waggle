import AppKit
import Foundation
import Testing
@testable import Knock

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(method: String, line: String)] = []
    func add(_ method: String, _ line: Data) {
        lock.lock(); defer { lock.unlock() }
        lines.append((method, String(decoding: line, as: UTF8.self)))
    }
    func last(_ method: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return lines.last { $0.method == method }?.line
    }
    func count(_ method: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return lines.filter { $0.method == method }.count
    }
}

private final class Served: @unchecked Sendable {
    var artifact = ""
}

private func detail(kind: String = "review", revisions: [String]) throws -> CaseDetail {
    let json = #"""
    {"case":{"id":"c_1","task_id":"t_1","kind":"\#(kind)","title":"Cache plan",
      "need":"Pick one.","why":"Both work.","recommendation":"a","recommendation_why":"Simple","options":[{"id":"a","label":"Ship it"}],
      "status":"needs_you","has_artifact":true,"runtime":"claude","created_at":"2026-09-26T10:00:00Z",
      "updated_at":"2026-09-26T10:41:00Z"},
     "task":{"id":"t_1","name":"Cache","project":"knock"},
     "messages":[],"revisions":[\#(revisions.joined(separator: ","))],"comments":[],"replies":[]}
    """#
    return try JSONDecoder().decode(CaseDetail.self, from: Data(json.utf8))
}

private let agentRevision = #"{"id":"r_1","case_id":"c_1","n":1,"created_at":"2026-09-26T10:00:00Z","author":"agent"}"#
private let humanRevision = #"{"id":"r_2","case_id":"c_1","n":2,"created_at":"2026-09-26T10:05:00Z","author":"you","base_revision":1,"passages_changed":1}"#

private func writeFile(_ name: String, _ text: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(name).path
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func writeShot() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let path = dir.appendingPathComponent("shot.png").path
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    return path
}

/// HAIL-168: Edit docs in place, from the viewer's state to the reply the agent gets.
@Suite(.serialized)
@MainActor
struct DocumentEditTests {
    private let original = "# Cache\n\nWe cache for **ten** minutes.\n"

    private func makeModel(served: Served, seen: Seen) async throws -> (ReviewViewModel, FakeKnockServer) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            seen.add(method, line)
            switch method {
            case "artifact.path": return jsonRPCOK(id: id, result: served.artifact)
            case "revision.add_by_human":
                return jsonRPCOK(id: id, result: humanRevision)
            default: return nil
            }
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        return (ReviewViewModel(client: client), server)
    }

    @Test func editIsOnlyForAMarkdownExplanation() async throws {
        let served = Served(), seen = Seen()
        let (model, server) = try await makeModel(served: served, seen: seen)
        defer { server.stop() }

        served.artifact = #"{"kind":"screenshot","root":"\#(try writeShot())","entry":""}"#
        await model.load(detail: try detail(revisions: [agentRevision]))
        #expect(!model.canEditInPlace, "not for a screenshot")

        served.artifact = #"{"kind":"markdown","root":"\#(try writeFile("a.md", original))","entry":""}"#
        await model.load(detail: try detail(revisions: [agentRevision]))
        #expect(model.canEditInPlace)
    }

    @Test func cancelDiscardsTheEditAndSavesNothing() async throws {
        let served = Served(), seen = Seen()
        let (model, server) = try await makeModel(served: served, seen: seen)
        defer { server.stop() }
        served.artifact = #"{"kind":"markdown","root":"\#(try writeFile("a.md", original))","entry":""}"#
        await model.load(detail: try detail(revisions: [agentRevision]))

        model.beginEditing()
        let session = try #require(model.editSession)
        _ = session.replace(2..<3, with: "X")
        #expect(session.hasChanges)
        model.cancelEditing()

        #expect(model.editSession == nil)
        #expect(model.humanRevision == nil)
        #expect(seen.count("revision.add_by_human") == 0)
        if case .markdown(let text, let revision) = model.artifactState {
            #expect(text == original)
            #expect(revision == 1)
        } else {
            Issue.record("the explanation stays on screen")
        }
    }

    @Test func doneSavesTheEditAsTheNextRevisionByYou() async throws {
        let served = Served(), seen = Seen()
        let (model, server) = try await makeModel(served: served, seen: seen)
        defer { server.stop() }
        served.artifact = #"{"kind":"markdown","root":"\#(try writeFile("a.md", original))","entry":""}"#
        await model.load(detail: try detail(revisions: [agentRevision]))
        var saved: Revision?
        model.onDocumentEdited = { saved = $0 }

        model.beginEditing()
        let session = try #require(model.editSession)
        let text = String(decoding: session.model.displayText, as: UTF16.self) as NSString
        let ten = text.range(of: "ten")
        _ = session.replace(ten.location..<(ten.location + ten.length), with: "five")

        // The daemon answers artifact.path for v2 with the edited file.
        served.artifact = #"{"kind":"markdown","root":"\#(try writeFile("b.md", "# Cache\n\nWe cache for **five** minutes.\n"))","entry":""}"#
        await model.finishEditing()

        let line = try #require(seen.last("revision.add_by_human"))
        #expect(line.contains(#""base_revision":1"#))
        #expect(line.contains(#""case_id":"c_1""#))
        #expect(line.contains("We cache for **five** minutes."))
        #expect(model.editSession == nil)
        #expect(saved?.n == 2)
        #expect(saved?.author == .you)
        #expect(model.humanRevision?.passagesChanged == 1)
        if case .markdown(let shown, let revision) = model.artifactState {
            #expect(revision == 2)
            #expect(shown.contains("five"))
        } else {
            Issue.record("v2 shows")
        }
    }

    @Test func doneWithNoChangeSavesNothing() async throws {
        let served = Served(), seen = Seen()
        let (model, server) = try await makeModel(served: served, seen: seen)
        defer { server.stop() }
        served.artifact = #"{"kind":"markdown","root":"\#(try writeFile("a.md", original))","entry":""}"#
        await model.load(detail: try detail(revisions: [agentRevision]))
        model.beginEditing()
        await model.finishEditing()
        #expect(model.editSession == nil)
        #expect(seen.count("revision.add_by_human") == 0)
    }

    @Test func aRevisionByYouIsNotAnAgentArrival() throws {
        let both = try detail(revisions: [agentRevision, humanRevision])
        #expect(both.revisionArrival == nil)
        #expect(both.revisions.last?.author == .you)
        #expect(both.revisions.last?.baseRevision == 1)
    }

    @Test func aRevisionWithoutAnAuthorReadsAsTheAgents() throws {
        let old = try detail(revisions: [#"{"id":"r_1","case_id":"c_1","n":1,"created_at":"2026-09-26T10:00:00Z"}"#])
        #expect(old.revisions[0].author == .agent)
    }

    // MARK: The reply

    private func flow(client: KnockClient) -> SendFlowController {
        let coordinator = SendCoordinator(
            client: client,
            store: PendingReplyStore(environment: ["KNOCK_HOME": FileManager.default.temporaryDirectory
                .appendingPathComponent("knock_edit_\(UUID().uuidString)").path]))
        let knockCase = try! detail(revisions: [agentRevision]).case
        return SendFlowController(
            knockCase: knockCase, commentsStore: CommentsSessionStore(), coordinator: coordinator,
            draftStore: ComposerDraftStore(), onSent: {})
    }

    private func replyServer(seen: Seen) throws -> (FakeKnockServer, KnockClient) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            seen.add(method, line)
            guard method == "reply.submit" else { return nil }
            return jsonRPCOK(
                id: id,
                result: #"{"id":"rp_1","case_id":"c_1","idempotency_key":"k","comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#)
        }
        try server.start()
        return (server, KnockClient(socketPath: socketPath, backoffSchedule: [0.02]))
    }

    @Test func theReplyCarriesTheAttachedEdit() async throws {
        let seen = Seen()
        let (server, client) = try replyServer(seen: seen)
        defer { server.stop() }
        await client.start()
        try await waitForState(client, .connected)
        let sendFlow = flow(client: client)

        sendFlow.attachEdit(.init(revision: 2, baseRevision: 1, passagesChanged: 3))
        #expect(sendFlow.hasUnsentWork)
        sendFlow.acceptRecommendation()
        _ = try await pollUntil(.seconds(20)) { seen.last("reply.submit") != nil && sendFlow.attachedEdit == nil }

        let line = try #require(seen.last("reply.submit"))
        #expect(line.contains(#""edit":{"revision":2}"#))
        #expect(sendFlow.attachedEdit == nil, "the edit goes with this reply only")
        await client.stop()
    }

    @Test func removeDropsTheEditFromTheReplyButKeepsTheRevision() async throws {
        let seen = Seen()
        let (server, client) = try replyServer(seen: seen)
        defer { server.stop() }
        await client.start()
        try await waitForState(client, .connected)
        let sendFlow = flow(client: client)

        sendFlow.attachEdit(.init(revision: 2, baseRevision: 1, passagesChanged: 3))
        sendFlow.removeEdit()
        sendFlow.acceptRecommendation()
        _ = try await pollUntil(.seconds(20)) { seen.last("reply.submit") != nil }

        let line = try #require(seen.last("reply.submit"))
        #expect(!line.contains("edit"))
        await client.stop()
    }

    // MARK: Labels

    @Test func theSendLabelGainsPlusEdit() {
        #expect(PromptBarLogic.sendPillLabel(commentCount: 0, hasEdit: true) == "Send + edit")
        #expect(PromptBarLogic.sendPillLabel(commentCount: 2, hasEdit: true) == "Send + 2 comments + edit")
        #expect(PromptBarLogic.sendPillLabel(commentCount: 0, planLabel: "Ship it", hasEdit: true) == "Ship it + edit")
        #expect(PromptBarLogic.sendPillLabel(commentCount: 0) == nil, "nothing changes without an edit")
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, planLabel: "Ship it", hasEdit: true).first == "Ship it + edit")
        #expect(PromptBarLogic.canSend(hasChoice: false, hasMessage: false, commentCount: 0, hasEdit: true))
    }

    @Test func theEditChipSaysVersionAndPassages() {
        #expect(PromptBarView.editChipLabel(revision: 2, passages: 3) == "Your edit · v2 · 3 passages changed")
        #expect(PromptBarView.editChipLabel(revision: 2, passages: 1) == "Your edit · v2 · 1 passage changed")
    }
}
