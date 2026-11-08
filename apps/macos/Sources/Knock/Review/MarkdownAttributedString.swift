import AppKit

/// HAIL-150: draws a `RenderedMarkdown` as an `NSAttributedString` in the app's own typography
/// (the same tokens `MarkdownView` uses), so the selectable, commentable markdown view looks like the
/// read-only one. Characters keep their index: `string[i]` is `RenderedMarkdown.text[i]`.
extension RenderedMarkdown {
    private static func sans(_ size: CGFloat, semibold: Bool = false, italic: Bool = false) -> NSFont {
        var font = PromptBarLogic.sansFont(size: size, weight: semibold ? .semibold : .regular)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    private static func mono(_ size: CGFloat) -> NSFont {
        guard FontRegistration.didRegisterBundledFonts, let font = NSFont(name: Theme.FontFamily.mono, size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }

    private static let ink = NSColor(Theme.Colors.ink)
    private static let ink3 = NSColor(Theme.Colors.ink3)
    private static let side = NSColor(Theme.Colors.side)
    private static let line = NSColor(Theme.Colors.line)
    private static let accent = NSColor(Theme.Colors.accent)
    private static let ok = NSColor(Theme.Colors.ok)
    private static let okSoft = NSColor(Theme.Colors.okSoft)
    private static let watch = NSColor(Theme.AskDoc.Colors.watch)
    private static let watchSoft = NSColor(Theme.AskDoc.Colors.watchSoft)

    /// Link colour and underline come from the view's `linkTextAttributes`.
    func attributedString() -> NSAttributedString {
        let out = NSMutableAttributedString(string: string)
        var tables: [Int: NSTextTable] = [:]

        for block in blocks {
            let range = NSRange(location: block.range.lowerBound, length: block.range.count)
            let para = NSMutableParagraphStyle()
            var size: CGFloat = 13
            var semibold = false
            var lineHeight: CGFloat = 1.45
            para.paragraphSpacing = 12

            switch block.kind {
            case .heading(let level):
                size = level == 1 ? 15 : (level == 2 ? 13.5 : 12.5)
                semibold = true
                lineHeight = level == 1 ? 1.3 : 1.45
            case .paragraph:
                break
            case .listItem:
                para.firstLineHeadIndent = 0
                para.headIndent = 22
                para.tabStops = [NSTextTab(textAlignment: .left, location: 22)]
            case .code:
                size = 12
                lineHeight = 1.4
                let box = Self.makeCodeBlock()
                box.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
                para.textBlocks = [box]
                para.paragraphSpacing = 0
            case .tableCell(let row, let column, let columns, let isHeader, let isLastRow):
                size = 12.5
                semibold = isHeader
                para.paragraphSpacing = 0
                let table = tables[Self.tableStart(blocks, containing: block)] ?? Self.makeTable(columns: columns)
                tables[Self.tableStart(blocks, containing: block)] = table
                let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setContentWidth(100 / CGFloat(columns), type: .percentageValueType)
                cell.setWidth(7, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(7, type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setBorderColor(Self.line)
                cell.backgroundColor = isHeader ? Self.side : nil
                if isLastRow { cell.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY) }
                para.textBlocks = [cell]
                lineHeight = 1.4
            }
            para.lineSpacing = size * (lineHeight - 1)
            let base = block.kind == .code ? Self.mono(size) : Self.sans(size, semibold: semibold)
            out.addAttributes([.font: base, .foregroundColor: Self.ink, .paragraphStyle: para], range: range)
        }

        // Inline runs.
        var i = 0
        while i < text.count {
            var j = i + 1
            while j < text.count, styles[j] == styles[i], linkIndex[j] == linkIndex[i] { j += 1 }
            let style = styles[i]
            let run = NSRange(location: i, length: j - i)
            if style.contains(.marker) {
                out.addAttribute(.foregroundColor, value: Self.ink3, range: run)
            }
            if style != [] || linkIndex[i] >= 0, let current = out.attribute(.font, at: i, effectiveRange: nil) as? NSFont {
                var font = current
                if style.contains(.code), !isCodeBlock(at: i) { font = Self.mono(current.pointSize - 0.5) }
                if style.contains(.bold), !isHeading(at: i) { font = Self.sans(current.pointSize, semibold: true) }
                if style.contains(.italic) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    if !NSFontManager.shared.traits(of: font).contains(.italicFontMask) {
                        out.addAttribute(.obliqueness, value: 0.2, range: run)
                    }
                }
                out.addAttribute(.font, value: font, range: run)
                if style.contains(.code), !isCodeBlock(at: i) {
                    out.addAttribute(.backgroundColor, value: Self.side, range: run)
                }
                if style.contains(.strike) {
                    out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run)
                }
            }
            if style.contains(.added) {
                out.addAttributes([.foregroundColor: Self.ok, .backgroundColor: Self.okSoft], range: run)
            } else if style.contains(.removed) {
                out.addAttributes([.foregroundColor: Self.watch, .backgroundColor: Self.watchSoft], range: run)
            }
            if linkIndex[i] >= 0 {
                out.addAttribute(.link, value: links[linkIndex[i]], range: run)
            }
            i = j
        }
        return out
    }

    private func isCodeBlock(at index: Int) -> Bool {
        blocks.first { $0.range.contains(index) }?.kind == .code
    }

    private func isHeading(at index: Int) -> Bool {
        if case .heading = blocks.first(where: { $0.range.contains(index) })?.kind { return true }
        return false
    }

    /// The start of the first cell of the table `block` belongs to: the blocks of one table are
    /// consecutive cells, row by row, and a table is told apart from the next by its first cell.
    private static func tableStart(_ blocks: [Block], containing block: Block) -> Int {
        guard var index = blocks.firstIndex(of: block) else { return block.range.lowerBound }
        while index > 0, case .tableCell(let row, let column, _, _, _) = blocks[index].kind, !(row == 0 && column == 0) {
            index -= 1
        }
        return blocks[index].range.lowerBound
    }

    private static func makeTable(columns: Int) -> NSTextTable {
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        return table
    }

    private static func makeCodeBlock() -> NSTextBlock {
        let table = NSTextTable()
        table.numberOfColumns = 1
        let box = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        box.backgroundColor = side
        box.setWidth(10, type: .absoluteValueType, for: .padding)
        box.setWidth(1, type: .absoluteValueType, for: .border)
        box.setBorderColor(line)
        box.setContentWidth(100, type: .percentageValueType)
        return box
    }
}
