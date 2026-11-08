import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Knock

/// WAG-367: the pills of the "Ask for" row.
@MainActor
struct WAG367Tests {
    @Test func eachPillPointsAtARealQuickAskOrFormat() {
        #expect(DetailPill.all.map(\.label) == ["how it works", "the trade-offs", "a prototype", "screenshots", "the numbers", "an example", "a diagram"])
        for pill in DetailPill.all {
            if case .quick(let index) = pill.pick {
                #expect(ComposerViewModel.detailChips.indices.contains(index))
                #expect(ComposerViewModel.detailChipUsageNames.indices.contains(index))
            }
        }
        #expect(DetailPill.all.last?.pick == .format(.diagram))
    }

    @Test func aPillPickIsMarkedInTheUsageLogAndAPanelPickIsNot() {
        let recorder = UsageRecorder()
        let before = UsageReporter.current
        UsageReporter.current = recorder.reporter
        defer { UsageReporter.current = before }
        DetailPill.report(format: "none", pick: "numbers", fromRow: true)
        DetailPill.report(format: "diagram", pick: nil)
        #expect(recorder.records.map(\.event) == [.detailFormatPicked, .detailFormatPicked])
        #expect(recorder.records.map(\.n) == [1, nil])
        #expect(recorder.records.map(\.variant) == ["numbers", nil])
    }

    @Test func theThreeDotsAreMarkedWhenTheyOpenThePanel() {
        let recorder = UsageRecorder()
        let sample = Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "Title", need: "Need", why: "Why", recommendation: "a",
            recommendationWhy: "Because", options: [], status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-13T10:00:00.000Z", updatedAt: "2026-10-13T10:00:00.000Z")
        let composer = ComposerViewModel(knockCase: sample, usage: recorder.reporter)
        composer.beginAskingForDetail(fromDots: true)
        composer.beginAskingForDetail()
        #expect(recorder.records.map(\.event) == [.askMoreDetailOpened, .askMoreDetailOpened])
        #expect(recorder.records.map(\.source) == ["button", nil])
    }

    /// Evidence only: `WAG367_EVIDENCE_DIR=<dir>` writes the row at four widths as PNG files.
    @Test func theRowRendersAtWideAndNarrowWidths() throws {
        guard let dir = ProcessInfo.processInfo.environment["WAG367_EVIDENCE_DIR"] else { return }
        let sample = Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "Title", need: "Need", why: "Why", recommendation: "a",
            recommendationWhy: "Because", options: [], status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-13T10:00:00.000Z", updatedAt: "2026-10-13T10:00:00.000Z")
        for width in [860.0, 680.0, 420.0, 300.0] {
            let row = AskForDetailRowView(composer: ComposerViewModel(knockCase: sample), onSend: {}, onSendFormat: { _ in })
                .frame(width: width)
                .background(Color.white)
            let renderer = ImageRenderer(content: row)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("row-\(Int(width)).png"))
        }
    }
}
