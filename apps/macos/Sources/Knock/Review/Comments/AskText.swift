import AppKit
import SwiftUI

/// WAG-357: a comment on the text of a request. This file holds the pure parts: which text a view shows, the plain
/// text an anchor counts in, and the map between the two. No view code here, so a test can check it.

/// Where a commentable text sits on the request page: the part, and the ids that name it. `key` tells two views of
/// one part apart (the pro lines of an option, the card and the list row of one source).
struct AskCommentTarget: Equatable, Sendable {
    var part: AskTextPart
    var itemId: String?
    var optionId: String?
    var sourceId: String?
    /// The text view's own identity. The card and the list row of one source share the target but not the key.
    var slot = ""
    /// Where this view's text starts inside the part's plain text. A source shows its label, excerpt and note in
    /// three views; each one starts after the one before.
    var baseOffset = 0

    init(_ part: AskTextPart, itemId: String? = nil, optionId: String? = nil, sourceId: String? = nil, slot: String = "", baseOffset: Int = 0) {
        self.part = part
        self.itemId = itemId
        self.optionId = optionId
        self.sourceId = sourceId
        self.slot = slot
        self.baseOffset = baseOffset
    }

    var key: String {
        [part.rawValue, itemId ?? "", optionId ?? "", sourceId ?? "", slot].joined(separator: "|")
    }

    /// True when `anchor` is on the same part of the request as this target.
    func owns(_ anchor: AskTextAnchor) -> Bool {
        anchor.part == part && anchor.itemId == itemId && anchor.optionId == optionId && anchor.sourceId == sourceId
    }

    func anchor(quote: String, start: Int, end: Int) -> AskTextAnchor {
        AskTextAnchor(
            part: part, itemId: itemId, optionId: optionId, sourceId: sourceId, quote: quote,
            start: baseOffset + start, end: baseOffset + end)
    }
}

extension AskTextPart {
    /// The part in plain words: "New note on the title", and the same words in the Comments list.
    var words: String {
        switch self {
        case .title: "the title"
        case .need: "what I need"
        case .why: "the why"
        case .question: "the question"
        case .recommendation: "the recommendation"
        case .pro: "a pro"
        case .con: "a con"
        case .effect: "an effect"
        case .source: "a source"
        }
    }

    /// The label of a saved comment: "On the title".
    var onWords: String { "On " + words }
}

/// How a commentable text looks. The values come from the theme text styles.
struct AskTextFace: Equatable {
    var size: CGFloat
    var weight: NSFont.Weight = .regular
    var lineHeight: CGFloat?
    var tracking: CGFloat?
    var color: NSColor
    /// The mono face, for a quoted line of code.
    var mono = false

    init(style: Theme.TextStyle, weight: NSFont.Weight = .regular, color: Color) {
        self.size = style.size
        self.weight = weight
        self.lineHeight = style.lineHeight
        self.tracking = style.letterSpacing
        self.color = NSColor(color)
    }

    var lineSpacing: CGFloat { lineHeight.map { size * ($0 - 1) } ?? 0 }
}

/// A pill's place in a text: a marker became this attachment.
final class AskPillAttachment: NSTextAttachment {
    var ids: [String] = []

    /// Two rebuilds of the same text hold two attachment objects. They are the same content (WAG-365), so the
    /// view does not take an equal rebuild for new text and does not throw its measures away.
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? AskPillAttachment else { return false }
        return other === self || other.ids == ids
    }

    override var hash: Int { ids.hashValue }
}

/// The text of one commentable view, laid out: the attributed string (a source marker is one attachment
/// character), the plain text an anchor counts in, and the map between them.
struct AskTextContent: Equatable {
    /// `line`: one flat line (marks and list prefixes gone). `blocks`: paragraphs and lists. `raw`: the text as it is,
    /// line breaks kept (a source excerpt).
    enum Mode: Equatable { case line, blocks, raw }

    let attributed: NSAttributedString
    /// The text as shown, markdown marks and source markers removed. Anchors count in UTF-16 units of this string.
    let plain: String
    /// Per UTF-16 unit of `attributed`: its place in `plain`, or -1 for what Waggle added (a bullet, a prefix, a pill).
    let plainIndex: [Int]
    /// The attachments, by their place in `attributed`.
    let pills: [(index: Int, ids: [String])]

    static func == (lhs: AskTextContent, rhs: AskTextContent) -> Bool {
        lhs.plain == rhs.plain && lhs.plainIndex == rhs.plainIndex && lhs.attributed.isEqual(to: rhs.attributed)
            && lhs.pills.map(\.index) == rhs.pills.map(\.index) && lhs.pills.map(\.ids) == rhs.pills.map(\.ids)
    }

    var plainLength: Int { plain.utf16.count }

    // MARK: Mapping

    private static func isSpace(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 }

    /// The plain range a selection of the attributed string covers, edge spaces left out. `nil` when it holds no
    /// plain text (only a pill or a bullet).
    func plainRange(forRendered range: Range<Int>) -> Range<Int>? {
        let clamped = max(0, range.lowerBound)..<min(plainIndex.count, range.upperBound)
        guard clamped.lowerBound < clamped.upperBound else { return nil }
        let units = Array(plain.utf16)
        var first: Int?
        var last: Int?
        for i in clamped where plainIndex[i] >= 0 && !Self.isSpace(units[plainIndex[i]]) {
            if first == nil { first = i }
            last = i
        }
        guard let first, let last else { return nil }
        return plainIndex[first]..<(plainIndex[last] + 1)
    }

    /// The attributed range a plain range lands on: from its first shown unit to its last.
    func renderedRange(forPlain range: Range<Int>) -> Range<Int>? {
        var first: Int?
        var last: Int?
        for i in 0..<plainIndex.count where plainIndex[i] >= range.lowerBound && plainIndex[i] < range.upperBound {
            if first == nil { first = i }
            last = i
        }
        guard let first, let last else { return nil }
        return first..<(last + 1)
    }

    func quote(forPlain range: Range<Int>) -> String {
        let units = Array(plain.utf16)
        let r = max(0, range.lowerBound)..<min(units.count, range.upperBound)
        guard r.lowerBound < r.upperBound else { return "" }
        return String(decoding: units[r], as: UTF16.self)
    }

    // MARK: Building

    /// The content of `text` (agent markdown with `[[s:id]]` markers).
    /// - Parameters:
    ///   - book: when it names the sources of the round and `showsPills`, the markers become pill attachments.
    ///     Otherwise they are gone.
    ///   - prefix: a bold lead-in Waggle writes ("Why you:"). It shows, but it is not part of the plain text.
    static func build(
        text: String, mode: Mode, face: AskTextFace, book: SourceBook?, showsPills: Bool, prefix: String? = nil
    ) -> AskTextContent {
        var builder = Builder(face: face)
        if let prefix {
            builder.append(prefix + " ", font: Builder.font(face, bold: true), plain: false)
        }
        let usesPills = showsPills && book != nil && !book!.isEmpty && text.contains("[[s:")
        switch mode {
        case .line:
            builder.appendLine(text, book: usesPills ? book : nil)
        case .raw:
            builder.append(text, font: Builder.font(face), plain: true)
        case .blocks:
            builder.appendBlocks(AgentMarkdown.blocks(text, keepingSources: usesPills), book: usesPills ? book : nil)
        }
        return builder.result()
    }

    /// How many UTF-16 units of plain text `text` has in `mode`. Offsets of one part that shows in several views count with it.
    static func plainLength(of text: String, mode: Mode) -> Int {
        let face = AskTextFace(style: Theme.AskDoc.Typography.optionCard13, color: .black)
        return build(text: text, mode: mode, face: face, book: nil, showsPills: false).plainLength
    }

    /// The start of each line in a part made of several lines (the pros of an option), counting one break between lines.
    static func lineBases(_ lines: [String]) -> [Int] {
        var bases: [Int] = []
        var next = 0
        for line in lines {
            bases.append(next)
            next += plainLength(of: line, mode: .line) + 1
        }
        return bases
    }

    /// The baseline of the first line, from the top of the text, for text that sits beside a bullet.
    static func firstBaseline(of attributed: NSAttributedString) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let fragment = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return fragment.minY + layout.location(forGlyphAt: 0).y
    }

    private struct Builder {
        let face: AskTextFace
        let out = NSMutableAttributedString()
        var plainText = ""
        var plainIndex: [Int] = []
        var pills: [(index: Int, ids: [String])] = []
        var plainCount = 0

        init(face: AskTextFace) { self.face = face }

        static func font(_ face: AskTextFace, bold: Bool = false, italic: Bool = false, code: Bool = false) -> NSFont {
            if code || face.mono {
                let size = face.mono ? face.size : max(face.size - 1, 10)
                if FontRegistration.didRegisterBundledFonts, let mono = NSFont(name: Theme.FontFamily.mono, size: size) { return mono }
                return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            var font = PromptBarLogic.sansFont(size: face.size, weight: bold ? .semibold : face.weight)
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            return font
        }

        func attributes(font: NSFont, paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: face.color, .paragraphStyle: paragraph]
            if let tracking = face.tracking { attrs[.kern] = tracking }
            return attrs
        }

        /// Adds text that Waggle wrote, or plain text that the person can comment on.
        mutating func append(_ string: String, font: NSFont, plain: Bool, background: NSColor? = nil, style: NSParagraphStyle? = nil) {
            var attrs = attributes(font: font, paragraph: style ?? baseParagraph())
            if let background { attrs[.backgroundColor] = background }
            out.append(NSAttributedString(string: string, attributes: attrs))
            for unit in string.utf16 {
                _ = unit
                if plain {
                    plainIndex.append(plainCount)
                    plainCount += 1
                } else {
                    plainIndex.append(-1)
                }
            }
            if plain { plainText += string }
        }

        func baseParagraph(spacing: CGFloat = 0, headIndent: CGFloat = 0, firstLine: CGFloat = 0) -> NSMutableParagraphStyle {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = face.lineSpacing
            para.paragraphSpacing = spacing
            para.headIndent = headIndent
            para.firstLineHeadIndent = firstLine
            return para
        }

        mutating func appendLine(_ text: String, book: SourceBook?) {
            let parsed = book.flatMap { $0.parsedWithPills(text) }
            let flat = AgentMarkdown.singleLine(parsed?.text ?? text)
            appendInline(flat, groups: parsed?.groups ?? [], book: book, style: baseParagraph())
        }

        mutating func appendBlocks(_ blocks: [AgentMarkdownBlock], book: SourceBook?) {
            for (index, block) in blocks.enumerated() {
                // The space after a block belongs to its paragraph style. Items of one list sit closer together.
                let spacing = index + 1 < blocks.count ? blockGap(block, blocks[index + 1]) : 0
                let style: NSMutableParagraphStyle
                var bold = false
                var marker: String?
                var level = 0
                var body = ""
                switch block {
                case .paragraph(let t): body = t
                case .heading(let t): body = t; bold = true
                case .bullet(let l, let t): body = t; marker = "•"; level = l
                case .numbered(let l, let n, let t): body = t; marker = "\(n)."; level = l
                }
                if marker != nil {
                    let indent: CGFloat = level == 0 ? 6 : 24
                    style = baseParagraph(spacing: spacing, headIndent: indent + 20, firstLine: indent)
                    style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 20)]
                } else {
                    style = baseParagraph(spacing: spacing)
                }
                if let marker {
                    append(marker + "\t", font: Self.font(face), plain: false, style: style)
                    recolorLast(marker.count + 1, color: NSColor(Theme.Colors.ink3))
                }
                let parsed = book.flatMap { $0.parsedWithPills(body) }
                appendInline(parsed?.text ?? body, groups: parsed?.groups ?? [], book: book, style: style, bold: bold)
                if index + 1 < blocks.count {
                    // The break between two blocks is part of the plain text, so a quote can span them.
                    append("\n", font: Self.font(face), plain: true, style: style)
                }
            }
        }

        /// Items of one list sit closer together than paragraphs do (8, and 5 inside a list).
        private func blockGap(_ previous: AgentMarkdownBlock, _ block: AgentMarkdownBlock) -> CGFloat {
            switch (previous, block) {
            case (.bullet, .bullet), (.numbered, .numbered), (.bullet, .numbered), (.numbered, .bullet): 5
            default: 8
            }
        }

        private mutating func recolorLast(_ count: Int, color: NSColor) {
            let range = NSRange(location: out.length - count, length: count)
            out.addAttribute(.foregroundColor, value: color, range: range)
        }

        /// The inline runs of a text that may hold placeholders: bold, italic and code as fonts, a placeholder as a
        /// pill attachment.
        mutating func appendInline(_ text: String, groups: [[String]], book: SourceBook?, style: NSParagraphStyle, bold: Bool = false) {
            let inline = AgentMarkdown.inline(text)
            var groupIndex = 0
            for run in inline.runs {
                let intent = run.inlinePresentationIntent ?? []
                let isCode = intent.contains(.code)
                let font = Self.font(
                    face, bold: bold || intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized), code: isCode)
                let piece = String(inline[run.range].characters)
                var chunk = ""
                func flush() {
                    guard !chunk.isEmpty else { return }
                    append(chunk, font: font, plain: true, background: isCode ? NSColor(Theme.Colors.side) : nil, style: style)
                    chunk = ""
                }
                for character in piece {
                    if character == SourceMarkers.placeholder {
                        flush()
                        defer { groupIndex += 1 }
                        guard groupIndex < groups.count, book?.pill(ids: groups[groupIndex]) != nil else { continue }
                        let attachment = AskPillAttachment()
                        attachment.ids = groups[groupIndex]
                        let string = NSMutableAttributedString(attachment: attachment)
                        string.addAttributes(attributes(font: font, paragraph: style), range: NSRange(location: 0, length: string.length))
                        pills.append((out.length, groups[groupIndex]))
                        out.append(string)
                        plainIndex.append(-1)
                    } else {
                        chunk.append(character)
                    }
                }
                flush()
            }
        }

        func result() -> AskTextContent {
            AskTextContent(attributed: NSAttributedString(attributedString: out), plain: plainText, plainIndex: plainIndex, pills: pills)
        }
    }
}

/// The rule for the Comment button: it shows only when exactly one part has a selection.
enum AskSelectionRule {
    struct PartSelection: Equatable {
        let key: String
        let hasSelection: Bool
    }

    /// The key of the one part that holds a selection, or `nil` when none does or when a selection crosses two parts.
    static func single(_ selections: [PartSelection]) -> String? {
        let active = selections.filter(\.hasSelection)
        return active.count == 1 ? active[0].key : nil
    }
}
