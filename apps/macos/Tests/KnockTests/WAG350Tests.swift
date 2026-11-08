import Testing
import SwiftUI
import AppKit
@testable import Knock

/// WAG-350: the artifact box never becomes wider than its column, whatever the number of tabs.
@MainActor
struct WAG350Tests {
    private func tabs(_ count: Int) -> [ArtifactTab] {
        (1...count).map {
            ArtifactTab(
                id: "name:screen-\($0)", title: "Screen set number \($0)", revision: 1, kind: .screenshot, hasName: true, revisions: [1])
        }
    }

    private func box(tabCount: Int) -> LiveArtifactBoxView {
        let model = LiveArtifactModel(
            caseId: "c1", client: KnockClient(socketPath: "/nonexistent.sock", startDaemon: {}), tabs: tabs(tabCount))
        return LiveArtifactBoxView(
            model: model, caseKind: .question, client: KnockClient(socketPath: "/nonexistent.sock", startDaemon: {}), onOpen: {})
    }

    /// The width the view takes when the column offers `column`, and its ideal width in the same host.
    private func widths<V: View>(_ view: V, column: CGFloat) -> (offered: CGFloat, minimum: CGFloat) {
        let controller = NSHostingController(rootView: view)
        let offered = controller.sizeThatFits(in: CGSize(width: column, height: 700)).width
        let minimum = controller.sizeThatFits(in: CGSize(width: 0, height: 700)).width
        return (offered, minimum)
    }

    @Test(arguments: [8, 12]) func theBoxIsAsWideAsItsColumn(tabCount: Int) {
        let result = widths(box(tabCount: tabCount), column: 390)
        #expect(result.offered <= 390.5)
    }

    @Test func theTabStripNeverAsksForMoreThanItIsOffered() {
        let strip = ArtifactTabStrip(tabs: tabs(12), selectedId: "name:screen-12") { _ in }
        #expect(widths(strip, column: 300).offered <= 300.5)
    }

    @Test func tabsThatFitStillHugTheirContent() {
        let strip = ArtifactTabStrip(tabs: tabs(2), selectedId: nil) { _ in }
        let offered = widths(strip, column: 900).offered
        #expect(offered > 100 && offered < 600)
    }
}
