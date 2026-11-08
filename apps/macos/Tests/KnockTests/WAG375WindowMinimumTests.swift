import AppKit
import SwiftUI
import XCTest
@testable import Knock

/// WAG-375: the window's minimum-size probe never measures the page.
@MainActor
final class WAG375WindowMinimumTests: XCTestCase {
    private final class Counter { var probes: [CGFloat?] = [] }

    private struct Probe: Layout {
        let counter: Counter
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            counter.probes.append(proposal.width)
            return CGSize(width: proposal.width ?? 10, height: proposal.height ?? 10)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
    }

    func testTheMinimumComesFromTheNumbersNotThePage() {
        let counter = Counter()
        let host = NSHostingView(rootView: Probe(counter: counter) { Color.clear }.fixedWindowMinimum(width: 900, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        XCTAssertEqual(fitting.width, 900, accuracy: 0.5)
        XCTAssertEqual(fitting.height, 600, accuracy: 0.5)
        XCTAssertFalse(counter.probes.contains { ($0 ?? 0) < 900 }, "the page was asked at \(counter.probes)")
    }

    func testThePageGetsTheWindowSize() {
        let counter = Counter()
        let host = NSHostingView(rootView: Probe(counter: counter) { Color.clear }.fixedWindowMinimum(width: 900, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(counter.probes.contains(1200))
    }

    /// WAG-378 (issue 9, 0.2.45): the app wraps the root in `.background` modifiers, and a stack or a background
    /// aligns itself to the root's alignment guides. The minimum probe must still never reach the page.
    func testABackgroundAroundTheRootDoesNotLeakTheProbe() {
        let counter = Counter()
        let root = Probe(counter: counter) { Color.clear }
            .fixedWindowMinimum(width: 900, height: 600)
            .background(Color.clear)
            .background(Color.clear)
            .preferredColorScheme(.light)
        // The window scene puts its content in a flexible frame and a stack (seen in the 0.2.46 sample).
        let host = NSHostingView(rootView: VStack(spacing: 0) { root; Color.clear.frame(height: 0) }.frame(maxWidth: .infinity, maxHeight: .infinity))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        host.invalidateIntrinsicContentSize()
        host.needsUpdateConstraints = true
        host.updateConstraintsForSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        // A leaked probe places the page at the minimum (900), so any width but the window's is a leak.
        XCTAssertTrue(counter.probes.allSatisfy { $0 == 1200 }, "the page was asked at \(counter.probes)")
        XCTAssertTrue(counter.probes.contains(1200))
    }
}
