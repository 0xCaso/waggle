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
    /// The space between two paragraphs (`AskParagraphGapKey`): 8 by default, 7 in the need box (`.need p`).
    var paragraphGap: CGFloat = AskTextFace.defaultParagraphGap
    /// The need box (task 11c, mockup `.num`): key numbers in 600 with tabular digits, in this color. `nil` elsewhere.
    var numberColor: NSColor? = nil

    static let defaultParagraphGap: CGFloat = 8

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
    ///   - prefix: a lead-in Waggle writes ("Why you:"), in the text's own weight (the mockup's `.need .why`). It
    ///     shows, but it is not part of the plain text.
    static func build(
        text: String, mode: Mode, face: AskTextFace, book: SourceBook?, showsPills: Bool, prefix: String? = nil
    ) -> AskTextContent {
        var builder = Builder(face: face)
        if let prefix {
            builder.append(prefix + " ", font: Builder.font(face), plain: false)
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
        var face: AskTextFace
        let out = NSMutableAttributedString()
        var plainText = ""
        var plainIndex: [Int] = []
        var pills: [(index: Int, ids: [String])] = []
        var plainCount = 0
        /// The gap a table leaves for the block after it: a text table ignores its own bottom margin.
        var spaceBeforeNext: CGFloat = 0

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
                if case .table(let headers, let rows) = block {
                    appendTable(headers: headers, rows: rows, book: book, isLast: index + 1 == blocks.count)
                    spaceBeforeNext = spacing
                    continue
                }
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
                case .table: break
                }
                if marker != nil {
                    let indent: CGFloat = level == 0 ? 6 : 24
                    style = baseParagraph(spacing: spacing, headIndent: indent + 20, firstLine: indent)
                    style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 20)]
                } else {
                    style = baseParagraph(spacing: spacing)
                }
                style.paragraphSpacingBefore = spaceBeforeNext
                spaceBeforeNext = 0
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

        /// A pipe table as an AppKit text table, as mockup B's `table.t` at the case map's sizes: the full width, one
        /// line around it with 10 pt corners (`AskTableCellBlock`), the header row on the side fill in 600 ink, a line
        /// over each body row, cells 12 pt in ink2 with 7/10 padding, number columns right-aligned and unwrapped, a
        /// muted cell ("—") in the quiet grey. Each cell ends with a break that is part of the plain text, so a quote
        /// can span cells.
        private mutating func appendTable(headers: [String], rows: [[String]], book: SourceBook?, isLast: Bool) {
            let column = Theme.AskDoc.Column.self
            let table = NSTextTable()
            table.numberOfColumns = max(headers.count, 1)
            table.collapsesBorders = false
            table.layoutAlgorithm = .automaticLayoutAlgorithm
            table.setContentWidth(100, type: .percentageValueType)
            let all = [headers] + rows
            let numeric = AskTableRules.numericColumns(headers: headers, rows: rows)
            var cellFace = face
            cellFace.size = column.tableText.size
            cellFace.lineHeight = column.tableText.lineHeight
            cellFace.tracking = nil
            let padding = column.tableCellPadding
            for (r, cells) in all.enumerated() {
                for (c, cell) in cells.enumerated() {
                    let block = AskTableCellBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    block.isHeader = r == 0
                    block.isFirstRow = r == 0
                    block.isLastRow = r == all.count - 1
                    block.isFirstColumn = c == 0
                    block.isLastColumn = c == table.numberOfColumns - 1
                    block.setWidth(padding.leading, type: .absoluteValueType, for: .padding, edge: .minX)
                    block.setWidth(padding.trailing, type: .absoluteValueType, for: .padding, edge: .maxX)
                    // The 1 pt line over a body row sits in the cell's top padding.
                    block.setWidth(padding.top, type: .absoluteValueType, for: .padding, edge: .minY)
                    block.setWidth(padding.bottom, type: .absoluteValueType, for: .padding, edge: .maxY)
                    if numeric.contains(c) {
                        // `nowrap`: the column is never narrower than its widest number.
                        let widest = all.map { c < $0.count ? $0[c] : "" }.map {
                            NSAttributedString(
                                string: AgentMarkdown.plainText($0),
                                attributes: [.font: Self.font(cellFace, bold: true)]).size().width
                        }.max() ?? 0
                        block.setValue(
                            widest.rounded(.up) + padding.leading + padding.trailing + 1, type: .absoluteValueType,
                            for: .minimumWidth)
                    }
                    let style = cellParagraph(cellFace)
                    style.textBlocks = [block]
                    if numeric.contains(c) { style.alignment = .right; style.lineBreakMode = .byClipping }
                    let parsed = book.flatMap { $0.parsedWithPills(cell) }
                    let start = out.length
                    let saved = face
                    face = cellFace
                    appendInline(parsed?.text ?? cell, groups: parsed?.groups ?? [], book: book, style: style, bold: r == 0)
                    face = saved
                    let color = r == 0 ? NSColor(Theme.Colors.ink)
                        : (AskTableRules.isMuted(cell) ? NSColor(Theme.AskDoc.Colors.quiet) : NSColor(Theme.Colors.ink2))
                    out.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: out.length - start))
                    let lastCell = r == all.count - 1 && c == cells.count - 1
                    if !(lastCell && isLast) {
                        append("\n", font: Self.font(cellFace), plain: true, style: style)
                    }
                }
            }
        }

        private func cellParagraph(_ face: AskTextFace) -> NSMutableParagraphStyle {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = face.lineSpacing
            return para
        }

        /// Items of one list sit closer together than paragraphs do (the face's paragraph gap, and 5 inside a list).
        /// A table keeps 4 above it and 12 under it (case map `table.t` margin), on top of no paragraph gap.
        private func blockGap(_ previous: AgentMarkdownBlock, _ block: AgentMarkdownBlock) -> CGFloat {
            switch (previous, block) {
            case (.bullet, .bullet), (.numbered, .numbered), (.bullet, .numbered), (.numbered, .bullet): 5
            case (.table, _): Theme.AskDoc.Column.tableMarginBottom
            case (_, .table): face.paragraphGap + Theme.AskDoc.Column.tableMarginTop
            default: face.paragraphGap
            }
        }

        private mutating func recolorLast(_ count: Int, color: NSColor) {
            let range = NSRange(location: out.length - count, length: count)
            out.addAttribute(.foregroundColor, value: color, range: range)
        }

        /// Task 11c (mockup `code`, `.path`, `.num`): a code span is a chip, a path (in code or in the text) a path chip,
        /// and in the need a key number is 600 with tabular digits. The characters stay as they are, so anchors keep
        /// their places.
        private mutating func decorate(_ chunk: String, at start: Int, font: NSFont, isCode: Bool) {
            let ink = NSColor(Theme.Colors.ink), quiet = NSColor(Theme.AskDoc.Colors.quiet)
            func ns(_ range: Range<String.Index>) -> NSRange {
                let r = NSRange(range, in: chunk)
                return NSRange(location: start + r.location, length: r.length)
            }
            if isCode {
                let trimmed = chunk.trimmingCharacters(in: .whitespaces)
                let kind: TextChipKind = InlinePaths.isPath(trimmed) ? .path : .code
                ChipPainter.mark(out, range: NSRange(location: start, length: (chunk as NSString).length), kind: kind, ink: ink, quiet: quiet)
                return
            }
            if face.mono { return }
            for range in InlinePaths.ranges(in: chunk) {
                ChipPainter.mark(out, range: ns(range), kind: .path, ink: ink, quiet: quiet)
            }
            if let numberColor = face.numberColor {
                let bold = NeedNumbers.tabular(PromptBarLogic.sansFont(size: face.size, weight: .semibold))
                for range in NeedNumbers.ranges(in: chunk) {
                    let r = ns(range)
                    guard out.attribute(.waggleChip, at: r.location, effectiveRange: nil) == nil else { continue }
                    out.addAttributes([.font: bold, .foregroundColor: numberColor], range: r)
                }
            }
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
                    let start = out.length
                    append(chunk, font: font, plain: true, style: style)
                    decorate(chunk, at: start, font: font, isCode: isCode && !face.mono)
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

/// The paragraph gap of the commentable text under it (`AskTextFace.paragraphGap`); the need box sets 7.
private struct AskParagraphGapKey: EnvironmentKey {
    static let defaultValue: CGFloat = AskTextFace.defaultParagraphGap
}

/// The need box sets this (task 11c): its key numbers draw 600, tabular, in this color.
private struct AskNumberColorKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var askParagraphGap: CGFloat {
        get { self[AskParagraphGapKey.self] }
        set { self[AskParagraphGapKey.self] = newValue }
    }

    var askNumberColor: Color? {
        get { self[AskNumberColorKey.self] }
        set { self[AskNumberColorKey.self] = newValue }
    }
}

/// A table cell that draws the mockup's table itself (mockup B `table.t`): one 1 pt line around the table with
/// 10 pt corners, the header row on the side fill, a 1 pt line over each body row, no lines between columns.
/// AppKit text tables have no corner radius, so each cell draws its share of the outline.
final class AskTableCellBlock: NSTextTableBlock {
    var isHeader = false
    var isFirstRow = false
    var isLastRow = false
    var isFirstColumn = false
    var isLastColumn = false

    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager
    ) {
        let flipped = controlView?.isFlipped ?? true
        let shape = AskTableCellShape(
            rect: frameRect, radius: Theme.AskDoc.Column.tableRadius, flipped: flipped,
            top: isFirstRow, bottom: isLastRow, left: isFirstColumn, right: isLastColumn)
        (isHeader ? NSColor(Theme.Colors.side) : NSColor.white).setFill()
        shape.fill().fill()
        NSColor(Theme.Colors.line).setStroke()
        let outline = shape.outline(rowLine: !isFirstRow)
        outline.lineWidth = 1
        outline.stroke()
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let cell = copy as? AskTableCellBlock {
            cell.isHeader = isHeader
            cell.isFirstRow = isFirstRow
            cell.isLastRow = isLastRow
            cell.isFirstColumn = isFirstColumn
            cell.isLastColumn = isLastColumn
        }
        return copy
    }
}

/// The paths of one table cell: the fill with the table's corners that fall in this cell rounded, and the outer
/// edges this cell owns (plus the line over a body row). Pure geometry, so a test can check it.
struct AskTableCellShape {
    let rect: NSRect
    let radius: CGFloat
    /// True when y grows downwards (a text view): the visual top is `minY`.
    var flipped = true
    let top: Bool
    let bottom: Bool
    let left: Bool
    let right: Bool

    private var topY: CGFloat { flipped ? rect.minY : rect.maxY }
    private var bottomY: CGFloat { flipped ? rect.maxY : rect.minY }
    /// One step from the top edge towards the bottom.
    private var down: CGFloat { flipped ? 1 : -1 }

    private static let k: CGFloat = 0.5523

    func fill() -> NSBezierPath {
        path(in: rect, inset: 0, closed: true, rowLine: false)
    }

    func outline(rowLine: Bool) -> NSBezierPath {
        path(in: rect, inset: 0.5, closed: false, rowLine: rowLine)
    }

    private func path(in rect: NSRect, inset: CGFloat, closed: Bool, rowLine: Bool) -> NSBezierPath {
        let minX = rect.minX + (left || closed ? inset : 0), maxX = rect.maxX - (right || closed ? inset : 0)
        let t = topY + down * inset, b = bottomY - down * inset
        let rTL = top && left ? radius : 0, rTR = top && right ? radius : 0
        let rBL = bottom && left ? radius : 0, rBR = bottom && right ? radius : 0
        let k = Self.k
        let path = NSBezierPath()
        func corner(from: NSPoint, to: NSPoint, c1: NSPoint, c2: NSPoint) { path.curve(to: to, controlPoint1: c1, controlPoint2: c2) }
        if closed {
            path.move(to: NSPoint(x: minX + rTL, y: t))
            path.line(to: NSPoint(x: maxX - rTR, y: t))
            if rTR > 0 {
                corner(from: .zero, to: NSPoint(x: maxX, y: t + down * rTR),
                       c1: NSPoint(x: maxX - rTR + k * rTR, y: t), c2: NSPoint(x: maxX, y: t + down * (rTR - k * rTR)))
            }
            path.line(to: NSPoint(x: maxX, y: b - down * rBR))
            if rBR > 0 {
                corner(from: .zero, to: NSPoint(x: maxX - rBR, y: b),
                       c1: NSPoint(x: maxX, y: b - down * (rBR - k * rBR)), c2: NSPoint(x: maxX - rBR + k * rBR, y: b))
            }
            path.line(to: NSPoint(x: minX + rBL, y: b))
            if rBL > 0 {
                corner(from: .zero, to: NSPoint(x: minX, y: b - down * rBL),
                       c1: NSPoint(x: minX + rBL - k * rBL, y: b), c2: NSPoint(x: minX, y: b - down * (rBL - k * rBL)))
            }
            path.line(to: NSPoint(x: minX, y: t + down * rTL))
            if rTL > 0 {
                corner(from: .zero, to: NSPoint(x: minX + rTL, y: t),
                       c1: NSPoint(x: minX, y: t + down * (rTL - k * rTL)), c2: NSPoint(x: minX + rTL - k * rTL, y: t))
            }
            path.close()
            return path
        }
        // The outline: each outer edge this cell owns, with its corners; the line over a body row.
        if top {
            path.move(to: NSPoint(x: minX + rTL, y: t))
            path.line(to: NSPoint(x: maxX - rTR, y: t))
        } else if rowLine {
            path.move(to: NSPoint(x: rect.minX, y: t))
            path.line(to: NSPoint(x: rect.maxX, y: t))
        }
        if rTR > 0 {
            path.move(to: NSPoint(x: maxX - rTR, y: t))
            corner(from: .zero, to: NSPoint(x: maxX, y: t + down * rTR),
                   c1: NSPoint(x: maxX - rTR + k * rTR, y: t), c2: NSPoint(x: maxX, y: t + down * (rTR - k * rTR)))
        }
        if right {
            path.move(to: NSPoint(x: maxX, y: (top ? t : topY) + down * rTR))
            path.line(to: NSPoint(x: maxX, y: (bottom ? b : bottomY) - down * rBR))
        }
        if rBR > 0 {
            path.move(to: NSPoint(x: maxX, y: b - down * rBR))
            corner(from: .zero, to: NSPoint(x: maxX - rBR, y: b),
                   c1: NSPoint(x: maxX, y: b - down * (rBR - k * rBR)), c2: NSPoint(x: maxX - rBR + k * rBR, y: b))
        }
        if bottom {
            path.move(to: NSPoint(x: maxX - rBR, y: b))
            path.line(to: NSPoint(x: minX + rBL, y: b))
        }
        if rBL > 0 {
            path.move(to: NSPoint(x: minX + rBL, y: b))
            corner(from: .zero, to: NSPoint(x: minX, y: b - down * rBL),
                   c1: NSPoint(x: minX + rBL - k * rBL, y: b), c2: NSPoint(x: minX, y: b - down * (rBL - k * rBL)))
        }
        if left {
            path.move(to: NSPoint(x: minX, y: (bottom ? b : bottomY) - down * rBL))
            path.line(to: NSPoint(x: minX, y: (top ? t : topY) + down * rTL))
        }
        if rTL > 0 {
            path.move(to: NSPoint(x: minX, y: t + down * rTL))
            corner(from: .zero, to: NSPoint(x: minX + rTL, y: t),
                   c1: NSPoint(x: minX, y: t + down * (rTL - k * rTL)), c2: NSPoint(x: minX + rTL - k * rTL, y: t))
        }
        return path
    }
}

/// What a table's cells hold, for its look (mockup B `.t td.num`, `.t .muted`). Pure, so it is tested.
enum AskTableRules {
    /// A column whose body cells are all numbers ("12", "$1,200", "−3.5 %", "~5", "2×", "15:00") is right-aligned
    /// and never wraps. Empty and muted cells do not count either way; a column with none of its own stays left.
    static func numericColumns(headers: [String], rows: [[String]]) -> Set<Int> {
        var out = Set<Int>()
        for column in 0..<max(headers.count, rows.map(\.count).max() ?? 0) {
            let cells = rows.compactMap { column < $0.count ? plain($0[column]) : nil }.filter { !$0.isEmpty && !isMuted($0) }
            if !cells.isEmpty, cells.allSatisfy(isNumber) { out.insert(column) }
        }
        return out
    }

    /// "—", "–", "-", "n/a", "none": a cell that says there is nothing, drawn in the quiet grey.
    static func isMuted(_ cell: String) -> Bool {
        ["—", "–", "-", "n/a", "na", "none", "?"].contains(plain(cell).lowercased())
    }

    static func isNumber(_ cell: String) -> Bool {
        let text = plain(cell)
        guard text.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        return text.range(of: #"^[~≈<>≤≥+\-−]?\s?[$€£¥]?\s?\d[\d.,:'\s]*\s?(%|×|x|k|K|M|ms|s|h|pt|px|MB|GB|KB)?$"#, options: .regularExpression) != nil
    }

    private static func plain(_ cell: String) -> String {
        AgentMarkdown.plainText(cell).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
