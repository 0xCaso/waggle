import Testing
import Foundation
import AppKit
@testable import Knock

/// WAG-375 (issue 9): the text measure keeps the widths one layout pass asks for.
///
/// The layout log of the reporter shows, in a burst, `typeset` running 2 400 times a second at widths that differ by a
/// fraction (`103.96875`, `103.0`, `104.0`) while the heartbeat passes before it typeset 0 times. In the sample of the
/// burst, 354 of the 389 samples inside `AskTextRepresentable.sizeThatFits` are inside `TextMeasurer.height`: the cost of
/// a pass is the typeset, not the lookup. A cache of 8 widths asked in the same order each pass typesets every ask once
/// the ninth width comes.
@MainActor
struct WAG375Tests {
    private func measurer() -> TextMeasurer {
        let measurer = TextMeasurer()
        let text = String(repeating: "A request text that wraps over many lines at every width. ", count: 30)
        measurer.set(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        return measurer
    }

    /// The widths a pass asks one text: the floor, the stack probes, the real column, the ideal size.
    private let widths: [CGFloat] = [80, 111, 135.5, 164, 350, 378.6, 379, 395.6, 396, 424.6, 441.6, 580]

    @Test func aPassOfTwelveWidthsTypesetsOnceNotOnEveryPass() {
        let measurer = measurer()
        for width in widths { _ = measurer.height(forWrapWidth: width) }
        let first = measurer.typesets
        #expect(first == widths.count)
        for _ in 0..<5 { for width in widths { _ = measurer.height(forWrapWidth: width) } }
        #expect(measurer.typesets == first, "five more passes typeset \(measurer.typesets - first) more times")
    }

    @Test func aCachedHeightIsTheHeightOfItsWidth() {
        let measurer = measurer()
        let narrow = measurer.height(forWrapWidth: 135.5)
        let wide = measurer.height(forWrapWidth: 441.6)
        for width in widths { _ = measurer.height(forWrapWidth: width) }
        #expect(measurer.height(forWrapWidth: 135.5) == narrow)
        #expect(measurer.height(forWrapWidth: 441.6) == wide)
        #expect(narrow > wide)
    }

    @Test func theCacheStillHasABound() {
        let measurer = measurer()
        for n in 0..<(TextMeasurer.capacity + 10) { _ = measurer.height(forWrapWidth: 100 + CGFloat(n) * 3) }
        let before = measurer.typesets
        _ = measurer.height(forWrapWidth: 100)
        #expect(measurer.typesets == before + 1, "the oldest width went out when the cache was full")
    }
}
