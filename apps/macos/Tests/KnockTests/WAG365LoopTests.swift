import Testing
import Foundation
import AppKit
import SwiftUI
import Combine
@testable import Knock

/// WAG-365: the layout of a request page comes to rest, a geometry write does not invalidate it, and the pulse
/// runs without layout.
@MainActor
struct WAG365LoopTests {
    private struct Page {
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        let hub: AskCommentsHub
        let sources: SourcesHub
    }

    private func page(width: CGFloat = 520, pulse: Bool = false) -> Page {
        let book = SourceBook(
            sources: [Source(id: "a", kind: "file", label: "Alpha"), Source(id: "b", kind: "file", label: "Beta")],
            citedIn: [])
        let sources = SourcesHub(book: book)
        let hub = AskCommentsHub(store: CommentsSessionStore())
        let text = "Pick how the plan should land. [[s:a]] The first round has several items, each with a source. [[s:b]] [[s:a,b]] And a long tail so the text wraps over many lines at this width."
        let content = ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if pulse { RowDot(color: .orange, pulses: true) }
                ForEach(0..<5, id: \.self) { i in
                    CommentableAskText(
                        text: text, style: Theme.AskDoc.Typography.why13_5, color: .primary,
                        target: AskCommentTarget(.title, itemId: "i\(i)"), hub: hub)
                }
            }
            .padding(16)
        }
        let view = AskCommentsHost(hub: hub) { SourcesHost(hub: sources) { content } }
        let hosting = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 500)
        return Page(window: window, hosting: hosting, hub: hub, sources: sources)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        func walk(_ v: NSView) { if let t = v as? T { found.append(t) }; v.subviews.forEach(walk) }
        walk(view)
        return found
    }

    private func pump(_ turns: Int) async throws {
        for _ in 0..<turns { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func counts(_ page: Page) -> [Int] {
        find(AskCommentTextView.self, in: page.hosting).map { $0.layoutPasses + $0.measures }
            + [page.hub.ui.geometryWrites, page.sources.reportWrites]
    }

    @Test func aRequestPageComesToRestAndSurvivesAFractionalMove() async throws {
        let p = page()
        p.window.orderBack(nil)
        defer { p.window.orderOut(nil) }
        try await pump(30)
        let views = find(AskCommentTextView.self, in: p.hosting)
        #expect(views.count == 5)
        #expect(!p.hub.ui.origins.isEmpty)

        let first = counts(p)
        try await pump(60)
        #expect(counts(p) == first, "the page kept laying out: \(first) -> \(counts(p))")

        // 0.3 point on an origin is the same place: nothing is written and nothing lays out.
        let key = try #require(p.hub.ui.origins.keys.first)
        let origin = try #require(p.hub.ui.origins[key])
        p.hub.viewMoved(key: key, origin: CGPoint(x: origin.x + 0.3, y: origin.y - 0.3))
        try await pump(30)
        #expect(counts(p) == first)
        #expect(p.hub.ui.origins[key] == origin)

        // A real move of 3 points is written once and the page comes to rest again.
        p.hub.viewMoved(key: key, origin: CGPoint(x: origin.x + 3, y: origin.y))
        try await pump(30)
        let moved = counts(p)
        try await pump(60)
        #expect(counts(p) == moved)
        #expect(p.hub.ui.origins[key]?.x == origin.x + 3)
    }

    @Test func aGeometryWriteWithNothingOnScreenInvalidatesNothing() throws {
        let hub = AskCommentsHub(store: CommentsSessionStore())
        var sends = 0
        let bag = hub.ui.objectWillChange.sink { sends += 1 }
        hub.viewMoved(key: "k", origin: CGPoint(x: 1, y: 2))
        hub.viewMoved(key: "k", origin: CGPoint(x: 9, y: 9))
        hub.ui.setHostSize(CGSize(width: 400, height: 300))
        hub.viewGone(key: "k")
        #expect(sends == 0, "a geometry write published \(sends) times with no overlay on screen")
        _ = bag
    }

    @Test func anOverlayOfAKeyFollowsItsTextButASmallMoveIsSilent() throws {
        let hub = AskCommentsHub(store: CommentsSessionStore())
        hub.viewMoved(key: "k", origin: CGPoint(x: 1, y: 2))
        hub.ui.selection = AskCommentsUI.Selection(
            key: "k", target: AskCommentTarget(.title), anchor: AskTextAnchor(part: .title, quote: "x", start: 0, end: 1), rect: CGRect(x: 0, y: 0, width: 5, height: 5))
        var sends = 0
        let bag = hub.ui.objectWillChange.sink { sends += 1 }
        hub.viewMoved(key: "k", origin: CGPoint(x: 1.3, y: 2.2))
        #expect(sends == 0)
        hub.viewMoved(key: "k", origin: CGPoint(x: 11, y: 2))
        #expect(sends == 1)
        _ = bag
    }

    @Test func aSourcesReportOfTheSamePlaceWritesNothing() throws {
        let sources = SourcesHub(book: .empty)
        sources.report(key: "p", rect: CGRect(x: 10, y: 10, width: 50, height: 16))
        let writes = sources.reportWrites
        sources.report(key: "p", rect: CGRect(x: 10.3, y: 9.8, width: 50.2, height: 16))
        #expect(sources.reportWrites == writes)
        sources.report(key: "p", rect: CGRect(x: 14, y: 10, width: 50, height: 16))
        #expect(sources.reportWrites == writes + 1)
    }

    /// Pumps until a pulse ring is in the hosting view, up to a deadline: a slow runner lays out later.
    private func pumpUntilRing(_ p: Page) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while find(PulseRingView.self, in: p.hosting).isEmpty && ContinuousClock.now < deadline {
            try await pump(5)
        }
    }

    // MARK: Fault B

    // These two need a window the system really draws. A GitHub macOS runner never hosts the ring view
    // (it stays absent after 20 s), so they run locally only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "needs a drawn window; not on CI runners"))
    func theWorkingPulseRunsOnItsOwnLayerAndCausesNoLayout() async throws {
        let p = page(pulse: true)
        p.window.orderBack(nil)
        defer { p.window.orderOut(nil) }
        try await pumpUntilRing(p)
        try await pump(30)
        let rings = find(PulseRingView.self, in: p.hosting)
        #expect(rings.count == 1)
        #expect(rings.first?.isPulsing == true)
        let before = counts(p)
        try await pump(100)
        #expect(counts(p) == before, "the pulse caused layout: \(before) -> \(counts(p))")
        #expect(rings.first?.animationStarts == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "needs a drawn window; not on CI runners"))
    func thePulseStopsWhenItLeavesTheWindow() async throws {
        let p = page(pulse: true)
        p.window.orderBack(nil)
        try await pumpUntilRing(p)
        try await pump(20)
        let ring = try #require(find(PulseRingView.self, in: p.hosting).first)
        #expect(ring.isPulsing)
        p.window.contentView = NSView()
        #expect(!ring.isPulsing)
        p.window.orderOut(nil)
    }
}
