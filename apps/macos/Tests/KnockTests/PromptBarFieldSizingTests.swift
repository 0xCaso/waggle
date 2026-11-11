import AppKit
import SwiftUI
import Testing
@testable import Knock

/// The answer box's own text view, set up as the bar sets it up, for measuring in tests.
@MainActor
enum PromptBarFieldProbe {
    static func field(_ text: String, width: CGFloat) -> PromptNSTextView {
        let view = PromptNSTextView(frame: .zero)
        PromptTextView.configure(view, font: PromptBarLogic.answerFont)
        view.string = text
        view.setFrameSize(NSSize(width: width, height: 28))
        return view
    }

    static func naturalWidth(_ text: String) -> CGFloat { field(text, width: 400).naturalTextWidth }
}

/// Request page C6: the answer box's height comes from its own text view, it never clips a word, it grows to
/// 40 % of the column (at least six lines) and then scrolls; the field takes its own row only when the text
/// needs the width. C7: quiet buttons go into "More" by their real widths.
@MainActor
struct PromptBarFieldSizingTests {
    private func lines(_ n: Int) -> String { (1...n).map { "line \($0)" }.joined(separator: "\n") }
    private func height(lines n: Int) -> CGFloat { CGFloat(n) * PromptBarLogic.lineHeight + PromptBarLogic.textInset.height * 2 }
    private let longParagraph = String(repeating: "word ", count: 80).trimmingCharacters(in: .whitespaces)

    // MARK: Height from the text view's own layout

    @Test func oneLineIs28Tall() {
        #expect(PromptBarFieldProbe.field("Yes, go ahead", width: 400).measure().contentHeight == 28)
        #expect(PromptBarFieldProbe.field("", width: 400).measure().contentHeight == 28)
    }

    @Test func oneWrappedLineIsTwoLinesTall() {
        // One paragraph that fits a wide field wraps once in a narrower one.
        let text = "Republish it, but keep the intro short and drop the second chart"
        let natural = PromptBarFieldProbe.naturalWidth(text)
        let width = (natural * 0.75).rounded() + PromptBarLogic.textInset.width * 2
        #expect(PromptBarFieldProbe.field(text, width: natural + 40).measure().contentHeight == height(lines: 1))
        #expect(PromptBarFieldProbe.field(text, width: width).measure().contentHeight == height(lines: 2))
    }

    @Test func aTrailingNewlineAddsALine() {
        #expect(PromptBarFieldProbe.field("a\n", width: 400).measure().contentHeight == height(lines: 2))
    }

    @Test func tenLinesGrowInATallColumnAndScrollUnderTheSixLineFloor() {
        let content = PromptBarFieldProbe.field(lines(10), width: 400).measure().contentHeight
        #expect(content == height(lines: 10))
        // A column 800 tall: the cap is 320, so all ten lines show.
        let tall = PromptBarLogic.maxFieldHeight(availableHeight: 800)
        #expect(PromptBarLogic.fieldHeight(contentHeight: content, maxHeight: tall) == content)
        #expect(!PromptBarLogic.scrolls(contentHeight: content, maxHeight: tall))
        // No column height known: six lines, then it scrolls.
        let floor = PromptBarLogic.maxFieldHeight(availableHeight: nil)
        #expect(PromptBarLogic.fieldHeight(contentHeight: content, maxHeight: floor) == height(lines: 6))
        #expect(PromptBarLogic.scrolls(contentHeight: content, maxHeight: floor))
    }

    @Test func fortyLinesAreCappedAt40PercentAndScroll() {
        let content = PromptBarFieldProbe.field(lines(40), width: 400).measure().contentHeight
        #expect(content == height(lines: 40))
        let cap = PromptBarLogic.maxFieldHeight(availableHeight: 900)
        #expect(cap == 360)
        #expect(PromptBarLogic.fieldHeight(contentHeight: content, maxHeight: cap) == 360)
        #expect(PromptBarLogic.scrolls(contentHeight: content, maxHeight: cap))
    }

    @Test func theCapIsNeverUnderSixLines() {
        #expect(PromptBarLogic.maxFieldHeight(availableHeight: nil) == 118)
        #expect(PromptBarLogic.maxFieldHeight(availableHeight: 0) == 118)
        #expect(PromptBarLogic.maxFieldHeight(availableHeight: 200) == 118)
        #expect(PromptBarLogic.maxFieldHeight(availableHeight: 1000) == 400)
    }

    @Test func aWidthChangeMeasuresAgain() {
        let view = PromptBarFieldProbe.field(longParagraph, width: 300)
        let narrow = view.measure()
        // Asked at another width, the view's own layout answers without moving the view...
        let wideAnswer = view.contentHeight(fieldWidth: 700)
        #expect(view.measure() == narrow)
        // ...and once the view is that wide, its measure agrees.
        view.setFrameSize(NSSize(width: 700, height: view.frame.height))
        let wide = view.measure()
        #expect(wide.contentHeight == wideAnswer)
        #expect(wide.contentHeight < narrow.contentHeight)
        #expect(wide.width == 700 && narrow.width == 300)
        // The one-line width does not depend on the width the field has.
        #expect(wide.naturalWidth == narrow.naturalWidth)
    }

    // MARK: The field's own row

    @Test func theFieldMovesToItsOwnRowOnlyWhenTheTextNeedsTheWidth() {
        let controls = PromptBarLogic.controlsWidth(quietLabels: ["Ask for more detail"], sendPillLabel: nil)
        let bar: CGFloat = 520
        let shared = PromptBarLogic.sharedRowFieldWidth(barWidth: bar, controlsWidth: controls) - PromptBarLogic.textInset.width * 2
        func ownRow(_ natural: CGFloat, _ text: String = "text") -> Bool {
            PromptBarLogic.fieldTakesOwnRow(text: text, naturalTextWidth: natural, barWidth: bar, controlsWidth: controls)
        }
        #expect(!ownRow(shared))
        #expect(ownRow(shared + 1))
        #expect(ownRow(10, "two\nlines"))
        // Unmeasured bar: only a line break moves the field.
        #expect(!PromptBarLogic.fieldTakesOwnRow(text: longParagraph, naturalTextWidth: nil, barWidth: 0, controlsWidth: controls))
        #expect(PromptBarLogic.fieldTakesOwnRow(text: "a\nb", naturalTextWidth: nil, barWidth: 0, controlsWidth: controls))
        // Controls on their own row take the field with them only when they leave it under 140 pt (C6).
        #expect(!PromptBarLogic.fieldTakesOwnRow(
            text: "", naturalTextWidth: 0, barWidth: bar, controlsWidth: controls, controlsOwnRow: true))
        let wide = bar - PromptBarLogic.barPadding * 2 - PromptBarLogic.controlSize - PromptBarLogic.controlGap * 2 - 139
        #expect(PromptBarLogic.fieldTakesOwnRow(
            text: "", naturalTextWidth: 0, barWidth: bar, controlsWidth: wide, controlsOwnRow: true))
        // Unmeasured bar with the controls already on their own row: the field goes with them.
        #expect(PromptBarLogic.fieldTakesOwnRow(
            text: "", naturalTextWidth: nil, barWidth: 0, controlsWidth: controls, controlsOwnRow: true))
    }

    /// C6, app check 2026-11-09: "Send comments" pushed the empty field onto its own row in a 440 pt column. An empty
    /// field (placeholder only, which wraps) stays on the button row while at least 140 pt is left for it; only under
    /// that does it move. Typed text moves it only when the text needs the width.
    @Test func anEmptyFieldStaysOnTheButtonRowWhileItKeeps140Points() {
        // The labels' real widths in the bar's text styles (Inter Tight 12, measured in the app).
        let widths = PromptBarLogic.ControlWidths.measured(
            quiet: [PromptBarLogic.askForLabel: 46],
            pill: ["Send comments": 89, "Rule out 2, keep talking": 125, "Rule out 2": 54])
        let leading = PromptBarLogic.leadingWidth(askForLabelWidth: 46)
        func plan(_ pills: [String?], bar: CGFloat) -> PromptBarLogic.ControlsPlan {
            PromptBarLogic.controlsPlan(
                rowWidth: bar - PromptBarLogic.barPadding * 2, quietLabels: [], pillLabels: pills, widths: widths,
                leadingWidth: leading)
        }
        func ownRow(_ text: String, natural: CGFloat, _ plan: PromptBarLogic.ControlsPlan, bar: CGFloat) -> Bool {
            PromptBarLogic.fieldTakesOwnRow(
                text: text, naturalTextWidth: natural, barWidth: bar, controlsWidth: plan.width(widths),
                controlsOwnRow: plan.ownRow, leadingWidth: leading)
        }
        func field(_ plan: PromptBarLogic.ControlsPlan, bar: CGFloat) -> CGFloat {
            PromptBarLogic.sharedRowFieldWidth(barWidth: bar, controlsWidth: plan.width(widths), leadingWidth: leading)
        }
        // The shared-row rule at the column's 440 pt (the answer box keeps its own row since 2026-11-10; the rule stays).
        let bar: CGFloat = 440
        let sendComments = plan(["Send comments"], bar: bar)
        #expect(sendComments.sendPillLabel == "Send comments")
        #expect(field(sendComments, bar: bar) >= PromptBarLogic.minSharedFieldWidth)
        #expect(!ownRow("", natural: 0, sendComments, bar: bar), "the empty field keeps the row")
        // A short typed answer stays too; a line longer than the field moves it.
        #expect(!ownRow("ok", natural: 14, sendComments, bar: bar))
        #expect(ownRow("a long answer", natural: field(sendComments, bar: bar), sendComments, bar: bar))
        // A bar 2 pt narrower leaves the field 1 pt under 140: now it moves.
        let tight = bar - (field(sendComments, bar: bar) - PromptBarLogic.minSharedFieldWidth) - 1
        let under = plan(["Send comments"], bar: tight)
        #expect(field(under, bar: tight) < PromptBarLogic.minSharedFieldWidth)
        #expect(ownRow("", natural: 0, under, bar: tight))
        // The full-size column at its narrowest (340 pt, 16 pt insets): "Rule out 2, keep talking" leaves too little.
        let narrow = plan(["Rule out 2, keep talking", "Rule out 2"], bar: 308)
        #expect(ownRow("", natural: 0, narrow, bar: 308))
        #expect(PromptBarLogic.minSharedFieldWidth == 140)
    }

    // MARK: Quiet buttons by their real widths (C7)

    @Test func measuredLabelsWiderThanTheEstimateMoveQuietButtonsIntoMore() {
        let quiet = ["Ask for more detail", "Change"]
        let pills: [String?] = ["Approve section"]
        let estimated = PromptBarLogic.ControlsPlan(quietLabels: quiet, overflowLabels: [], sendPillLabel: "Approve section")
        // A row that fits every button by the estimate, on the controls' own row.
        let row = estimated.width + PromptBarLogic.controlSize + PromptBarLogic.controlGap
        #expect(PromptBarLogic.controlsPlan(rowWidth: row, quietLabels: quiet, pillLabels: pills).overflowLabels.isEmpty)
        // The real labels are 30 pt wider each: the leftmost quiet button goes into "More", none is cut.
        let wider = PromptBarLogic.ControlWidths.measured(
            quiet: Dictionary(uniqueKeysWithValues: quiet.map { ($0, PromptBarLogic.quietButtonWidth($0) - 16 + 30) }), pill: [:])
        let plan = PromptBarLogic.controlsPlan(rowWidth: row, quietLabels: quiet, pillLabels: pills, widths: wider)
        #expect(plan.overflowLabels == ["Ask for more detail"])
        #expect(plan.quietLabels == ["Change"])
        #expect(plan.sendPillLabel == "Approve section")
        #expect(plan.width(wider) + PromptBarLogic.controlSize + PromptBarLogic.controlGap <= row)
    }

    @Test func anUnmeasuredLabelFallsBackToTheEstimate() {
        let widths = PromptBarLogic.ControlWidths.measured(quiet: [:], pill: [:])
        #expect(widths.quiet("Open review") == PromptBarLogic.quietButtonWidth("Open review"))
        #expect(widths.send("Send + 2 comments") == PromptBarLogic.sendButtonWidth(pillLabel: "Send + 2 comments"))
        #expect(widths.send(nil) == PromptBarLogic.sendHeight)
    }

    // MARK: The bar hosted (no window): the field is as tall as its text, on the first frame and after edits

    final class Model: ObservableObject {
        @Published var text: String
        init(_ text: String) { self.text = text }
    }

    private struct Host: View {
        @ObservedObject var model: Model
        @State var focused = false
        var body: some View {
            PromptBarCore(
                text: $model.text, placeholder: "Add a note, or ask something…", quietLabels: ["Ask for more detail"],
                canSend: true, onSend: {}, isFocused: $focused)
                .environment(\.answerBoxAvailableHeight, 900)
        }
    }

    /// Lays out and lets the main queue run until `done` holds, so the field's measures reach the bar.
    /// Polls with a deadline (AGENTS.md): a loaded runner needs more passes, a fast one stops at once.
    private func settle(_ host: NSView, until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        host.layoutSubtreeIfNeeded()
        while !done(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            host.layoutSubtreeIfNeeded()
        }
    }

    /// Settles until the hosted field exists.
    private func settle(_ host: NSView) async throws {
        try await settle(host) { fieldViews(host) != nil }
    }

    private func fieldViews(_ root: NSView) -> (NSScrollView, PromptNSTextView)? {
        if let scroll = root as? NSScrollView, let text = scroll.documentView as? PromptNSTextView { return (scroll, text) }
        for sub in root.subviews { if let found = fieldViews(sub) { return found } }
        return nil
    }

    private func hosted(_ text: String, width: CGFloat) -> NSHostingView<Host> {
        hosted(Model(text), width: width)
    }

    private func hosted(_ model: Model, width: CGFloat) -> NSHostingView<Host> {
        let host = NSHostingView(rootView: Host(model: model))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        return host
    }

    @Test func aLongTextShowsEveryLineOnTheFirstFrame() throws {
        let host = hosted(longParagraph, width: 420)
        host.layoutSubtreeIfNeeded()
        let (scroll, text) = try #require(fieldViews(host))
        // Before any measure was reported back, the field is as tall as its own layout at its width.
        let needed = text.contentHeight(fieldWidth: scroll.frame.width)
        #expect(needed > height(lines: 2))
        #expect(scroll.frame.height >= needed - 0.5, "field \(scroll.frame.height) < text \(needed)")
    }

    @Test func theHostedFieldKeepsItsOwnRowAndGrowsWithEdits() async throws {
        let host = hosted("Short", width: 420)
        try await settle(host) { fieldViews(host)?.0.frame.height == 28 }
        let (scroll, text) = try #require(fieldViews(host))
        #expect(scroll.frame.height == 28)
        // The field has its own full-width row from the start (2026-11-10), so a long text does not move it.
        let ownRowWidth = scroll.frame.width
        #expect(ownRowWidth > 420 / 2)
        // The person types a long paragraph.
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.insertText(" " + longParagraph, replacementRange: text.selectedRange())
        try await settle(host) { scroll.frame.height == text.measure().contentHeight }
        let measured = text.measure()
        // The same text view on the new row: the caret, undo and IME state stay.
        #expect(try #require(fieldViews(host)).1 === text)
        #expect(scroll.frame.width == ownRowWidth, "the field kept its full-width row")
        #expect(scroll.frame.height == measured.contentHeight, "field \(scroll.frame.height) vs text \(measured.contentHeight)")
        #expect(measured.contentHeight > height(lines: 2))
        #expect(!scroll.hasVerticalScroller)
        // Forty lines: capped at 40 % of 900 and the scroller is on screen.
        text.insertText("\n" + lines(40), replacementRange: text.selectedRange())
        try await settle(host) { scroll.frame.height == 360 && scroll.hasVerticalScroller }
        #expect(scroll.frame.height == 360)
        #expect(scroll.hasVerticalScroller && !scroll.autohidesScrollers && scroll.scrollerStyle == .legacy)
    }

    @Test func textSetByTheAppLeavesTheCaretAtTheEnd() async throws {
        let model = Model("Draft")
        let host = hosted(model, width: 420)
        try await settle(host)
        let (_, text) = try #require(fieldViews(host))
        text.setSelectedRange(NSRange(location: 0, length: 0))
        model.text = "Use this reply, please"
        try await settle(host) {
            text.string == "Use this reply, please" && text.selectedRange().location == (text.string as NSString).length
        }
        #expect(text.string == "Use this reply, please")
        #expect(text.selectedRange() == NSRange(location: (text.string as NSString).length, length: 0))
    }
}
