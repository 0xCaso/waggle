import SwiftUI

/// Agent text as safe markdown (HAIL-70, Pen `f3F6q`): paragraphs with spacing,
/// bullets and numbered lists on a hanging indent with a muted marker, bold,
/// italic and inline code (mono, side fill). Links, images and HTML show as plain
/// text. Nothing here is clickable and nothing loads.
struct AgentMarkdownText: View {
    let text: String
    var style: Theme.TextStyle = Theme.Typography.body12_5w400
    var color: Color = Theme.Colors.ink
    /// One-click copy buttons for long inline commands (HAIL-94).
    var offersCommandCopy = true
    /// The request page draws the source markers of this text as pills (WAG-356). Everywhere else they are gone.
    var showsSources = false
    /// WAG-357: where this text sits on the request page, when the person can comment on it.
    var target: AskCommentTarget? = nil
    var weight: NSFont.Weight = .regular
    @Environment(\.sourcesHub) private var hub
    @Environment(\.askComments) private var askHub
    @Environment(\.askParagraphGap) private var paragraphGap
    @Environment(\.askNumberColor) private var numberColor

    /// The hub when this text draws pills: the page opted in and the round has sources.
    private var pillHub: SourcesHub? {
        guard showsSources, let hub, !hub.book.isEmpty, text.contains("[[s:") else { return nil }
        return hub
    }

    var body: some View {
        let blocks = AgentMarkdown.blocks(text, keepingSources: pillHub != nil)
        VStack(alignment: .leading, spacing: paragraphGap) {
            if let target, let askHub {
                CommentableAskText(text: text, mode: .blocks, style: style, weight: weight, color: color, target: target, hub: askHub)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    blockView(block)
                        .padding(.top, index > 0 ? extraGap(before: block, after: blocks[index - 1]) : 0)
                }
            }
            if offersCommandCopy {
                let commands = AgentMarkdown.copyableCommands(text)
                if !commands.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(commands, id: \.self) { CopyPill(label: $0, copies: $0, mono: true) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// Items of one list sit closer together than paragraphs do.
    private func extraGap(before block: AgentMarkdownBlock, after previous: AgentMarkdownBlock) -> CGFloat {
        switch (previous, block) {
        case (.bullet, .bullet), (.numbered, .numbered), (.bullet, .numbered), (.numbered, .bullet): -3
        default: 0
        }
    }

    @ViewBuilder
    private func blockView(_ block: AgentMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            run(text)
        case .heading(let text):
            run(text, base: style.font.weight(.semibold))
        case .bullet(let level, let text):
            item(marker: "•", level: level, text: text)
        case .numbered(let level, let index, let text):
            item(marker: "\(index).", level: level, text: text)
        case .table(let headers, let rows):
            table(headers: headers, rows: rows)
        }
    }

    /// A pipe table as mockup B's `table.t` at the case map's sizes (the same look as the commentable path,
    /// `AskTableCellBlock`): one line around it with 10 pt corners, the header row on the side fill in 600 ink, a line
    /// over each body row, cells 12 pt ink2 with 7/10 padding, number columns right-aligned, a muted cell quiet.
    private func table(headers: [String], rows: [[String]]) -> some View {
        let numeric = AskTableRules.numericColumns(headers: headers, rows: rows)
        return Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { column, cell in
                    tableCell(cell, header: true, numeric: numeric.contains(column))
                }
            }
            .background(Theme.Colors.side)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                Rectangle().fill(Theme.Colors.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                        tableCell(cell, header: false, numeric: numeric.contains(column))
                    }
                }
            }
        }
        .background(Theme.Colors.win)
        .clipShape(RoundedRectangle(cornerRadius: Theme.AskDoc.Column.tableRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.AskDoc.Column.tableRadius)
                .strokeBorder(Theme.Colors.line, lineWidth: 1)
        )
        .padding(.top, Theme.AskDoc.Column.tableMarginTop)
        .padding(.bottom, max(0, Theme.AskDoc.Column.tableMarginBottom - paragraphGap))
    }

    private func tableCell(_ text: String, header: Bool, numeric: Bool) -> some View {
        let style = Theme.AskDoc.Column.tableText
        let color = header ? Theme.Colors.ink : (AskTableRules.isMuted(text) ? Theme.AskDoc.Colors.quiet : Theme.Colors.ink2)
        return Text(styled(text, base: Theme.AskDoc.Column.font(style.size, header ? .semibold : .regular), size: style.size))
            .knockTextStyle(style)
            .foregroundColor(color)
            .multilineTextAlignment(numeric ? .trailing : .leading)
            .lineLimit(numeric ? 1 : nil)
            .fixedSize(horizontal: numeric, vertical: true)
            .padding(Theme.AskDoc.Column.tableCellPadding)
            .frame(maxWidth: .infinity, alignment: numeric ? .trailing : .leading)
    }

    private func item(marker: String, level: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .knockTextStyle(style)
                .foregroundColor(Theme.Colors.ink3)
                .frame(minWidth: 12, alignment: .trailing)
            run(text)
        }
        .padding(.leading, level == 0 ? 6 : 24)
    }

    /// One run of text: plain, or with its markers drawn as pills when some marker names a source.
    @ViewBuilder
    private func run(_ text: String, base: Font? = nil) -> some View {
        if let hub = pillHub, text.contains("[[s:"), let parsed = SourcedText.resolvable(text, in: hub.book) {
            PillFlowText(hub: hub, text: styled(parsed.text, base: base), groups: parsed.groups, style: style, color: color)
        } else {
            Text(styled(text, base: base)).knockTextStyle(style).foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func styled(_ text: String, base: Font? = nil, size: CGFloat? = nil) -> AttributedString {
        var out = AgentMarkdown.inline(text)
        let body = base ?? style.font
        let size = size ?? style.size
        for run in out.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = body
            if intent.contains(.code) {
                font = .custom(Theme.FontFamily.mono, size: max(size - 1, 10))
                out[run.range].backgroundColor = Theme.Colors.side
            }
            if intent.contains(.stronglyEmphasized) { font = font.weight(.semibold) }
            if intent.contains(.emphasized) { font = font.italic() }
            out[run.range].font = font
        }
        // Task 11c: in the need box, key numbers in 600 with tabular digits (mockup `.num`).
        if let numberColor {
            let plain = String(out.characters)
            let codeRanges = out.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
            for range in NeedNumbers.ranges(in: plain) {
                let start = plain.distance(from: plain.startIndex, to: range.lowerBound)
                let length = plain.distance(from: range.lowerBound, to: range.upperBound)
                let lower = out.characters.index(out.startIndex, offsetBy: start)
                let upper = out.characters.index(lower, offsetBy: length)
                guard !codeRanges.contains(where: { $0.contains(lower) }) else { continue }
                out[lower..<upper].font = Theme.AskDoc.Column.font(size, .semibold).monospacedDigit()
                out[lower..<upper].foregroundColor = numberColor
            }
        }
        return out
    }
}
