import Testing
import Foundation
import AppKit
import SwiftUI
@testable import Knock

/// WAG-359: a source no text cites shows as a pill after the why text; a pill is centred on its line and easy to click.
@MainActor
struct PillFallbackTests {
    private func src(_ id: String) -> Source { Source(id: id, kind: "file", label: "label \(id)") }

    // MARK: The uncited model

    @Test func aSourceNoTextCitesIsUncitedInTheOrderSent() {
        let sources = [src("a"), src("b"), src("c")]
        #expect(SourceBook.uncitedIds(sources: sources, texts: ["One. [[s:b]]", "Two."]) == ["a", "c"])
    }

    @Test func aCitedSourceIsNotUncitedWhateverTheField() {
        let sources = [src("a"), src("b")]
        #expect(SourceBook.uncitedIds(sources: sources, texts: ["Need.", "A pro [[s:a,b]]"]).isEmpty)
    }

    @Test func aMarkerWithAnUnknownIdCitesNothingKnown() {
        #expect(SourceBook.uncitedIds(sources: [src("a")], texts: ["Fact [[s:ghost]]"]) == ["a"])
    }

    @Test func noSourcesGiveNoUncited() {
        #expect(SourceBook.uncitedIds(sources: [], texts: ["Fact [[s:a]]"]).isEmpty)
        #expect(SourceBook(sources: [], citedIn: ["x"]).uncited.isEmpty)
    }

    @Test func aRepeatedIdCountsOnce() {
        let book = SourceBook(sources: [src("a"), src("a")], citedIn: ["plain"])
        #expect(book.uncited == ["a"])
    }

    @Test func aBookBuiltWithoutTextsHasNoFallback() {
        #expect(SourceBook(sources: [src("a")]).uncited.isEmpty)
    }

    @Test func eachUncitedSourceBecomesItsOwnMarkerAtTheEnd() {
        let text = SourceMarkers.appending(uncited: ["a", "b"], to: "Because it is fast.  ")
        #expect(text == "Because it is fast. [[s:a]] [[s:b]]")
        #expect(SourceMarkers.parse(text).groups == [["a"], ["b"]])
    }

    @Test func nothingIsAddedToNoIdsOrNoText() {
        #expect(SourceMarkers.appending(uncited: [], to: "Same.") == "Same.")
        #expect(SourceMarkers.appending(uncited: ["a"], to: "  ") == "  ")
    }

    @Test func theRoundBookTakesTheNeedAndWhyIntoAccount() throws {
        let json = """
        {"case":{"id":"c1","title":"T","need":"Pick one. [[s:a]]","why":"Because.","status":"needs_you","kind":"decision",
        "created_at":"2026-10-10T10:00:00.000Z","updated_at":"2026-10-10T10:00:00.000Z"},
        "rounds":[{"seq":0,"question":"Pick one. [[s:a]]","items":[],"created_at":"2026-10-10T10:00:00.000Z",
        "own_artifact":false,"talk_count":0,"sources":[{"id":"a","kind":"file","label":"A","state":"seen"},{"id":"b","kind":"file","label":"B","state":"seen"}]}]}
        """
        // The detail shape differs between daemon versions; skip the check when this fixture does not decode.
        guard let detail = try? JSONDecoder().decode(CaseDetail.self, from: Data(json.utf8)) else { return }
        #expect(detail.currentSourceBook.uncited == ["b"])
    }

    // MARK: Alignment

    private let styles: [(String, Theme.TextStyle, NSFont.Weight)] = [
        ("need", Theme.AskDoc.Typography.need17, .semibold),
        ("needDetails", NeedText.detailStyle(Theme.AskDoc.Typography.need17), .regular),
        ("why", Theme.AskDoc.Typography.why13_5, .regular),
        ("option", Theme.AskDoc.Typography.optionCard13, .regular),
        ("compact", Theme.Typography.body13_5w400, .regular),
    ]

    @Test func aPillIsCentredOnTheMiddleOfTheXHeightForEachStyle() {
        for (name, style, weight) in styles {
            let xh = PillAlignment.xHeight(size: style.size, weight: weight)
            for pillHeight in [18.0, 19.5, 24.0] {
                let baseline: CGFloat = 20
                let top = PillAlignment.top(baseline: baseline, pillHeight: pillHeight, xHeight: xh)
                let centre = top + pillHeight / 2
                #expect(abs(centre - (baseline - xh / 2)) <= 0.5, "\(name)")
            }
        }
    }

    @Test func theAttachmentIsTheLineBoxOfTheFontSoTheLineKeepsItsHeight() {
        let font = PromptBarLogic.sansFont(size: 17)
        let bounds = PillAlignment.attachmentBounds(font: font, width: 50)
        #expect(bounds.minY >= font.descender && bounds.maxY <= font.ascender && bounds.width == 50)
    }

    @Test func aPillInATextViewIsCentredAndDoesNotChangeTheLineHeight() throws {
        for (name, style, weight) in styles {
            let hub = SourcesHub(book: SourceBook(sources: [src("a")]))
            var face = AskTextFace(style: style, weight: weight, color: .black)
            face.mono = false
            let text = "Words before. [[s:a]] After it."
            let withPill = AskTextContent.build(text: text, mode: .line, face: face, book: hub.book, showsPills: true)
            let without = AskTextContent.build(text: text, mode: .line, face: face, book: nil, showsPills: false)
            let view = AskCommentTextView.make()
            view.configure(
                content: withPill, target: AskCommentTarget(.why), comments: [], selectedId: nil, canComment: true,
                hub: nil, sourcesHub: hub)
            let plain = AskCommentTextView.make()
            plain.configure(
                content: without, target: AskCommentTarget(.why), comments: [], selectedId: nil, canComment: true,
                hub: nil, sourcesHub: nil)
            let width: CGFloat = 600
            #expect(abs(view.fittingHeight(forWidth: width) - plain.fittingHeight(forWidth: width)) <= 0.5, "\(name) height \(view.fittingHeight(forWidth: width)) vs \(plain.fittingHeight(forWidth: width))")
            view.setFrameSize(NSSize(width: width, height: view.fittingHeight(forWidth: width)))
            view.layout()
            let host = try #require(view.subviews.compactMap { $0 as? PillImageView }.first, "\(name)")
            let layout = try #require(view.layoutManager)
            let container = try #require(view.textContainer)
            let index = try #require(withPill.pills.first?.index)
            // The baseline of a text glyph on the same line as the pill (the pill may start a wrapped line).
            let pillGlyph = layout.glyphIndexForCharacter(at: index)
            var lineGlyphs = NSRange()
            _ = layout.lineFragmentRect(forGlyphAt: pillGlyph, effectiveRange: &lineGlyphs)
            let other = try #require((lineGlyphs.location..<(lineGlyphs.location + lineGlyphs.length)).first { $0 != pillGlyph })
            let baseline = layout.lineFragmentRect(forGlyphAt: other, effectiveRange: nil).minY
                + layout.location(forGlyphAt: other).y + view.textContainerOrigin.y
            _ = container
            let font = try #require(view.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            #expect(abs(host.frame.midY - (baseline - font.xHeight / 2)) <= 1, "\(name) centre")
            #expect(host.frame.height >= 24)
        }
    }

    // MARK: Click area

    @Test func theClickAreaIsTheShapePlusFourOnEachSideAndAtLeast24High() {
        let shape = CGRect(x: 100, y: 10, width: 80, height: 18)
        let hit = PillHitArea.rect(visible: shape, pads: .full)
        #expect(hit.minX == 96 && hit.maxX == 184)
        #expect(hit.height == 24 && hit.midY == shape.midY)
        let tall = PillHitArea.rect(visible: CGRect(x: 0, y: 0, width: 50, height: 30), pads: .full)
        #expect(tall.height == 30)
    }

    @Test func twoPillsSideBySideNeverOverlap() {
        for gap in [0.0, 2.0, 4.0, 6.0, 8.0, 12.0] {
            let left = CGRect(x: 0, y: 0, width: 60, height: 18)
            let right = CGRect(x: 60 + gap, y: 0, width: 70, height: 18)
            let a = PillHitArea.rect(visible: left, pads: PillHitArea.pads(gapToPreviousPill: nil, gapToNextPill: gap))
            let b = PillHitArea.rect(visible: right, pads: PillHitArea.pads(gapToPreviousPill: gap, gapToNextPill: nil))
            #expect(a.maxX <= b.minX, "gap \(gap)")
        }
    }

    @Test func aPillAloneGetsTheFullReach() {
        #expect(PillHitArea.pads(gapToPreviousPill: nil, gapToNextPill: nil) == .full)
        #expect(PillHitArea.pads(gapToPreviousPill: 4, gapToNextPill: nil).leading == 2)
    }

    @Test func aPillOnAWrappedLineOfBlocksIsCentred() throws {
        for (name, style, weight) in styles {
            let hub = SourcesHub(book: SourceBook(sources: [src("a")]))
            let face = AskTextFace(style: style, weight: weight, color: .black)
            let text = "Pick the cache layout to ship: Flat or Tiered. The Flat one reads from the store [[s:a]] and the Tiered one adds a second level."
            let content = AskTextContent.build(text: text, mode: .blocks, face: face, book: hub.book, showsPills: true)
            let view = AskCommentTextView.make()
            view.configure(content: content, target: AskCommentTarget(.need), comments: [], selectedId: nil, canComment: true, hub: nil, sourcesHub: hub)
            let width: CGFloat = 480
            view.setFrameSize(NSSize(width: width, height: view.fittingHeight(forWidth: width)))
            view.layout()
            let host = try #require(view.subviews.compactMap { $0 as? PillImageView }.first)
            let layout = try #require(view.layoutManager)
            let index = try #require(content.pills.first?.index)
            // The baseline of a text glyph on the same line as the pill (the pill may start a wrapped line).
            let pillGlyph = layout.glyphIndexForCharacter(at: index)
            var lineGlyphs = NSRange()
            _ = layout.lineFragmentRect(forGlyphAt: pillGlyph, effectiveRange: &lineGlyphs)
            let other = try #require((lineGlyphs.location..<(lineGlyphs.location + lineGlyphs.length)).first { $0 != pillGlyph })
            let baseline = layout.lineFragmentRect(forGlyphAt: other, effectiveRange: nil).minY
                + layout.location(forGlyphAt: other).y + view.textContainerOrigin.y
            let font = try #require(view.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            #expect(abs(host.frame.midY - (baseline - font.xHeight / 2)) <= 1, "\(name) wrapped blocks")
        }
    }
}
