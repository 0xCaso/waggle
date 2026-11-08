import Testing
@testable import Knock

/// WAG-300: a still artifact in the artifact box is plain content. The box owns the header.
struct WAG300StillChromelessTests {
    @Test func pagerKeepsTheCountInTheBox() {
        #expect(ArtifactPreviewCard.pagerLabel(count: 3, chromeless: true) == "1 / 3 screens")
    }

    @Test func pagerStaysAsTodayInTheCard() {
        #expect(ArtifactPreviewCard.pagerLabel(count: 3, chromeless: false) == "1 / 3")
    }
}
