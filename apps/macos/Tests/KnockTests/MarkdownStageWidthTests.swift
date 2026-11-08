import Testing
import AppKit
@testable import Knock

/// The markdown stage wraps to its own width at every window size (0.1.55).
@MainActor
struct MarkdownStageWidthTests {
    @Test func widthsFollowTheOfferedWidth() {
        #expect(MarkdownStageWidth.documentWidth(offered: 420.7) == 420)
        #expect(MarkdownStageWidth.documentWidth(offered: 0) == 1)
        #expect(MarkdownStageWidth.wrapWidth(documentWidth: 420, inset: 44) == 332)
        #expect(MarkdownStageWidth.wrapWidth(documentWidth: 50, inset: 44) == 1)
    }

    @Test func textViewFollowsTheScrollViewAcrossResizes() {
        let scroll = MarkdownStageScrollView()
        let textView = MarkdownCommentTextView.make()
        scroll.documentView = textView
        textView.autoresizingMask = [.width]
        for width in [900.0, 360.0, 700.0] {
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 500)
            scroll.layoutSubtreeIfNeeded()
            scroll.layout()
            let container = textView.textContainer!
            #expect(textView.frame.width <= width)
            #expect(container.size.width <= width - 2 * textView.textContainerInset.width + 0.5)
        }
    }
}
