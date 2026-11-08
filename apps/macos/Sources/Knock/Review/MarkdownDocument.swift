import Foundation

/// One block of a parsed markdown document (HAIL-33: the review viewer
/// renders "headings, lists, code blocks, tables and links" with the app's
/// own typography, never raw HTML - `AttributedString(markdown:)` alone only
/// parses inline runs, not block structure, so this is a small, deliberately
/// limited block-level parser, not a full CommonMark implementation. It
/// never recognises markdown image syntax, so a remote image can never
/// render (the story's own "no remote images" rule) - by omission, not by a
/// filter that could be bypassed.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case listItem(ordered: Bool, index: Int, text: String)
    case codeBlock(text: String)
    case table(headers: [String], rows: [[String]])
}

enum MarkdownDocument {
    /// Parses `text` into a flat sequence of blocks, line by line. Blank
    /// lines separate paragraphs; a run of consecutive list items stays
    /// flat (no nesting - Non-goal: no chat thread or rich editor inside an
    /// ask, just a short explanation).
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var orderedIndex = 1

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let joined = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(text: joined)) }
            paragraphLines = []
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                orderedIndex = 1
                i += 1
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                i += 1
                var codeLines: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // skip the closing fence
                blocks.append(.codeBlock(text: codeLines.joined(separator: "\n")))
                continue
            }

            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let headers = splitTableRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitTableRow(lines[i]))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if let item = listItem(trimmed) {
                flushParagraph()
                if item.ordered {
                    blocks.append(.listItem(ordered: true, index: item.index ?? orderedIndex, text: item.text))
                    orderedIndex += 1
                } else {
                    blocks.append(.listItem(ordered: false, index: 0, text: item.text))
                }
                i += 1
                continue
            }

            paragraphLines.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// Inline formatting within one block's text (bold, italic, inline
    /// code, links) via Foundation's own markdown parser, restricted to
    /// inline syntax so it never re-interprets a block-level "#"/"-" this
    /// parser already consumed. Falls back to the plain text on a parse
    /// failure - malformed markdown must still render as *something*, never
    /// crash or vanish.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var chars = Substring(line)
        while chars.first == "#", level < 6 {
            level += 1
            chars = chars.dropFirst()
        }
        guard chars.first == " " else { return nil }
        return (level, chars.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (ordered: Bool, index: Int?, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return (false, nil, String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        guard let dotRange = line.range(of: ". "), line.distance(from: line.startIndex, to: dotRange.lowerBound) <= 3
        else { return nil }
        let numeral = line[line.startIndex..<dotRange.lowerBound]
        guard let index = Int(numeral) else { return nil }
        return (true, index, String(line[dotRange.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || !trimmed.contains(" ") else { return false }
        let cells = trimmed.split(separator: "|")
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
