import CoreGraphics
import Foundation
import Testing
@testable import Knock

/// Task 13a: the sidebar border and the decision column border move by drag, stay after a restart, and a double
/// click sets the default width again. The decision column stays between 360 and 640 pt; the sidebar between 240
/// and 420 pt; the artifact keeps its 480 pt beside the column, and folds as before when the pane is too narrow.
@MainActor
struct PaneBordersTests {
    private func freshDefaults() -> UserDefaults {
        let name = "PaneBordersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: the pure rules

    @Test func theDefaultsAreTheWidthsFromBeforeTheDrag() {
        #expect(PaneBorder.sidebar.defaultWidth == 300)
        #expect(PaneBorder.sidebar.defaultWidth == Theme.Spacing.listColumnWidth)
        #expect(PaneBorder.decisionColumn.defaultWidth == 440)
        #expect(PaneBorder.decisionColumn.defaultWidth == AskLayout.columnWidth)
    }

    @Test func eachBorderKeepsItsOwnRange() {
        #expect(PaneBorder.decisionColumn.range == 360...640)
        #expect(PaneBorder.sidebar.range == 240...420)
        #expect(PaneBorder.decisionColumn.clamp(100) == 360)
        #expect(PaneBorder.decisionColumn.clamp(900) == 640)
        #expect(PaneBorder.decisionColumn.clamp(500.4) == 500)
        #expect(PaneBorder.sidebar.clamp(0) == 240)
        #expect(PaneBorder.sidebar.clamp(1000) == 420)
        #expect(PaneBorder.sidebar.clamp(.nan) == 300)
        #expect(PaneBorder.decisionColumn.clamp(.infinity) == 440)
    }

    @Test func theKeysAreNamespacedAndDistinct() {
        #expect(PaneBorder.sidebar.defaultsKey == "knock.split.sidebarWidth")
        #expect(PaneBorder.decisionColumn.defaultsKey == "knock.split.decisionColumnWidth")
        let all = Set(PaneBorder.allCases.map(\.defaultsKey) + [
            SplitFoldState.queueKey, SplitFoldState.askKey, SplitFoldState.bothFoldedKey,
            SplitFoldState.priorQueueKey, SplitFoldState.priorAskKey, SplitFoldState.legacyFullPreviewKey,
        ])
        #expect(all.count == 8)
    }

    @Test func aDragRightWidensTheSidebarAndNarrowsTheColumn() {
        #expect(PaneBorder.sidebar.dragged(from: 300, translation: 40) == 340)
        #expect(PaneBorder.sidebar.dragged(from: 300, translation: -100) == 240)
        #expect(PaneBorder.decisionColumn.dragged(from: 440, translation: 40) == 400)
        #expect(PaneBorder.decisionColumn.dragged(from: 440, translation: -150) == 590)
        #expect(PaneBorder.decisionColumn.dragged(from: 440, translation: -400) == 640)
        #expect(PaneBorder.decisionColumn.dragged(from: 440, translation: 400) == 360)
    }

    @Test func aDragNeverTakesTheArtifactUnderItsMinimum() {
        // A 1000 pt pane leaves the column at most 520 pt.
        let limit = AskLayout.dragLimit(width: 1000)
        #expect(limit == 520)
        #expect(PaneBorder.decisionColumn.dragged(from: 440, translation: -300, limit: limit) == 520)
        // The limit never takes the column under its own minimum.
        #expect(PaneBorder.decisionColumn.dragged(from: 440, translation: 0, limit: 200) == 360)
    }

    // MARK: the layout with a dragged column

    @Test func theDefaultColumnKeepsTheOldFoldRule() {
        #expect(AskLayout.layout(width: 920, hasArtifact: true, preferred: 440) == .beside)
        #expect(AskLayout.layout(width: 919, hasArtifact: true, preferred: 440) == .folded)
        #expect(AskColumnsLayout.widths(1000, preferred: 440) == [560, 440])
    }

    @Test func aWideColumnGivesWayBeforeTheArtifactFolds() {
        // 640 + 480 = 1120: room for both at full width.
        #expect(AskColumnsLayout.widths(1400, preferred: 640) == [760, 640])
        #expect(AskColumnsLayout.widths(1120, preferred: 640) == [480, 640])
        // Narrower: the column gives way, down to 440, and the artifact keeps 480.
        #expect(AskColumnsLayout.widths(1000, preferred: 640) == [480, 520])
        #expect(AskColumnsLayout.widths(920, preferred: 640) == [480, 440])
        #expect(AskLayout.layout(width: 920, hasArtifact: true, preferred: 640) == .beside)
        #expect(AskLayout.layout(width: 919, hasArtifact: true, preferred: 640) == .folded)
    }

    @Test func aNarrowColumnFoldsTheArtifactLater() {
        #expect(AskLayout.layout(width: 840, hasArtifact: true, preferred: 360) == .beside)
        #expect(AskLayout.layout(width: 839, hasArtifact: true, preferred: 360) == .folded)
        #expect(AskColumnsLayout.widths(1400, preferred: 360) == [1040, 360])
        #expect(AskColumnsLayout.widths(840, preferred: 360) == [480, 360])
    }

    @Test func theArtifactNeverGetsUnderItsMinimumAtAnyDraggedWidth() {
        for preferred: CGFloat in [360, 440, 500, 640] {
            for total: CGFloat in stride(from: 800, through: 2000, by: 37.5) {
                guard AskLayout.layout(width: total, hasArtifact: true, preferred: preferred) == .beside else { continue }
                let widths = AskColumnsLayout.widths(total, preferred: preferred)
                #expect(widths[0] >= AskLayout.minArtifactWidth)
                #expect(widths[1] >= PaneBorder.decisionColumn.range.lowerBound)
                #expect(widths[1] <= preferred)
                #expect(widths[0] + widths[1] <= total)
            }
        }
    }

    @Test func withNoArtifactTheDraggedWidthDoesNotChangeThePage() {
        #expect(AskLayout.layout(width: 1600, hasArtifact: false, preferred: 640) == .page)
        #expect(AskLayout.columnWidth(.page, width: 1600, preferred: 360) == 640)
        #expect(AskLayout.columnWidth(.folded, width: 900, preferred: 640) == 640)
    }

    // MARK: the saved widths

    @Test func nothingSavedGivesTheDefaults() {
        let store = PaneWidthStore(defaults: freshDefaults())
        #expect(store.sidebarWidth == 300)
        #expect(store.decisionColumnWidth == 440)
    }

    @Test func theWidthsStayAfterARestart() {
        let defaults = freshDefaults()
        let store = PaneWidthStore(defaults: defaults)
        store.set(.sidebar, 360)
        store.set(.decisionColumn, 520)
        let restarted = PaneWidthStore(defaults: defaults)
        #expect(restarted.sidebarWidth == 360)
        #expect(restarted.decisionColumnWidth == 520)
    }

    @Test func aSavedWidthOutsideTheRangeIsClampedOnLoad() {
        let defaults = freshDefaults()
        defaults.set(2000.0, forKey: PaneBorder.decisionColumn.defaultsKey)
        defaults.set(10.0, forKey: PaneBorder.sidebar.defaultsKey)
        let store = PaneWidthStore(defaults: defaults)
        #expect(store.decisionColumnWidth == 640)
        #expect(store.sidebarWidth == 240)
        defaults.set("wide", forKey: PaneBorder.sidebar.defaultsKey)
        #expect(PaneWidthStore(defaults: defaults).sidebarWidth == 300)
    }

    @Test func setClampsTheWidth() {
        let store = PaneWidthStore(defaults: freshDefaults())
        store.set(.decisionColumn, 9000)
        #expect(store.decisionColumnWidth == 640)
        store.set(.sidebar, -5)
        #expect(store.sidebarWidth == 240)
    }

    @Test func aDoubleClickSetsTheDefaultAgainAndForgetsTheSavedWidth() {
        let defaults = freshDefaults()
        let store = PaneWidthStore(defaults: defaults)
        store.set(.sidebar, 400)
        store.set(.decisionColumn, 600)
        store.reset(.decisionColumn)
        #expect(store.decisionColumnWidth == 440)
        #expect(store.sidebarWidth == 400)
        #expect(defaults.object(forKey: PaneBorder.decisionColumn.defaultsKey) == nil)
        store.reset(.sidebar)
        #expect(store.sidebarWidth == 300)
        let restarted = PaneWidthStore(defaults: defaults)
        #expect(restarted.sidebarWidth == 300)
        #expect(restarted.decisionColumnWidth == 440)
    }
}
