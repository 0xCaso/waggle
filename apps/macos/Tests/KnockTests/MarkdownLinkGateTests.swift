import Testing
import Foundation
@testable import Knock

/// `MarkdownLinkGate` (HAIL-33: "Links open in the default browser, only
/// after a confirmation"): a tapped link must never open until `confirm()`
/// is called explicitly.
@MainActor
struct MarkdownLinkGateTests {
    @Test func requestOpenRecordsThePendingURLWithoutOpeningIt() {
        let gate = MarkdownLinkGate()
        var opened: [URL] = []

        gate.requestOpen(URL(string: "https://example.com")!)

        #expect(gate.pendingURL == URL(string: "https://example.com"))
        #expect(opened.isEmpty, "a tapped link must not open before it is confirmed")
    }

    @Test func confirmOpensThePendingURLAndClearsIt() {
        let gate = MarkdownLinkGate()
        var opened: [URL] = []
        gate.requestOpen(URL(string: "https://example.com")!)

        gate.confirm { opened.append($0) }

        #expect(opened == [URL(string: "https://example.com")!])
        #expect(gate.pendingURL == nil)
    }

    @Test func cancelClearsThePendingURLWithoutOpening() {
        let gate = MarkdownLinkGate()
        var opened: [URL] = []
        gate.requestOpen(URL(string: "https://example.com")!)

        gate.cancel()

        #expect(gate.pendingURL == nil)
        #expect(opened.isEmpty)
    }

    @Test func confirmWithNothingPendingIsANoOp() {
        let gate = MarkdownLinkGate()
        var opened: [URL] = []

        gate.confirm { opened.append($0) }

        #expect(opened.isEmpty)
    }

    @Test func aSecondLinkReplacesThePendingOneRatherThanQueuing() {
        let gate = MarkdownLinkGate()
        gate.requestOpen(URL(string: "https://one.example")!)
        gate.requestOpen(URL(string: "https://two.example")!)
        #expect(gate.pendingURL == URL(string: "https://two.example"))
    }
}
