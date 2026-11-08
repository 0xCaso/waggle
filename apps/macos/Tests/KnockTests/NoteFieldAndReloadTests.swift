import AppKit
import Foundation
import Testing
@testable import Knock

@Suite("HAIL-233 note field growth")
struct NoteFieldLogicTests {
    @Test func shortTextIsOneLine() {
        #expect(NoteFieldLogic.lineCount(text: "") == 1)
        #expect(NoteFieldLogic.lineCount(text: "Make this bigger") == 1)
        #expect(NoteFieldLogic.fieldHeight(text: "Make this bigger") == NoteFieldLogic.lineHeight)
    }

    @Test func longTextWrapsAndTheFieldGrows() {
        let text = String(repeating: "wrap me please ", count: 8)
        let lines = NoteFieldLogic.lineCount(text: text)
        #expect(lines > 1)
        #expect(NoteFieldLogic.fieldHeight(totalLines: lines) == CGFloat(min(lines, 4)) * NoteFieldLogic.lineHeight)
    }

    @Test func newlinesAddLines() {
        #expect(NoteFieldLogic.lineCount(text: "a\nb") == 2)
        #expect(NoteFieldLogic.lineCount(text: "a\nb\n") == 3)
    }

    @Test func growsFromOneToFourLinesThenScrolls() {
        let heights = (1...6).map { NoteFieldLogic.fieldHeight(totalLines: $0) }
        #expect(heights == [1, 2, 3, 4, 4, 4].map { CGFloat($0) * NoteFieldLogic.lineHeight })
        #expect((1...4).allSatisfy { !NoteFieldLogic.scrolls(totalLines: $0) })
        #expect(NoteFieldLogic.scrolls(totalLines: 5))
        #expect(NoteFieldLogic.visibleLines(totalLines: 9) == 4)
    }

    @Test func popoverGrowsWithTheFieldAndStopsAtFourLines() {
        let one = NoteFieldLogic.popoverHeight(text: "x")
        let four = NoteFieldLogic.popoverHeight(text: "a\nb\nc\nd")
        let ten = NoteFieldLogic.popoverHeight(text: "a\nb\nc\nd\ne\nf\ng\nh\ni\nj")
        #expect(four - one == 3 * NoteFieldLogic.lineHeight)
        #expect(ten == four)
    }

    @Test func tallPopoverStaysOnScreen() {
        let container = CGSize(width: 600, height: 300)
        let height = NoteFieldLogic.popoverHeight(text: "a\nb\nc\nd\ne")
        // A region near the bottom edge: the popover centre keeps the whole box inside.
        let point = CommentCaptureStageView.popoverPosition(
            for: CGRect(x: 100, y: 290, width: 20, height: 10), in: container, height: height)
        #expect(point.y + height / 2 <= container.height)
        #expect(point.y - height / 2 >= 0)
    }
}

@Suite("HAIL-233 arrow key routing")
@MainActor
struct ReviewArrowKeysTests {
    @Test func arrowsFlipScreensWhenNoTextFieldHasFocus() {
        #expect(ReviewArrowKeys.route(keyCode: 123, modifiers: [], firstResponder: nil) == .previous)
        #expect(ReviewArrowKeys.route(keyCode: 124, modifiers: [], firstResponder: NSView()) == .next)
    }

    @Test func focusedTextFieldKeepsTheArrows() {
        let textView = NSTextView()
        let field = NSTextField()
        for responder: NSResponder in [textView, field] {
            for code: UInt16 in [123, 124, 125, 126] {
                #expect(ReviewArrowKeys.route(keyCode: code, modifiers: [], firstResponder: responder) == .passThrough)
            }
        }
    }

    @Test func otherKeysAndModifiedArrowsPassThrough() {
        #expect(ReviewArrowKeys.route(keyCode: 125, modifiers: [], firstResponder: nil) == .passThrough)
        #expect(ReviewArrowKeys.route(keyCode: 0, modifiers: [], firstResponder: nil) == .passThrough)
        #expect(ReviewArrowKeys.route(keyCode: 123, modifiers: .command, firstResponder: nil) == .passThrough)
        #expect(ReviewArrowKeys.route(keyCode: 124, modifiers: [.numericPad, .function], firstResponder: nil) == .next)
    }
}

@Suite("HAIL-233 prototype reload")
@MainActor
struct PrototypeReloadTests {
    final class FakeWebView: ReloadableWebView {
        var calls: [String] = []
        func clearWebsiteData() async { calls.append("clear") }
        func loadEntry(_ entry: URL, directory: URL) { calls.append("load \(entry.lastPathComponent) in \(directory.lastPathComponent)") }
    }

    @Test func reloadClearsStateThenLoadsTheEntryAgain() async {
        let web = FakeWebView()
        let dir = URL(fileURLWithPath: "/tmp/rev1", isDirectory: true)
        await PrototypeReload.run(web, entry: dir.appendingPathComponent("index.html"), directory: dir)
        #expect(web.calls == ["clear", "load index.html in rev1"])
    }

    @Test func modelRunsTheRegisteredAction() async {
        let model = PrototypeZoomModel()
        var ran = 0
        model.reload()  // nothing registered: does nothing
        model.reloadAction = { ran += 1 }
        model.reload()
        await Task.yield()
        #expect(ran == 1)
    }
}
