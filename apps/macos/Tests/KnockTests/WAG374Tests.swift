import AppKit
import SwiftUI
import XCTest
@testable import Knock

/// WAG-374: the floating Interact / Comment toolbar never covers the bottom of a screenshot.
@MainActor
final class WAG374Tests: XCTestCase {
    private func measuredHeight(_ tools: [ReviewMode], showsKeys: Bool) -> CGFloat {
        let host = NSHostingView(rootView: CanvasToolbarView(tools: tools, mode: .comment, showsKeys: showsKeys) { _ in })
        return host.fittingSize.height
    }

    func testTheBandIsAtLeastAsTallAsTheToolbar() {
        for tools in [[ReviewMode.comment], [.interact, .comment]] {
            for keys in [true, false] {
                XCTAssertLessThanOrEqual(measuredHeight(tools, showsKeys: keys), CanvasToolbarView.height + 0.5)
            }
        }
    }

    func testTheImageEndsAboveTheToolbarWithAGap() {
        for gap in [ArtifactViewerView.toolbarBottomGap, LiveArtifactBoxView.toolbarBottomGap] {
            let inset = CanvasToolbarView.imageBottomInset(bottomGap: gap)
            XCTAssertGreaterThanOrEqual(inset - (gap + CanvasToolbarView.height), 8)
        }
    }
}
