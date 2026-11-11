import AppKit
import SwiftUI

/// The rules of the option card "Gist and facts" (decision 2026-11-10-option-card-gist-and-facts, mockup
/// `design/mockups/2026-11-10-option-text/` variant `gist`), as plain functions a test can check without a view.
enum OptionGist {
    /// At most this many fact chips under a title (`.fx`). More (a newer daemon may send them) show in the full points.
    static let maxFacts = 3
    static let showFull = "Show the full points"
    static let hideFull = "Hide the full points"
    static let prosLabel = "Pros"
    static let consLabel = "Cons"

    static func shownFacts(_ facts: [String]) -> [String] { Array(facts.prefix(maxFacts)) }
    static func extraFacts(_ facts: [String]) -> [String] { Array(facts.dropFirst(maxFacts)) }

    /// A fact that reads as a path or a piece of code draws in the mono face (`.mono`); the rest in Inter Tight.
    static func isCodeLike(_ fact: String) -> Bool {
        fact.contains("`") || InlinePaths.isPath(fact) || fact.hasPrefix("--")
    }

    /// "+3 –3" at the right of a closed card (`.tally`): the number of pros and of cons. A side with none is left out.
    struct Tally: Equatable {
        let pros: Int
        let cons: Int

        var spoken: String {
            [pros > 0 ? "\(pros) \(pros == 1 ? "pro" : "pros")" : nil, cons > 0 ? "\(cons) \(cons == 1 ? "con" : "cons")" : nil]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }

    static func tally(pros: [OptionPoint], cons: [OptionPoint]) -> Tally? {
        pros.isEmpty && cons.isEmpty ? nil : Tally(pros: pros.count, cons: cons.count)
    }

    /// The text a closed card shows when its option has no facts (an older agent): the first words of its first pro
    /// and first con, each cut at a whole word with "…" to share `width`. A gist shows as it is when it fits.
    struct Teaser: Equatable {
        var pro: String?
        var con: String?
    }

    static func closedTeaser(
        pro: OptionPoint?, con: OptionPoint?, width: CGFloat, gap: CGFloat, measure: (String) -> CGFloat
    ) -> Teaser {
        let proText = pro.map { AgentMarkdown.singleLine($0.shown) }
        let conText = con.map { AgentMarkdown.singleLine($0.shown) }
        switch (proText, conText) {
        case (nil, nil): return Teaser()
        case (let one?, nil): return Teaser(pro: cutAtWord(one, fits: { measure($0) <= width }).text)
        case (nil, let one?): return Teaser(con: cutAtWord(one, fits: { measure($0) <= width }).text)
        case (let p?, let c?):
            let half = max(0, (width - gap) / 2)
            // A short side gives its spare room to the other.
            let pw = measure(p), cw = measure(c)
            let proRoom = cw < half ? width - gap - cw : (pw < half ? pw : half)
            let conRoom = width - gap - min(pw, proRoom)
            return Teaser(
                pro: cutAtWord(p, fits: { measure($0) <= proRoom }).text,
                con: cutAtWord(c, fits: { measure($0) <= conRoom }).text)
        }
    }

    /// Cuts `text` at a whole word, with "…", to the longest head that `fits`. Never inside a word: when not even the
    /// first word fits, that word shows whole and the frame clips it. `isCut` is false when the whole text fits.
    static func cutAtWord(_ text: String, fits: (String) -> Bool) -> (text: String, isCut: Bool) {
        if fits(text) { return (text, false) }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else { return (text, false) }
        func head(_ n: Int) -> String {
            words.prefix(n).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-–—")) + "…"
        }
        // `fits` grows with the text, so the longest head that fits is a binary search.
        var low = 1, high = words.count - 1, best = 1
        while low <= high {
            let mid = (low + high) / 2
            if fits(head(mid)) { best = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return (head(best), true)
    }

    /// True when "Show the full points" has more to show than the card: a gist that is not its point, effects, a fact
    /// past the third, or a description or reason the one line cut.
    static func hasHiddenDetail(
        pros: [OptionPoint], cons: [OptionPoint], effects: [String], facts: [String], descriptionCut: Bool, reasonCut: Bool
    ) -> Bool {
        (pros + cons).contains(where: \.hasMore) || !effects.isEmpty || facts.count > maxFacts || descriptionCut || reasonCut
    }

    /// The spoken label of a point: its full text, never the gist alone.
    static func spokenPoint(_ point: OptionPoint, word: String) -> String {
        let detail = AgentMarkdown.singleLine(point.detail)
        guard let gist = point.gist, point.hasMore else { return "\(word): \(detail)" }
        return "\(word): \(AgentMarkdown.singleLine(gist)). \(detail)"
    }

    /// The hanging indent of a + / – line (`.hl li`: a 11 pt column for the sign, centred, then 6 pt, then the text).
    /// A wrapped line starts under the text, never under the sign.
    enum Hanging {
        static let markColumn: CGFloat = 11
        static let gap: CGFloat = 6
        static var textInset: CGFloat { markColumn + gap }

        /// Where the sign starts so it sits in the middle of its column.
        static func markOffset(markWidth: CGFloat) -> CGFloat { max(0, (markColumn - markWidth) / 2) }
    }
}

/// The card sizes of variant `gist` (1 CSS px = 1 pt).
enum GistCardStyle {
    /// `.fact`: 500 11/1, padding 4 / 6, radius 5, ink2 on side, tabular digits.
    static let factSize: CGFloat = 11
    static let factPadding = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
    static let factRadius: CGFloat = 5
    /// `.fx` gap 5.
    static let factGap: CGFloat = 5
    /// `.cl`: padding 0 12 9 38, gap 8.
    static let closedGap: CGFloat = 8
    /// `.tally`: 500 11.5/1, gap 8.
    static let tallySize: CGFloat = 11.5
    static let tallyGap: CGFloat = 8
    /// `.x .d`: margin 8 0 9, line height 1.5.
    static let descriptionTop: CGFloat = 8
    static let descriptionBottom: CGFloat = 9
    static let descriptionLineHeight: CGFloat = 1.5
    /// `.pcg`: 2 columns, gap 14, padding-top 2; `h4` 600 10.5/1 .06em, 6 under it; `.hl` gap 4, `li` line height 1.35.
    static let columnGap: CGFloat = 14
    static let gridTop: CGFloat = 2
    /// The steps frame puts the grid 10 under the chips when there is no description (`style="margin-top:10px"`).
    static let gridAfterFacts: CGFloat = 10
    static let headLabelGap: CGFloat = 6
    static let pointGap: CGFloat = 4
    static let pointLineHeight: CGFloat = 1.35
    /// `.x .because`: margin-top 9, then the dashed line and 6 padding.
    static let becauseTop: CGFloat = 9
    /// `.x .foot`: margin-top 7.
    static let footTop: CGFloat = 7
}

// MARK: - Paths, code and numbers in running text

/// A piece of running text drawn as a chip (mockup `code` and `.path`): the text keeps its place, the chip is drawn
/// behind it.
enum TextChipKind: Int {
    /// `code`: mono 11.5, ink, side fill, 1 pt `line` border, radius 4, padding 0 / 4.
    case code
    /// `.path`: mono 11, white fill, 1 pt `line2` border, radius 5, padding 2 / 7 / 2 / 5; the folders quiet, the file ink.
    case path

    var fill: NSColor { self == .code ? NSColor(Theme.Colors.side) : NSColor(Theme.Colors.win) }
    var stroke: NSColor { self == .code ? NSColor(Theme.Colors.line) : NSColor(Theme.Colors.line2) }
    var radius: CGFloat { self == .code ? 4 : 5 }
    var padLeft: CGFloat { self == .code ? 4 : 5 }
    var padRight: CGFloat { self == .code ? 4 : 7 }
    var padVertical: CGFloat { self == .code ? 0 : 2 }
    var fontSize: CGFloat { self == .code ? 11.5 : 11 }

    static func monoFont(_ size: CGFloat) -> NSFont {
        if FontRegistration.didRegisterBundledFonts, let mono = NSFont(name: Theme.FontFamily.mono, size: size) { return mono }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension NSAttributedString.Key {
    /// A `TextChipKind` raw value: `ChipPainter` draws the chip behind these characters.
    static let waggleChip = NSAttributedString.Key("waggleChip")
}

/// Paths in running text (mockup `.path`): `~/.bench/run/summary.md`, `design/mockups/index.html`, `./a/b`.
enum InlinePaths {
    /// A word that reads as a file path: it starts at the home folder, the root or a dot folder, or has two slashes, or
    /// ends in a file name with an extension. "and/or", "4/5" and web links are not paths.
    static func isPath(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard w.contains("/"), !w.contains("://"), !w.contains(" "), w.count > 2 else { return false }
        if w.hasPrefix("~/") || w.hasPrefix("./") || w.hasPrefix("../") || (w.hasPrefix("/") && w.count > 1) { return true }
        if w.filter({ $0 == "/" }).count >= 2 { return true }
        guard let last = w.split(separator: "/").last, let dot = last.lastIndex(of: ".") else { return false }
        let ext = last[last.index(after: dot)...]
        return (1...5).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber } && ext.contains(where: \.isLetter)
    }

    /// The ranges of the path words in `text`, trailing punctuation left out.
    static func ranges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index? = nil
        func close(_ end: String.Index) {
            guard let s = start else { return }
            var e = end
            while e > s, ",.;:)!?\"'".contains(text[text.index(before: e)]) { e = text.index(before: e) }
            var b = s
            while b < e, "(\"'".contains(text[b]) { b = text.index(after: b) }
            if b < e, isPath(String(text[b..<e])) { out.append(b..<e) }
            start = nil
        }
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace { close(i) } else if start == nil { start = i }
            i = text.index(after: i)
        }
        close(text.endIndex)
        return out
    }

    /// Where the file name starts in a path: after its last slash (a path that ends in "/" is all folders).
    static func fileStart(in path: String) -> String.Index {
        guard let slash = path.lastIndex(of: "/") else { return path.startIndex }
        return path.index(after: slash)
    }
}

/// The key numbers of the need (mockup `.num`: 600, ink, tabular digits): an amount with its currency, "4 of 5", a
/// count, a percent or a size with its unit. A number inside a word ("v0.4", "run-1108") is not one.
enum NeedNumbers {
    private static let pattern: NSRegularExpression = {
        let currency = #"(?:(?:USD|EUR|GBP|CHF|US\$|\$|€|£)\s?)"#
        let number = #"\d+(?:[.,]\d+)*"#
        let unit = #"(?:\s?(?:%|pt|px|ms|s|min|h|KB|MB|GB|TB|k|K|x|×)(?![\p{L}\d]))?"#
        let of = #"(?:\s(?:of|out of|in)\s\d+(?:[.,]\d+)*(?![\p{L}\d]))?"#
        let expression = #"(?<![\p{L}\d_\-./#@])"# + currency + "?" + number + "(?:" + unit + of + ")" + #"(?![\p{L}\d_\-/])"#
        return try! NSRegularExpression(pattern: expression)
    }()

    static func ranges(in text: String) -> [Range<String.Index>] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            var end = range.upperBound
            // "11." at the end of a sentence: the dot is not part of the number.
            while end > range.lowerBound, ".,".contains(text[text.index(before: end)]) { end = text.index(before: end) }
            return range.lowerBound..<end
        }
    }

    /// The same face with tabular (monospaced) digits.
    static func tabular(_ font: NSFont) -> NSFont {
        let settings: [[NSFontDescriptor.FeatureKey: Int]] = [[
            .typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector,
        ]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}

/// Draws the chips of `TextChipKind` behind their characters, from a laid-out text.
enum ChipPainter {
    static func paint(layout: NSLayoutManager, container: NSTextContainer, origin: NSPoint, glyphRange: NSRange? = nil) {
        guard let storage = layout.textStorage, storage.length > 0 else { return }
        let glyphs = glyphRange ?? layout.glyphRange(for: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.waggleChip, in: chars) { value, range, _ in
            guard let raw = value as? Int, let kind = TextChipKind(rawValue: raw) else { return }
            let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? TextChipKind.monoFont(kind.fontSize)
            layout.enumerateEnclosingRects(
                forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                let probe = layout.glyphIndex(for: CGPoint(x: rect.midX, y: rect.midY), in: container)
                let line = layout.lineFragmentRect(forGlyphAt: probe, effectiveRange: nil)
                let baseline = line.minY + layout.location(forGlyphAt: probe).y
                let top = baseline - font.ascender - kind.padVertical - 1
                let height = font.ascender - font.descender + 2 * kind.padVertical + 2
                let box = NSRect(
                    x: origin.x + rect.minX - kind.padLeft, y: origin.y + top,
                    width: rect.width + kind.padLeft, height: height)
                let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: kind.radius, yRadius: kind.radius)
                kind.fill.setFill()
                path.fill()
                kind.stroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    /// Marks `range` of `text` as a chip of `kind`: the mono face, the colors, and the room for its padding (kern on
    /// the character before it and on its last character).
    static func mark(_ text: NSMutableAttributedString, range: NSRange, kind: TextChipKind, ink: NSColor, quiet: NSColor) {
        guard range.length > 0 else { return }
        text.addAttribute(.waggleChip, value: kind.rawValue, range: range)
        text.addAttribute(.font, value: TextChipKind.monoFont(kind.fontSize), range: range)
        text.addAttribute(.foregroundColor, value: ink, range: range)
        text.removeAttribute(.backgroundColor, range: range)
        if kind == .path {
            let string = (text.string as NSString).substring(with: range)
            let fileStart = string.distance(from: string.startIndex, to: InlinePaths.fileStart(in: string))
            let folders = (String(string.prefix(fileStart)) as NSString).length
            if folders > 0 { text.addAttribute(.foregroundColor, value: quiet, range: NSRange(location: range.location, length: folders)) }
        }
        if range.location > 0 {
            let before = (text.string as NSString).character(at: range.location - 1)
            if before != 10 { text.addAttribute(.kern, value: kind.padLeft + 1, range: NSRange(location: range.location - 1, length: 1)) }
        }
        text.addAttribute(.kern, value: kind.padRight + 1, range: NSRange(location: range.location + range.length - 1, length: 1))
    }
}

/// A layout manager that draws the text chips behind the glyphs (the commentable request text).
final class ChipLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let container = textContainers.first {
            ChipPainter.paint(layout: self, container: container, origin: origin, glyphRange: glyphsToShow)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

extension OptionGist {
    /// Agent text on one line for the card: source markers gone, line breaks and bold marks dropped, code spans kept
    /// (they draw as chips).
    static func flatLine(_ text: String) -> String {
        let stripped = SourceMarkers.strip(text).replacingOccurrences(of: "**", with: "")
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Text the card can draw as plain text with code chips: one paragraph, no other markdown, no source markers.
    static func isFlatLine(_ text: String) -> Bool {
        !text.contains("\n") && !text.contains("[[s:") && !text.contains("**") && !text.contains("](")
    }
}

// MARK: - Views

/// `.fx` of `.fact` chips: one neutral style, wrapped 5 apart.
struct FactChips: View {
    let facts: [String]

    var body: some View {
        ChipFlowLayout(spacing: GistCardStyle.factGap) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in FactChip(text: fact) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Facts: " + facts.map { $0.replacingOccurrences(of: "`", with: "") }.joined(separator: ", "))
    }
}

/// `.fact`: 500 11/1 Inter Tight in ink2 on side, radius 5, padding 4 / 6, tabular digits. A path or code reads in mono.
struct FactChip: View {
    let text: String

    var body: some View {
        let mono = OptionGist.isCodeLike(text)
        Text(text.replacingOccurrences(of: "`", with: ""))
            .font(mono ? Theme.AskDoc.Column.font(GistCardStyle.factSize, mono: true) : OptionCardStyle.sans(GistCardStyle.factSize, .medium))
            .monospacedDigit()
            .foregroundColor(Theme.Colors.ink2)
            .lineLimit(1)
            .fixedSize()
            .cssLine(size: GistCardStyle.factSize, lineHeight: 1, mono: mono)
            .padding(GistCardStyle.factPadding)
            .background(Theme.Colors.side)
            .clipShape(RoundedRectangle(cornerRadius: GistCardStyle.factRadius))
    }
}

/// `.tally`: "+3 –3", 500 11.5/1, the signs in pro and watch, the numbers quiet.
struct TallyView: View {
    let tally: OptionGist.Tally

    private static var font: Font { OptionCardStyle.sans(GistCardStyle.tallySize, .medium) }

    /// The width it takes, for the closed card's cut.
    static func width(_ tally: OptionGist.Tally) -> CGFloat {
        let font = NeedNumbers.tabular(PromptBarLogic.sansFont(size: GistCardStyle.tallySize, weight: .medium))
        let parts = [tally.pros > 0 ? "+\(tally.pros)" : nil, tally.cons > 0 ? "–\(tally.cons)" : nil].compactMap { $0 }
        let widths = parts.map { ceil(NSAttributedString(string: $0, attributes: [.font: font]).size().width) }
        return widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * GistCardStyle.tallyGap
    }

    var body: some View {
        HStack(spacing: GistCardStyle.tallyGap) {
            if tally.pros > 0 {
                (Text("+").foregroundColor(Theme.AskDoc.Colors.pro) + Text("\(tally.pros)").foregroundColor(Theme.AskDoc.Colors.quiet))
            }
            if tally.cons > 0 {
                (Text("–").foregroundColor(Theme.AskDoc.Colors.watch) + Text("\(tally.cons)").foregroundColor(Theme.AskDoc.Colors.quiet))
            }
        }
        .font(Self.font)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .cssLine(size: GistCardStyle.tallySize, lineHeight: 1)
        .help(tally.spoken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tally.spoken)
    }
}

/// `.pcg h4`: 600 10.5/1, .06 em, upper case, quiet.
struct GistHeadLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .knockTextStyle(OptionCardStyle.label)
            .foregroundColor(Theme.AskDoc.Colors.quiet)
            .lineLimit(1)
            .cssLine(size: 10.5, lineHeight: 1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// `.hl li`: the sign centred in its 11 pt column, the text 6 pt after it; a wrapped line starts under the text.
struct HangingLine: View {
    let mark: String
    let color: Color
    let text: String
    var lineHeight: CGFloat = GistCardStyle.pointLineHeight

    var body: some View {
        CSSText(
            runs: [.init(text: mark, semibold: true, color: color)] + CSSText.inlineRuns(OptionGist.flatLine(text), color: Theme.Colors.ink),
            lineHeight: lineHeight, hanging: true)
        .accessibilityElement(children: .ignore)
    }
}
