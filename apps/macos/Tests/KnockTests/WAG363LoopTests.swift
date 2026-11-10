import Testing
import Foundation
import AppKit
import SwiftUI
import Combine
@testable import Knock

/// WAG-363: the two update loops of issue 6 cannot run.
@MainActor
struct WAG363LoopTests {
    // MARK: Loop 2: the ask text layout settles

    private func host(width: CGFloat) -> (NSWindow, NSHostingView<AnyView>) {
        let book = SourceBook(
            sources: [Source(id: "a", kind: "file", label: "Alpha"), Source(id: "b", kind: "file", label: "Beta")],
            citedIn: [])
        let sources = SourcesHub(book: book)
        let hub = AskCommentsHub(store: CommentsSessionStore())
        let text = "Pick how the plan should land. [[s:a]] The first round has several items, each with a source. [[s:b]] [[s:a,b]] And a long tail so the text wraps over many lines at this width."
        let view = VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                CommentableAskText(
                    text: text, style: Theme.AskDoc.Typography.why13_5, color: .primary,
                    target: AskCommentTarget(.title, itemId: "i\(i)"), hub: hub)
            }
        }
        .environment(\.sourcesHub, sources)
        .coordinateSpace(name: SourcesHub.space)
        .coordinateSpace(name: AskCommentsHub.space)
        let hosting = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        return (window, hosting)
    }

    private func textViews(in view: NSView) -> [AskCommentTextView] {
        var found: [AskCommentTextView] = []
        func walk(_ v: NSView) { if let t = v as? AskCommentTextView { found.append(t) }; v.subviews.forEach(walk) }
        walk(view)
        return found
    }

    /// Lets the main run loop turn without a nested run loop, which would hold the main actor.
    private func pump(_ turns: Int) async throws {
        for _ in 0..<turns { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test func theAskTextLayoutSettles() async throws {
        let (window, hosting) = host(width: 520)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await pump(20)
        let views = textViews(in: hosting)
        #expect(views.count == 4)
        // A resize, then a fraction of a point, then back: the layout comes to rest each time.
        for width in [380, 380.4, 520] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 600))
            try await pump(20)
        }
        // Wait until the counts hold still over 30 turns (20 s deadline): a loaded runner lays out slower.
        func total() -> [Int] { views.map { $0.layoutPasses + $0.measures } }
        let deadline = ContinuousClock.now + .seconds(20)
        var before = total()
        while ContinuousClock.now < deadline {
            try await pump(30)
            if total() == before { break }
            before = total()
        }
        try await pump(60)
        let after = views.map { $0.layoutPasses + $0.measures }
        #expect(before == after, "layout passes + measures kept growing: \(before) -> \(after)")
    }

    @Test func aMeasureIsPureAndFollowsTheProposedWidth() throws {
        let book = SourceBook(sources: [], citedIn: [])
        let face = AskTextFace(style: Theme.AskDoc.Typography.why13_5, color: .primary)
        let content = AskTextContent.build(
            text: String(repeating: "word another ", count: 60), mode: .line, face: face, book: book, showsPills: true, prefix: nil)
        let hub = AskCommentsHub(store: CommentsSessionStore())
        let view = AskCommentTextView.make()
        view.configure(
            content: content, target: AskCommentTarget(.title), comments: [], selectedId: nil, canComment: true,
            hub: hub, sourcesHub: nil)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        let frame = view.frame
        let wrap = try #require(view.textContainer?.size.width)
        let narrow = view.fittingHeight(forWidth: 120)
        let wide = view.fittingHeight(forWidth: 900)
        #expect(narrow > wide, "a narrower proposal must give a taller text: \(narrow) vs \(wide)")
        #expect(view.fittingHeight(forWidth: 120) == narrow)
        #expect(view.frame == frame)
        #expect(view.textContainer?.size.width == wrap)
    }
}

// MARK: Loop 1: the footer mirror writes nothing when nothing changed

@MainActor
struct WAG363FooterTests {
    private func sessionsJSON(lastSeen: Int) -> String {
        """
        [{"id":"s_1","task_id":"t1","runtime":"claude","task_name":"a","project":"a","branch":"main","pid":123,"can_nudge":true,
          "state":"live","connected_at":"2026-10-11T10:00:00Z","last_seen_at":"2026-10-11T10:00:\(10 + lastSeen)Z"},
         {"id":"s_2","task_id":"t2","runtime":"claude","task_name":"b","project":"b","branch":"main","pid":456,"can_nudge":false,
          "state":"live","connected_at":"2026-10-11T10:00:00Z","last_seen_at":"2026-10-11T10:00:\(10 + lastSeen)Z"},
         {"id":"s_3","task_id":"t3","runtime":"claude","task_name":"c","project":"c","branch":"main",
          "state":"ended","connected_at":"2026-10-11T10:00:00Z","last_seen_at":"2026-10-11T10:00:00Z"}]
        """
    }

    @Test func aPollThatChangesOnlyLastSeenWritesNoFooterValue() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        var lastSeen = 0
        server.onRequest = { method, id, _ in
            guard method == "sessions.list", let id else { return nil }
            return jsonRPCOK(id: id, result: self.sessionsJSON(lastSeen: lastSeen))
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wag363_\(UUID().uuidString)").path
        let model = AppModel(client: client, environment: ["KNOCK_HOME": home])

        // No queue on screen: the mirror lives in the model, so the test needs no window.
        await model.sessionsModel.refresh()

        _ = try await pollUntil(.seconds(20)) { model.liveSessionCount == 2 }
        #expect(model.liveSessionCount == 2)
        #expect(model.sessionPidByTaskId == ["t1": 123, "t2": 456])
        #expect(model.canNudgeByTaskId == ["t1": true, "t2": false])

        var writes = 0
        var bag: [Any] = []
        bag.append(model.$liveSessionCount.dropFirst().sink { _ in writes += 1 })
        bag.append(model.$sessionPidByTaskId.dropFirst().sink { _ in writes += 1 })
        bag.append(model.$canNudgeByTaskId.dropFirst().sink { _ in writes += 1 })
        for step in 1...5 {
            lastSeen = step
            await model.sessionsModel.refresh()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(model.sessionsModel.sessions.first?.lastSeenAt.hasSuffix("15Z") == true)
        #expect(writes == 0, "the footer mirror wrote \(writes) times for values that did not change")
        _ = bag
        await client.stop()
    }

    @Test func theMirrorFollowsASessionThatStartsOrEnds() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wag363_\(UUID().uuidString)").path
        let model = AppModel(client: KnockClient(socketPath: makeTempSocketPath(), backoffSchedule: [1]), environment: ["KNOCK_HOME": home])
        func session(_ id: String, _ state: SessionState, pid: Int?) -> SessionInfo {
            SessionInfo(id: id, taskId: "t\(id)", runtime: .claude, taskName: id, project: "/x/\(id)", branch: nil, pid: pid, canNudge: pid != nil, state: state, connectedAt: "", lastSeenAt: "")
        }
        model.mirrorSessions([session("1", .live, pid: 7), session("2", .live, pid: nil)])
        #expect(model.liveSessionCount == 2)
        #expect(model.sessionPidByTaskId == ["t1": 7])
        #expect(model.canNudgeByTaskId == ["t1": true, "t2": false])
        model.mirrorSessions([session("1", .ended, pid: 7), session("2", .live, pid: nil)])
        #expect(model.liveSessionCount == 1)
        #expect(model.sessionPidByTaskId.isEmpty)
        #expect(model.canNudgeByTaskId == ["t2": false])
    }
}
