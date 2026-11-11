import AppKit
import Foundation
import Testing
@testable import Knock

/// Task 11 (decision 2026-11-10-option-card-gist-and-facts): pros and cons as a string or `{ gist, detail }`, facts,
/// the closed card's counts and first words, the hanging indent, the whole-word cut, and the need's chips and numbers.
@MainActor
struct OptionGistTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Decoding both forms

    @Test func anOptionDecodesStringAndObjectPointsMixedInOneList() throws {
        let option = try decode(Option.self, """
            {"id":"a","label":"One store file","title":"One store file","facts":["~2 h","no migration","src/store.ts"],
             "pros":["Easy to test",{"gist":"One file to change","detail":"Only src/store.ts changes, so the review stays small"}],
             "cons":[{"gist":"Memory only","detail":"The cache stays in memory and is lost on restart"}],
             "effects":["Touches the store only"]}
            """)
        #expect(option.proPoints == [
            OptionPoint(detail: "Easy to test"),
            OptionPoint(gist: "One file to change", detail: "Only src/store.ts changes, so the review stays small"),
        ])
        #expect(option.conPoints == [OptionPoint(gist: "Memory only", detail: "The cache stays in memory and is lost on restart")])
        // Every older view reads the full points.
        #expect(option.pros == ["Easy to test", "Only src/store.ts changes, so the review stays small"])
        #expect(option.cons == ["The cache stays in memory and is lost on restart"])
        #expect(option.facts == ["~2 h", "no migration", "src/store.ts"])
        #expect(option.effects == ["Touches the store only"])
    }

    @Test func anOldOptionDecodesAsBeforeWithNoFactsAndNoGists() throws {
        let option = try decode(Option.self, #"{"id":"a","label":"Keep it","pros":["Known"],"cons":["Two copies"]}"#)
        #expect(option.pros == ["Known"])
        #expect(option.cons == ["Two copies"])
        #expect(option.facts.isEmpty)
        #expect(option.proPoints.allSatisfy { $0.gist == nil })
    }

    @Test func aBadEntryOrBadFactsDoNotDropTheAsk() throws {
        let option = try decode(Option.self, #"{"id":"a","label":"A","pros":["Good",42,{"detail":"Only a detail"},{"gist":"Only a gist"}],"facts":"oops"}"#)
        #expect(option.proPoints == [OptionPoint(detail: "Good"), OptionPoint(detail: "Only a detail"), OptionPoint(detail: "Only a gist")])
        #expect(option.facts.isEmpty)
    }

    @Test func aPointWithoutAGistEncodesAsAPlainStringAgain() throws {
        let option = Option(id: "a", label: "A", proPoints: ["Plain", OptionPoint(gist: "Short", detail: "The long one")])
        let json = String(decoding: try JSONEncoder().encode(option), as: UTF8.self)
        #expect(json.contains(#""pros":["Plain",{"#))
        #expect(try decode(Option.self, json) == option)
    }

    @Test func aPointOptionOfTheQuestionsShapeDecodesBothForms() throws {
        let point = try decode(PointOption.self, #"{"label":"A","pros":["x",{"gist":"g","detail":"d"}],"facts":["1 h"]}"#)
        #expect(point.proPoints == [OptionPoint(detail: "x"), OptionPoint(gist: "g", detail: "d")])
        #expect(point.pros == ["x", "d"])
        #expect(point.facts == ["1 h"])
    }

    @Test func anItemOptionKeepsItsGistsFactsDescriptionAndReason() throws {
        let item = try decode(Item.self, """
            {"id":"i1","select":"one","options":[{"id":"o1","label":"Ship it now, then fix the rest","title":"Ship now",
             "pros":[{"gist":"Fast","detail":"It ships today"}],"facts":["today"],"why":"It is the smallest step"}],
             "recommendation":["o1"]}
            """)
        let point = QuestionPoint(item: item, fallbackText: "Which?")
        let option = try #require(point.options?.first)
        #expect(option.proPoints == [OptionPoint(gist: "Fast", detail: "It ships today")])
        #expect(option.facts == ["today"])
        #expect(option.why == "It is the smallest step")
        #expect(option.description != nil)
    }

    // MARK: - Closed card

    @Test func theClosedCardCountsProsAndCons() {
        #expect(OptionGist.tally(pros: ["a", "b", "c"], cons: ["d"]) == OptionGist.Tally(pros: 3, cons: 1))
        #expect(OptionGist.tally(pros: [], cons: []) == nil)
        #expect(OptionGist.Tally(pros: 3, cons: 1).spoken == "3 pros, 1 con")
        #expect(OptionGist.Tally(pros: 0, cons: 2).spoken == "2 cons")
        #expect(TallyView.width(OptionGist.Tally(pros: 3, cons: 3)) > TallyView.width(OptionGist.Tally(pros: 3, cons: 0)))
    }

    @Test func atMostThreeFactsShowAndTheRestStay() {
        let facts = ["a", "b", "c", "d"]
        #expect(OptionGist.shownFacts(facts) == ["a", "b", "c"])
        #expect(OptionGist.extraFacts(facts) == ["d"])
        #expect(OptionGist.hasHiddenDetail(pros: [], cons: [], effects: [], facts: facts, descriptionCut: false, reasonCut: false))
    }

    @Test func theClosedTeaserCutsEachSideAtAWholeWord() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) }
        let teaser = OptionGist.closedTeaser(
            pro: "Removes the noise from the shared repo state", con: "The release waits a week", width: 40, gap: 4, measure: measure)
        let pro = teaser.pro ?? "", con = teaser.con ?? ""
        #expect(pro.hasSuffix("…") && con.hasSuffix("…"))
        #expect(measure(pro) + measure(con) + 4 <= 40)
        #expect("Removes the noise from the shared repo state".hasPrefix(String(pro.dropLast())))
        // A short side keeps its full text and leaves the room to the other.
        let short = OptionGist.closedTeaser(pro: "No cost", con: "Only 5 cycles: 4 to 1 can still be chance", width: 40, gap: 4, measure: measure)
        #expect(short.pro == "No cost")
        #expect((short.con ?? "").count > 20)
        // A gist shows as it is.
        let gist = OptionGist.closedTeaser(pro: OptionPoint(gist: "Fast", detail: "It ships today, before lunch"), con: nil, width: 40, gap: 4, measure: measure)
        #expect(gist.pro == "Fast")
    }

    // MARK: - Whole-word cut

    @Test func theCutIsAtAWholeWordWithAnEllipsis() {
        let text = "Ship the release first, then run the fixed test"
        let cut = OptionGist.cutAtWord(text, fits: { $0.count <= 24 })
        #expect(cut.isCut)
        #expect(cut.text == "Ship the release first…")
        let words = Set(text.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) })
        #expect(cut.text.dropLast().split(separator: " ").allSatisfy { words.contains(String($0).trimmingCharacters(in: .punctuationCharacters)) })
        #expect(OptionGist.cutAtWord("Short", fits: { _ in true }) == ("Short", false))
        // One long word is never cut inside.
        #expect(OptionGist.cutAtWord("Supercalifragilistic", fits: { $0.count < 5 }).text == "Supercalifragilistic")
    }

    @Test func showTheFullPointsShowsOnlyWhenSomethingIsHidden() {
        #expect(!OptionGist.hasHiddenDetail(pros: ["a"], cons: ["b"], effects: [], facts: [], descriptionCut: false, reasonCut: false))
        #expect(OptionGist.hasHiddenDetail(
            pros: [OptionPoint(gist: "a", detail: "a long a")], cons: [], effects: [], facts: [], descriptionCut: false, reasonCut: false))
        #expect(!OptionGist.hasHiddenDetail(
            pros: [OptionPoint(gist: "same", detail: "same")], cons: [], effects: [], facts: [], descriptionCut: false, reasonCut: false))
        #expect(OptionGist.hasHiddenDetail(pros: [], cons: [], effects: ["x"], facts: [], descriptionCut: false, reasonCut: false))
        #expect(OptionGist.hasHiddenDetail(pros: [], cons: [], effects: [], facts: [], descriptionCut: true, reasonCut: false))
    }

    @Test func voiceOverReadsTheFullPoint() {
        let point = OptionPoint(gist: "Memory only", detail: "The cache stays in memory and is lost on restart")
        #expect(OptionGist.spokenPoint(point, word: "Con") == "Con: Memory only. The cache stays in memory and is lost on restart")
        #expect(OptionGist.spokenPoint("Easy to test", word: "Pro") == "Pro: Easy to test")
    }

    // MARK: - Hanging indent

    @Test func aWrappedPointStartsUnderTheTextNotUnderTheSign() {
        FontRegistration.registerBundledFonts()
        let line = CSSText(
            runs: [.init(text: "+", semibold: true, color: .green), .init(text: "The release goes out before its own test, so a bad result comes late", color: .black)],
            lineHeight: GistCardStyle.pointLineHeight, hanging: true)
        let storage = NSTextStorage(attributedString: line.attributed)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 160, height: 1000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        var starts: [CGFloat] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, used, _, _, _ in starts.append(used.minX) }
        #expect(starts.count >= 3)
        // The first line holds the sign in its 11 pt column; the text after it starts at 17, as every wrapped line does.
        let text = storage.string as NSString
        let textStart = layout.glyphIndexForCharacter(at: text.range(of: "The").location)
        #expect(abs(layout.location(forGlyphAt: textStart).x - OptionGist.Hanging.textInset) < 0.5)
        for start in starts.dropFirst() { #expect(abs(start - OptionGist.Hanging.textInset) < 0.5) }
        // The sign sits in the middle of its column.
        #expect(starts[0] > 0 && starts[0] < OptionGist.Hanging.markColumn / 2)
        #expect(OptionGist.Hanging.textInset == 17)
    }

    /// A point that wraps asks for the room of every line it draws, so the next point starts below it (no overlap).
    @Test func aWrappedPointAsksForTheHeightOfAllItsLines() {
        FontRegistration.registerBundledFonts()
        let line = CSSText(
            runs: [.init(text: "+", semibold: true, color: .green), .init(text: "One proof for each work, and you select it", color: .black)],
            lineHeight: GistCardStyle.pointLineHeight, hanging: true)
        let one = CSSTextNSView.usedSize(line.attributed, width: 1000)
        for width in [120, 150, 170, 190] as [CGFloat] {
            let used = CSSTextNSView.usedSize(line.attributed, width: width)
            let storage = NSTextStorage(attributedString: line.attributed)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: width, height: 1000))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
            #expect(lines >= 2)
            #expect(abs(used.height - CGFloat(lines) * one.height) < 0.5)
            #expect(used.width <= width)
        }
        // The width it asks for keeps it on the lines it was measured with: at the used width alone TextKit wraps it.
        let short = CSSText(
            runs: [.init(text: "+", semibold: true, color: .green), .init(text: "Same movement as Percorso", color: .black)],
            lineHeight: GistCardStyle.pointLineHeight, hanging: true)
        let fit = short.fitSize(proposedWidth: 190)
        #expect(abs(fit.height - CSSTextNSView.usedSize(short.attributed, width: 1000).height) < 1)
        #expect(CSSTextNSView.usedSize(short.attributed, width: fit.width).height <= fit.height)
    }

    @Test func codeInAPointIsAChip() {
        let runs = CSSText.inlineRuns("A fail means `v0.4.1` here", color: .black)
        #expect(runs.map(\.text) == ["A fail means ", "v0.4.1", " here"])
        #expect(runs.map(\.code) == [false, true, false])
        #expect(CSSText.inlineRuns("an `unclosed tick", color: .black).map(\.text) == ["an `unclosed tick"])
        let attributed = CSSText(runs: runs).attributed
        let at = (attributed.string as NSString).range(of: "v0.4.1").location
        #expect(attributed.attribute(.waggleChip, at: at, effectiveRange: nil) as? Int == TextChipKind.code.rawValue)
    }

    // MARK: - Need: paths, code, numbers

    @Test func pathsAreFoundAndLinksAreNot() {
        #expect(InlinePaths.isPath("~/.bench/cache/run-1108/summary.md"))
        #expect(InlinePaths.isPath("docs/menu.md"))
        #expect(InlinePaths.isPath("design/mockups/2026-11-08-recipe-cards/"))
        #expect(!InlinePaths.isPath("and/or"))
        #expect(!InlinePaths.isPath("4/5"))
        #expect(!InlinePaths.isPath("https://example.com/a/b"))
        let text = "See docs/menu.md, and/or the list."
        #expect(InlinePaths.ranges(in: text).map { String(text[$0]) } == ["docs/menu.md"])
        let path = "~/.bench/summary.md"
        #expect(String(path[InlinePaths.fileStart(in: path)...]) == "summary.md")
    }

    @Test func keyNumbersAreFoundAndNumbersInWordsAreNot() {
        let text = "Cache B beat A in 4 of 5 cycles, with 5 wrong claims against 11. Spent USD 18.40, about 40% in v0.4 at run-1108."
        let found = NeedNumbers.ranges(in: text).map { String(text[$0]) }
        #expect(found == ["4 of 5", "5", "11", "USD 18.40", "40%"])
    }

    @Test func theNeedDrawsCodeAndPathsAsChipsAndNumbersBold() {
        FontRegistration.registerBundledFonts()
        var face = AskTextFace(style: Theme.AskDoc.Column.need, color: Theme.Colors.ink)
        face.numberColor = NSColor(Theme.Colors.ink)
        let content = AskTextContent.build(
            text: "Spent USD 18.40 on `--max-turns 15` and `~/.bench/summary.md`.", mode: .blocks, face: face, book: nil, showsPills: false)
        let string = content.attributed.string as NSString
        func chip(_ word: String) -> Int? {
            content.attributed.attribute(.waggleChip, at: string.range(of: word).location, effectiveRange: nil) as? Int
        }
        #expect(chip("--max") == TextChipKind.code.rawValue)
        #expect(chip("summary.md") == TextChipKind.path.rawValue)
        let font = content.attributed.attribute(.font, at: string.range(of: "18.40").location, effectiveRange: nil) as? NSFont
        #expect(font?.fontName.contains("SemiBold") == true)
        // The plain text an anchor counts in is unchanged.
        #expect(content.plain == "Spent USD 18.40 on --max-turns 15 and ~/.bench/summary.md.")
    }
}
