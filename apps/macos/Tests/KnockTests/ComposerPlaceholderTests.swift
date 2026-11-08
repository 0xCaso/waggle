import Testing
@testable import Knock

/// The composer's own placeholder overlay (docs/stories/HAIL-34.md operator
/// report 21:13): `TextField`'s native placeholder text rendered in a color
/// close enough to the background to read as empty, so `ComposerFooterView`
/// draws its own overlay instead, gated on this pure check.
struct ComposerPlaceholderTests {
    @Test func isVisibleWhenTheDraftIsEmpty() {
        #expect(ComposerPlaceholder.isVisible(draftText: ""))
    }

    @Test func isNotVisibleOnceSomethingIsTyped() {
        #expect(!ComposerPlaceholder.isVisible(draftText: "a"))
    }
}
