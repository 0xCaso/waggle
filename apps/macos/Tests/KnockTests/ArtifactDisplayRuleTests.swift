import Testing
@testable import Knock

/// `ArtifactDisplayRule.mode`: which display mode a staged artifact gets in
/// the case pane (HAIL-45 contract: "a full-width reading view in the pane
/// for markdown and HTML write-ups... Prototype-like HTML (review asks)
/// keeps today's preview by default; question asks with an HTML artifact
/// default to the reading mode"). Pure and state-free, so this is the one
/// place the mode rule itself needs proving - `ArtifactPreviewLoaderTests`
/// then proves the loader actually applies it.
struct ArtifactDisplayRuleTests {
    @Test func markdownAlwaysReadsInlineRegardlessOfAskKind() {
        #expect(ArtifactDisplayRule.mode(artifactKind: .markdown, caseKind: .question) == .markdownReading)
        #expect(ArtifactDisplayRule.mode(artifactKind: .markdown, caseKind: .review) == .markdownReading)
    }

    // 29 Sep: never a live page in the pane (it caught the scroll wheel).
    @Test func htmlBundleIsTheStillCardForAQuestionAskToo() {
        #expect(ArtifactDisplayRule.mode(artifactKind: .htmlBundle, caseKind: .question) == .card)
    }

    @Test func htmlBundleKeepsTheSmallCardForAReviewAsk() {
        #expect(ArtifactDisplayRule.mode(artifactKind: .htmlBundle, caseKind: .review) == .card)
    }

    @Test func screenshotAndScreenshotsAlwaysUseTheSmallCard() {
        #expect(ArtifactDisplayRule.mode(artifactKind: .screenshot, caseKind: .question) == .card)
        #expect(ArtifactDisplayRule.mode(artifactKind: .screenshot, caseKind: .review) == .card)
        #expect(ArtifactDisplayRule.mode(artifactKind: .screenshots, caseKind: .question) == .card)
        #expect(ArtifactDisplayRule.mode(artifactKind: .screenshots, caseKind: .review) == .card)
    }
}
