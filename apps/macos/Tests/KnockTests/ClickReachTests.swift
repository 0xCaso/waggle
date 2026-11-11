import Testing
import AppKit
import SwiftUI
import WebKit
@testable import Knock

/// HAIL-133: a click must reach its target. The prototype's pan monitor read `event.keyCode` on
/// every event it watches, and `keyCode` raises on a mouse event, so AppKit dropped every click
/// in the window while a prototype was open.
@Suite(.serialized)
@MainActor
struct ClickReachTests {
    final class Counter { var n = 0 }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.sendEvent(event)
    }

    private func click(at point: NSPoint, in window: NSWindow) {
        send(.leftMouseDown, at: point, in: window)
        send(.leftMouseUp, at: point, in: window)
    }

    private func space(down: Bool, in window: NSWindow) {
        let event = NSEvent.keyEvent(
            with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        NSApp.sendEvent(event)
    }

    @Test func buttonsBesideAZoomablePrototypeStillGetClicks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("click_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entry = dir.appendingPathComponent("index.html")
        try "<html><body style='width:2000px;height:3000px'>hi</body></html>".write(to: entry, atomically: true, encoding: .utf8)
        let config = HTMLIsolation.makeConfiguration(contentRuleList: try await HTMLIsolation.compiledContentRuleList())
        let zoom = PrototypeZoomModel()
        let left = Counter(), right = Counter()
        let view = HStack(spacing: 0) {
            Button("L") { left.n += 1 }.frame(width: 100).frame(maxHeight: .infinity)
            SandboxedHTMLView(
                entryURL: entry, directoryURL: dir, configuration: config, captureController: nil,
                zoom: zoom, magnification: zoom.storedScale
            ).padding(28)
            Button("R") { right.n += 1 }.frame(width: 100).frame(maxHeight: .infinity)
        }
        .frame(width: 800, height: 600)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Space pressed and released over the page, then clicks outside the web view.
        space(down: true, in: window)
        space(down: false, in: window)
        click(at: NSPoint(x: 50, y: 300), in: window)
        click(at: NSPoint(x: 750, y: 300), in: window)
        #expect(left.n == 1)
        #expect(right.n == 1)
        window.orderOut(nil)
    }

    @Test func dockRowsGetClicks() throws {
        let c = Case(
            id: "c1", taskId: "t1", kind: .review, title: "How should we ship the release?",
            need: String(repeating: "Pick one of the options below. ", count: 8),
            why: String(repeating: "Not a technical call. ", count: 8),
            recommendation: "o0", recommendationWhy: "It is faster",
            options: (0..<3).map { Option(id: "o\($0)", label: "You release it, option \($0), and tell the team.") },
            status: .needsYou, hasArtifact: true,
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z")
        let client = KnockClient(socketPath: "/tmp/knock-nonexistent-\(UUID().uuidString).sock")
        let coordinator = SendCoordinator(
            client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": NSTemporaryDirectory() + UUID().uuidString]))
        let flow = SendFlowController(
            knockCase: c, commentsStore: CommentsSessionStore(), coordinator: coordinator,
            draftStore: ComposerDraftStore(), onSent: {})
        let root = AskColumnView(knockCase: c, composer: flow.composer, sendFlow: flow, commentCount: 0, tab: .question)
        let host = NSHostingView(rootView: root.frame(width: 430, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()

        // Walk up from the window's bottom edge (window y grows up). The dock owns every point from
        // there to its top edge: none of them reaches a view inside the question's scroll view. Past
        // the dock's top the scroll view takes over, so the question never runs under the dock.
        let frame = try #require(host.superview)
        func inScrollView(atWindowY y: CGFloat) -> Bool {
            var view = frame.hitTest(frame.convert(NSPoint(x: 120, y: y), from: nil))
            while let current = view {
                // SwiftUI's own scroll view; the note field's text view sits in a plain NSScrollView inside the dock.
                // The dock's own option list scrolls inside its cap (WAG-303), so it is a short scroll view;
                // the question's one fills the rest of the column.
                if String(describing: type(of: current)).contains("HostingScrollView"), current.frame.height > 250 { return true }
                view = current.superview
            }
            return false
        }
        var dockTop: CGFloat = 0
        for y in stride(from: 4.0, to: 600.0, by: 2.0) {
            if inScrollView(atWindowY: y) { break }
            dockTop = y
        }
        // Full size has the pane's column (C9): the options scroll with the question, the dock holds only the
        // answer box and the send row.
        #expect(dockTop > 30, "the dock holds the answer box and the send row")
        #expect(dockTop < 150, "the option rows scroll with the question, not in the dock")
        for y in stride(from: 4.0, through: dockTop, by: 2.0) {
            #expect(!inScrollView(atWindowY: y), "a click at y=\(y) in the dock must not reach the scroll view")
        }
        // The tabs sit pinned above the scroll (C8), about 54 pt at the top of the 700 pt column.
        for y in stride(from: dockTop + 4, to: 640.0, by: 2.0) where !inScrollView(atWindowY: y) && y < 640 {
            Issue.record("the dock reaches y=\(y), above where the scroll view ends")
            break
        }
        window.orderOut(nil)
    }
}
