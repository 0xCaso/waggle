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
}
