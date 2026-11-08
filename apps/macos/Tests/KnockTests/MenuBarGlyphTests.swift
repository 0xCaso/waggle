import KnockMark
import Testing
@testable import Knock

/// Contract: HAIL-23's menu-bar glyph is an 18x18 pt template image, so
/// macOS re-tints it for light and dark menu bars.
struct MenuBarGlyphTests {
    @Test func templateImageIsAnEighteenPointTemplate() {
        let image = KnockMark.menuBarTemplateImage()
        #expect(image.isTemplate)
        #expect(image.size.width == 18)
        #expect(image.size.height == 18)
    }
}
