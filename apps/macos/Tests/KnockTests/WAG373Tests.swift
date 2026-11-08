import Testing
import Foundation
import AppKit
@testable import Knock

/// WAG-373: a measure at a proposed width of 0 (SwiftUI's minimum-size probe, which the layout log of issue 9 shows as
/// `w=20`) must not typeset at a wrap width of 1 pt.
@MainActor
struct WAG373Tests {
    private func view(text: String) -> AskCommentTextView {
        let face = AskTextFace(style: Theme.AskDoc.Typography.why13_5, color: .primary)
        let content = AskTextContent.build(text: text, mode: .line, face: face, book: nil, showsPills: false)
        let view = AskCommentTextView.make()
        view.configure(
            content: content, target: AskCommentTarget(.title), comments: [], selectedId: nil, canComment: true,
            hub: AskCommentsHub(store: CommentsSessionStore()), sourcesHub: nil)
        return view
    }

    @Test func aMinimumSizeProbeDoesNotTypesetAtOnePoint() {
        let text = String(repeating: "A long request text that wraps over many lines. ", count: 40)
        let view = view(text: text)
        let atZero = view.fittingHeight(forWidth: 0)
        let atTwenty = view.fittingHeight(forWidth: 20)
        // One typeset serves both probes: they share the floor width, so the second one hits the cache.
        #expect(view.measurer.typesets == 1, "the probes typeset \(view.measurer.typesets) times")
        #expect(atZero == atTwenty)
        // A one-character-per-line typeset is thousands of points tall; the floor keeps the probe small.
        let floor = AskCommentTextView.minWrapWidth + 2 * AskCommentTextView.inset.width
        #expect(atZero == view.fittingHeight(forWidth: floor))
        #expect(view.measurer.typesets == 1)
        #expect(atZero < 20_000)
    }

    @Test func aRealWidthStillWrapsAtItsOwnWidth() {
        let text = String(repeating: "A long request text that wraps over many lines. ", count: 40)
        let view = view(text: text)
        let narrow = view.fittingHeight(forWidth: 200)
        let wide = view.fittingHeight(forWidth: 600)
        #expect(narrow > wide)
        #expect(view.measurer.typesets == 2)
    }
}
