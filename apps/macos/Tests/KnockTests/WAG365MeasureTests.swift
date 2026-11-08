import Testing
import Foundation
import AppKit
@testable import Knock

/// WAG-365 run 2: a repeated width costs no typeset.
@MainActor
struct WAG365MeasureTests {
    private let text = NSAttributedString(
        string: String(repeating: "A long line of words that wraps over many lines at a narrow width. ", count: 20),
        attributes: [.font: NSFont.systemFont(ofSize: 13)])

    @Test func threeWidthsAskedInTurnTypesetThreeTimes() {
        let measurer = TextMeasurer()
        measurer.set(text)
        let widths: [CGFloat] = [320, 480.25, 611]
        var first: [CGFloat] = []
        for round in 0..<50 {
            let heights = widths.map { measurer.height(forWrapWidth: $0) }
            if round == 0 { first = heights } else { #expect(heights == first) }
        }
        #expect(measurer.typesets == 3)
        #expect(first[0] > first[2], "a narrower width wraps to more lines")
    }

    @Test func aChangeOfTheTextForgetsTheHeightsAndTheCacheIsBounded() {
        let measurer = TextMeasurer()
        measurer.set(text)
        for w in 0..<20 { _ = measurer.height(forWrapWidth: 200 + CGFloat(w) * 10) }
        #expect(measurer.typesets == 20)
        for w in 12..<20 { _ = measurer.height(forWrapWidth: 200 + CGFloat(w) * 10) }
        #expect(measurer.typesets == 20, "the last \(TextMeasurer.capacity) widths stay")
        measurer.set(NSAttributedString(string: "short"))
        _ = measurer.height(forWrapWidth: 380)
        #expect(measurer.typesets == 21)
    }

    @Test func anEqualRebuildKeepsTheMeasuresOfTheView() throws {
        let book = SourceBook(sources: [Source(id: "a", kind: "file", label: "Alpha")], citedIn: [])
        let hub = SourcesHub(book: book)
        var face = AskTextFace(style: Theme.AskDoc.Typography.why13_5, weight: .regular, color: .black)
        face.mono = false
        let t = "Some words. [[s:a]] And more words so that it wraps. " + String(repeating: "More text here. ", count: 30)
        let one = AskTextContent.build(text: t, mode: .line, face: face, book: book, showsPills: true)
        let two = AskTextContent.build(text: t, mode: .line, face: face, book: book, showsPills: true)
        #expect(one == two, "an equal rebuild is equal content")
        let view = AskCommentTextView.make()
        let ask = AskCommentsHub(store: CommentsSessionStore())
        let target = AskCommentTarget(.title, itemId: "i")
        view.configure(content: one, target: target, comments: [], selectedId: nil, canComment: true, hub: ask, sourcesHub: hub)
        for w: CGFloat in [300, 500] { _ = view.fittingHeight(forWidth: w) }
        let typesets = view.measurer.typesets
        view.configure(content: two, target: target, comments: [], selectedId: nil, canComment: true, hub: ask, sourcesHub: hub)
        for w: CGFloat in [300, 500, 300, 500] { _ = view.fittingHeight(forWidth: w) }
        #expect(view.measurer.typesets == typesets)
    }

    /// Run 3: the layout counter is off unless an evidence process asks for it, and it keeps no count while off.
    @Test func layoutLogIsOffInATestProcess() {
        #expect(!EvidenceLayoutLog.enabled)
        EvidenceLayoutLog.bump("test")
        EvidenceLayoutLog.event("test", "never built")
        #expect(EvidenceLayoutLog.path == nil)
    }
}
