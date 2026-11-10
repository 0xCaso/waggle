import Foundation
import Testing
@testable import Knock

/// `ArtifactPreviewPlan.choose`: which of the four looks a review ask's
/// `html_bundle` card gets (HAIL-49 contract: "both: the agent's preview
/// when present, else the agent's size, else 1280 px desktop"; amendment A1:
/// "render at the card's real size" - the no-preview fallback and
/// `preview.html` now render at the card's own live width, not a fixed
/// 1280x800 / 1200x630). Pure and state-free, so this is the one place the
/// choice rule itself needs proving - `ArtifactPreviewLoaderTests` then
/// proves the loader actually applies it, mirroring `ArtifactDisplayRuleTests`
/// one level up.
struct ArtifactPreviewPlanTests {
    private let cardWidth: CGFloat = 620

    @Test func fallsBackToTheCardsOwnSizeWhenNeitherViewportNorPreviewIsGiven() {
        let plan = ArtifactPreviewPlan.choose(viewport: nil, preview: nil, cardWidth: cardWidth)
        #expect(plan == .defaultDesktop(renderSize: CGSize(width: 620, height: 280), isTruncated: false))
        #expect(plan.renderSize == CGSize(width: 620, height: 280))
    }

    @Test func theDefaultFallbackUsesWhicheverCardWidthItIsGiven() {
        let plan = ArtifactPreviewPlan.choose(viewport: nil, preview: nil, cardWidth: 500)
        #expect(plan.renderSize == CGSize(width: 500, height: ArtifactPreviewPlan.cardHeight))
    }

    @Test func aPhoneShapedViewportGetsThePhoneFrame() {
        let viewport = ViewportSize(width: 390, height: 844)
        let plan = ArtifactPreviewPlan.choose(viewport: viewport, preview: nil, cardWidth: cardWidth)
        #expect(plan == .viewportPhone(renderSize: CGSize(width: 390, height: 844)))
    }

    @Test func aWideViewportGetsTheFullFillWidthLook() {
        let viewport = ViewportSize(width: 1024, height: 600)
        let plan = ArtifactPreviewPlan.choose(viewport: viewport, preview: nil, cardWidth: cardWidth)
        #expect(plan == .viewportFull(renderSize: CGSize(width: 1024, height: 600)))
    }

    @Test func aSquareViewportIsNotTreatedAsAPhone() {
        // width == height: not "narrower than tall", so it gets the full
        // fill-width look rather than the phone frame.
        let viewport = ViewportSize(width: 600, height: 600)
        let plan = ArtifactPreviewPlan.choose(viewport: viewport, preview: nil, cardWidth: cardWidth)
        #expect(plan == .viewportFull(renderSize: CGSize(width: 600, height: 600)))
    }

    @Test func aPreviewHtmlTakesPriorityOverAViewportAndRendersAtTheCardsOwnSize() {
        let viewport = ViewportSize(width: 390, height: 844)
        let preview = ArtifactPreviewInfo(kind: .html, path: "/bundle/preview.html")
        let plan = ArtifactPreviewPlan.choose(viewport: viewport, preview: preview, cardWidth: cardWidth)
        #expect(plan == .previewHTML(renderSize: CGSize(width: 620, height: 280)))
        #expect(plan.renderSize == CGSize(width: 620, height: 280))
    }

    @Test func aPreviewImageNeedsNoRenderSize() {
        let preview = ArtifactPreviewInfo(kind: .image, path: "/bundle/preview.png")
        let plan = ArtifactPreviewPlan.choose(viewport: nil, preview: preview, cardWidth: cardWidth)
        #expect(plan == .previewImage)
        #expect(plan.renderSize == nil)
    }

    @Test func onlyPreviewHtmlReportsItself() {
        #expect(ArtifactPreviewPlan.previewHTML(renderSize: .zero).isPreviewHTML)
        #expect(!ArtifactPreviewPlan.previewImage.isPreviewHTML)
        #expect(!ArtifactPreviewPlan.defaultDesktop(renderSize: .zero, isTruncated: false).isPreviewHTML)
        #expect(!ArtifactPreviewPlan.viewportPhone(renderSize: .zero).isPreviewHTML)
        #expect(!ArtifactPreviewPlan.viewportFull(renderSize: .zero).isPreviewHTML)
    }

    // MARK: Amendment A1: the card grows to 420 pt only for a phone viewport.

    @Test func onlyAPhoneViewportGrowsTheCardsHeight() {
        #expect(ArtifactPreviewPlan.viewportPhone(renderSize: .zero).cardHeightForDisplay == 420)
        #expect(ArtifactPreviewPlan.defaultDesktop(renderSize: .zero, isTruncated: false).cardHeightForDisplay == 280)
        #expect(ArtifactPreviewPlan.viewportFull(renderSize: .zero).cardHeightForDisplay == 280)
        #expect(ArtifactPreviewPlan.previewHTML(renderSize: .zero).cardHeightForDisplay == 280)
        #expect(ArtifactPreviewPlan.previewImage.cardHeightForDisplay == 280)
    }

    // MARK: Amendment A1: "re-render when the card width changes by more
    // than ~40 pt (debounced), cache per case+revision+width bucket" - the
    // pure bucket function both the loader's cache key and the card's
    // `.task(id:)` are built on.

    @Test func widthBucketRoundsToTheNearest40Points() {
        #expect(ArtifactPreviewPlan.widthBucket(600) == 600)
        #expect(ArtifactPreviewPlan.widthBucket(1000) == 1000)
        #expect(ArtifactPreviewPlan.widthBucket(1015) == 1000)
        #expect(ArtifactPreviewPlan.widthBucket(1025) == 1040)
    }

    @Test func widthBucketTreatsASmallChangeAsTheSameBucket() {
        // A width change under ~40pt (e.g. a sidebar resize by a few points)
        // must map to the same bucket, so the loader's cache key - and the
        // card's `.task(id:)` - does not restart the render for it.
        #expect(ArtifactPreviewPlan.widthBucket(600) == ArtifactPreviewPlan.widthBucket(610))
    }
}

/// `ArtifactCardGeometry`: the sizing math `htmlSnapshotContent` uses to lay
/// out a rendered snapshot within the card's fixed width and height cap -
/// free of any live image or view, so it is testable without rendering
/// anything (contract: "snapshot sizing math").
struct ArtifactCardGeometryTests {

    @Test func fitHeightScalesToTheCardsHeightPreservingAspectRatio() {
        // A 390x844 phone render, fit to a 280pt-tall card: the same aspect
        // ratio means a width of 280 * 390 / 844.
        let size = ArtifactCardGeometry.fitHeight(imageSize: CGSize(width: 390, height: 844), cardHeight: 280)
        #expect(size.height == 280)
        #expect(abs(size.width - 280 * 390 / 844) < 0.001)
    }

    @Test func fitHeightOfAZeroHeightImageIsZero() {
        #expect(ArtifactCardGeometry.fitHeight(imageSize: .zero, cardHeight: 280) == .zero)
    }
}
