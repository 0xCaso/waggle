import AppKit
import Foundation
import Testing
@testable import Knock

/// WAG-413: Compare two revisions of a screenshot.
@MainActor
struct WAG413CompareTests {
    // MARK: - The pair

    @Test func theDefaultPairIsTheShownRevisionAndTheOneBeforeIt() {
        #expect(ComparePair.previous(of: 3, in: [1, 2, 3]) == 2)
        #expect(ComparePair.previous(of: 5, in: [1, 3, 5]) == 3)
        #expect(ComparePair.previous(of: 1, in: [1, 2, 3]) == nil)
        #expect(ComparePair.previous(of: 2, in: [2]) == nil)
        #expect(ComparePair.previous(of: 4, in: []) == nil)
    }

    @Test func aScreenOfASetPairsByCaptionThenByPosition() {
        // A unique caption wins, even when the screen moved.
        #expect(ComparePair.screenIndex(shownIndex: 0, shownCaption: "Pricing", beforeCaptions: ["Home", "Pricing"]) == 1)
        // No caption: the same position.
        #expect(ComparePair.screenIndex(shownIndex: 1, shownCaption: nil, beforeCaptions: ["A", "B", "C"]) == 1)
        // A caption twice is no match: the position decides.
        #expect(ComparePair.screenIndex(shownIndex: 0, shownCaption: "X", beforeCaptions: ["X", "X"]) == 0)
        // No such screen before.
        #expect(ComparePair.screenIndex(shownIndex: 3, shownCaption: nil, beforeCaptions: ["A", "B"]) == nil)
    }

    // MARK: - One zoom

    @Test func bothSidesShareOneZoom() {
        let container = CGSize(width: 400, height: 300)
        let before = CGSize(width: 800, height: 600)
        let after = CGSize(width: 1600, height: 1200)
        let zoomed = CompareSync.scales(zoom: .scale(2), container: container, before: before, after: after)
        #expect(zoomed.before == zoomed.after)
        #expect(zoomed.before == 2)
        // Fit shows each image whole.
        let fit = CompareSync.scales(zoom: .fit, container: container, before: before, after: after)
        #expect(fit.before == 0.5)
        #expect(fit.after == 0.25)
    }

    @Test func theZoomIsTheSameWhenTheSwitchGoesOffAndOn() {
        let stage = ScreenshotStageModel()
        let compare = CompareModel()
        stage.zoom = .scale(2)
        compare.userSet(true)
        compare.userSet(false)
        compare.userSet(true)
        #expect(stage.zoom == .scale(2))
        // The pinch and the keys move the one zoom that both sides read.
        stage.updateViewport(container: CGSize(width: 400, height: 300), image: CGSize(width: 800, height: 600))
        stage.zoomIn()
        #expect(stage.zoom == .scale(2.5))
    }

    @Test func aPanOnOneSideMovesTheOtherToTheSameFraction() {
        let origin = CompareSync.mirroredOrigin(
            origin: CGPoint(x: 100, y: 50), content: CGSize(width: 500, height: 300), visible: CGSize(width: 300, height: 200),
            otherContent: CGSize(width: 1100, height: 700), otherVisible: CGSize(width: 300, height: 200)
        )
        #expect(origin == CGPoint(x: 400, y: 250))
        // Nothing to scroll on the source: the other side stays at the start.
        let still = CompareSync.mirroredOrigin(
            origin: .zero, content: CGSize(width: 300, height: 200), visible: CGSize(width: 300, height: 200),
            otherContent: CGSize(width: 900, height: 700), otherVisible: CGSize(width: 300, height: 200)
        )
        #expect(still == .zero)
    }

    @Test func theSidesStackWhenTheStageIsNarrow() {
        #expect(CompareSync.stacks(stageWidth: 620))
        #expect(!CompareSync.stacks(stageWidth: 970))
    }

    // MARK: - The slider

    @Test func theSliderLineFollowsTheDragAndStaysInsideTheStage() {
        #expect(CompareSlider.start == 0.5)
        #expect(CompareSlider.position(x: 250, width: 1000) == 0.25)
        #expect(CompareSlider.position(x: -40, width: 1000) == 0)
        #expect(CompareSlider.position(x: 1400, width: 1000) == 1)
        #expect(CompareSlider.position(x: 10, width: 0) == 0.5)
        #expect(CompareSlider.beforeWidth(position: 0.25, width: 800) == 200)
    }

    @Test func theSliderControlStartsInTheMiddleAndResetsWhenChosenAgain() {
        let compare = CompareModel()
        #expect(!compare.isOn)
        #expect(compare.layout == .sideBySide)
        #expect(!compare.showsChanges)
        compare.sliderPosition = 0.8
        compare.setLayout(.slider)
        #expect(compare.sliderPosition == 0.5)
    }

    // MARK: - Show what changed

    private func image(_ paint: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        paint(context)
        return context.makeImage()!
    }

    @Test func twoSameImagesHaveNoChangedArea() {
        let a = image { _ in }
        let b = image { _ in }
        #expect(CompareDiff.boxes(before: a, after: b).isEmpty)
    }

    @Test func aChangedBlockGetsOneBoxOverIt() throws {
        let before = image { _ in }
        // A dark block in the top-left quarter (CoreGraphics y runs up).
        let after = image {
            $0.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            $0.fill(CGRect(x: 20, y: 120, width: 60, height: 60))
        }
        let boxes = CompareDiff.boxes(before: before, after: after)
        #expect(boxes.count == 1)
        let box = try #require(boxes.first)
        // 20...80 of 200 across, 20...80 down: the box covers it and stays near it.
        #expect(box.x <= 0.1 && box.x + box.w >= 0.4)
        #expect(box.y <= 0.1 && box.y + box.h >= 0.4)
        #expect(box.w < 0.6 && box.h < 0.6)
    }

    @Test func twoFarBlocksGiveTwoBoxes() {
        let before = image { _ in }
        let after = image {
            $0.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            $0.fill(CGRect(x: 10, y: 150, width: 30, height: 30))
            $0.fill(CGRect(x: 150, y: 10, width: 30, height: 30))
        }
        #expect(CompareDiff.boxes(before: before, after: after).count == 2)
    }

    // MARK: - Stills and comments on both sides

    private func tinyImage() -> NSImage { NSImage(size: NSSize(width: 10, height: 10)) }

    @Test func compareAddsTheEarlierStillWithoutMovingTheShownScreen() {
        let store = CommentsSessionStore()
        let shown = store.addCapture(image: tinyImage(), revision: 2, isBase: true)
        #expect(store.compareStill(revision: 1, screenIndex: 0) == nil)
        let before = store.addCompareStill(image: tinyImage(), revision: 1, screenIndex: 0, caption: nil)
        #expect(store.currentCapture?.id == shown.id)
        #expect(store.compareStill(revision: 1, screenIndex: 0)?.id == before.id)
        #expect(store.compareStill(revision: 2, screenIndex: 0)?.id == shown.id)
    }

    @Test func aCommentOnEitherSideKeepsItsRevisionAndKind() {
        let recorder = UsageRecorder()
        let store = CommentsSessionStore()
        store.usage = recorder.reporter
        let after = store.addCapture(image: tinyImage(), revision: 2, isBase: true)
        let before = store.addCompareStill(image: tinyImage(), revision: 1, screenIndex: 0, caption: nil)

        store.beginDraft(rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.2), on: before.id)
        store.updateDraftText("old button")
        let onBefore = store.commitDraft()
        store.beginDraft(rect: Rect(x: 0.5, y: 0.5, w: 0.2, h: 0.2), on: after.id)
        store.updateDraftText("new button")
        let onAfter = store.commitDraft()

        #expect(onBefore?.captureId == before.id)
        #expect(onAfter?.captureId == after.id)
        #expect(store.model.captures.first { $0.id == onBefore?.captureId }?.revision == 1)
        #expect(store.model.captures.first { $0.id == onAfter?.captureId }?.revision == 2)
        #expect(store.model.comments(on: before.id).count == 1)
        #expect(store.model.comments(on: after.id).count == 1)
        #expect(recorder.records.allSatisfy { $0.artifactKind == .screenshot })
    }

    @Test func aSetKeepsScreenPositionsAndLabelsAnEarlierScreenWithItsVersion() {
        let store = CommentsSessionStore()
        store.addScreenshotsCaptures(images: [(tinyImage(), "Home"), (tinyImage(), "Pricing")], revision: 3)
        let shown = store.screens[1]
        #expect(store.screenIndexByCaptureId[shown.id] == 1)
        let before = store.addCompareStill(image: tinyImage(), revision: 2, screenIndex: 1, caption: "Pricing")
        #expect(store.screens.count == 2)
        #expect(store.screenLabel(for: before) == "Screen 2 · Pricing (v2)")
        #expect(store.screenLabel(for: shown) == "Screen 2 · Pricing")
        #expect(store.artifactKind(ofCapture: shown.id) == .screenshots)
    }

    @Test func aClickOnTheEarlierSidesCommentInTheListKeepsTheShownScreen() {
        let store = CommentsSessionStore()
        let shown = store.addCapture(image: tinyImage(), revision: 2, isBase: true)
        let before = store.addCompareStill(image: tinyImage(), revision: 1, screenIndex: 0, caption: nil)
        store.beginDraft(rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.2), on: before.id)
        store.updateDraftText("old")
        let comment = store.commitDraft()!
        store.activeCompareBeforeId = before.id
        store.selectComment(id: comment.id, origin: .list)
        #expect(store.currentCapture?.id == shown.id)
        #expect(store.selectedCommentId == comment.id)
    }

    // MARK: - The usage log

    @Test func theSwitchReportsACodedEventAndNothingElse() throws {
        let recorder = UsageRecorder()
        let compare = CompareModel(usage: recorder.reporter)
        compare.userSet(true)
        compare.userSet(true)
        compare.userSet(false)
        #expect(recorder.records == [
            UsageRecord(.compareToggled, variant: .on),
            UsageRecord(.compareToggled, variant: .off),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(recorder.records[0])
        #expect(String(decoding: data, as: UTF8.self) == #"{"event":"compare_toggled","variant":"on"}"#)
        #expect(UsageEvent.compareToggled.isAskBound)
    }

    // MARK: - Copy

    @Test func theCaptionsAndHintsReadPlain() {
        #expect(CompareCopy.before(1) == "Before · revision 1")
        #expect(CompareCopy.after(2) == "After · revision 2")
        #expect(CompareCopy.noEarlier == "No earlier revision yet")
        for text in [CompareCopy.switchLabel, CompareCopy.noEarlier, CompareCopy.showChanges, CompareCopy.noMatch] {
            #expect(!text.contains("—"))
        }
    }
}
