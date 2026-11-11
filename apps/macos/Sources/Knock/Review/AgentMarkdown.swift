import Foundation

/// One block of an agent's text (HAIL-70, operator decision 29 Sep: agent text
/// renders as safe markdown). A small parser on purpose: paragraphs, bullets one
/// level deep, numbered lists, pipe tables (decision 2026-11-11). Headings keep their text and lose the "#".
/// Images and HTML stay as plain text lines. It never produces a link or an
/// image, so nothing here can open or load anything.
enum AgentMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String)
    /// `level` is 0, or 1 for an indented bullet.
    case bullet(level: Int, text: String)
    case numbered(level: Int, index: Int, text: String)
    /// A pipe table: a header row, a `---` separator row, then body rows. Every row has as many cells as the header.
    case table(headers: [String], rows: [[String]])
}

enum AgentMarkdown {
    /// `keepingSources` leaves the source markers `[[s:ID]]` in the text for the request page, which draws them as
    /// pills (WAG-356). Every other caller gets them removed: no raw marker is ever visible.
    static func blocks(_ text: String, keepingSources: Bool = false) -> [AgentMarkdownBlock] {
        let text = keepingSources ? text : SourceMarkers.strip(text)
        var blocks: [AgentMarkdownBlock] = []
        var paragraph: [String] = []
        var nextIndex = 1

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            i += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("|"), i < lines.count, isTableSeparator(lines[i]) {
                flush()
                let headers = tableCells(trimmed)
                i += 1
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(fitted(tableCells(lines[i]), to: headers.count))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                nextIndex = 1
                continue
            }
            if trimmed.isEmpty {
                flush()
                nextIndex = 1
                continue
            }
            let indented = raw.hasPrefix("  ") || raw.hasPrefix("\t")
            if let item = listMarker(trimmed) {
                flush()
                let level = indented ? 1 : 0
                if item.ordered {
                    blocks.append(.numbered(level: level, index: item.index ?? nextIndex, text: item.text))
                    nextIndex = (item.index ?? nextIndex) + 1
                } else {
                    blocks.append(.bullet(level: level, text: item.text))
                }
            } else if let heading = headingText(trimmed) {
                flush()
                blocks.append(.heading(heading))
            } else if indented, let last = blocks.last, paragraph.isEmpty, let joined = appending(trimmed, to: last) {
                blocks[blocks.count - 1] = joined
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return blocks
    }

    /// The inline runs of one block: bold, italic and inline code kept as
    /// attributes, links and images reduced to their visible text.
    static func inline(_ text: String) -> AttributedString {
        let text = SourceMarkers.strip(text)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var parsed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        parsed.link = nil
        parsed.imageURL = nil
        return parsed
    }

    /// One plain line for a queue row or a notification: markers gone, list and
    /// heading prefixes gone, lines joined with a space.
    static func singleLine(_ text: String) -> String {
        let lines = SourceMarkers.strip(text).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").compactMap {
            raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !isTableSeparator(trimmed) else { return nil }
            let body = listMarker(trimmed)?.text ?? headingText(trimmed) ?? trimmed
            let plain = String(inline(body).characters).trimmingCharacters(in: .whitespaces)
            return plain.isEmpty ? nil : plain
        }
        return lines.joined(separator: " ")
    }

    /// The line with its source markers kept, for a note that the request page draws as pills (WAG-356).
    /// A view that shows it must be `SourcedText` or `CalmNoteView`, which remove the markers when they draw no pill.
    static func singleLine(_ text: String, keepingSources: Bool) -> String {
        guard keepingSources, text.contains("[[s:") else { return singleLine(text) }
        let parsed = SourceMarkers.parse(text)
        return SourceMarkers.restore(singleLine(parsed.text), groups: parsed.groups)
    }

    /// The text of a message as plain text for the clipboard (HAIL-94): markers gone,
    /// paragraphs split by a blank line, list items one per line with "- " or "1." kept.
    static func plainText(_ text: String) -> String {
        let blocks = blocks(text)
        var out = ""
        for (index, block) in blocks.enumerated() {
            let line: String
            switch block {
            case .paragraph(let body), .heading(let body): line = plain(body)
            case .bullet(let level, let body): line = String(repeating: "  ", count: level) + "- " + plain(body)
            case .numbered(let level, let n, let body): line = String(repeating: "  ", count: level) + "\(n). " + plain(body)
            case .table(let headers, let rows):
                line = ([headers] + rows).map { "| " + $0.map(plain).joined(separator: " | ") + " |" }.joined(separator: "\n")
            }
            if index > 0 {
                let kind: (AgentMarkdownBlock) -> Int = {
                    switch $0 {
                    case .bullet: 1
                    case .numbered: 2
                    default: 0
                    }
                }
                out += kind(block) != 0 && kind(block) == kind(blocks[index - 1]) ? "\n" : "\n\n"
            }
            out += line
        }
        return out
    }

    private static func plain(_ text: String) -> String {
        String(inline(text).characters)
    }

    /// An inline code span longer than this many characters gets a copy button.
    static let longCodeSpan = 24

    /// The commands of a message that get a one-click copy button (HAIL-94):
    /// every inline code span longer than `longCodeSpan` characters, in order and
    /// without repeats. With none, a message whose whole body looks like a command
    /// offers the body itself.
    static func copyableCommands(_ text: String) -> [String] {
        var found: [String] = []
        for block in blocks(text) {
            let bodies: [String]
            switch block {
            case .paragraph(let t), .heading(let t), .bullet(_, let t), .numbered(_, _, let t): bodies = [t]
            case .table(let headers, let rows): bodies = headers + rows.flatMap { $0 }
            }
            for body in bodies {
            for span in codeSpans(body) where span.count > longCodeSpan && !found.contains(span) {
                found.append(span)
            }
            }
        }
        if found.isEmpty, looksLikeCommand(text) {
            var command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if command.hasPrefix("$ ") { command = String(command.dropFirst(2)) }
            return [command]
        }
        return found
    }

    /// The code spans of one block, trimmed.
    static func codeSpans(_ text: String) -> [String] {
        let parsed = inline(text)
        return parsed.runs.compactMap { run in
            guard run.inlinePresentationIntent?.contains(.code) == true else { return nil }
            return String(parsed[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static let commandNames: Set<String> = [
        "git", "bun", "bunx", "npm", "npx", "pnpm", "yarn", "swift", "xcodebuild", "make", "cargo", "go",
        "python", "python3", "pip", "brew", "curl", "cd", "ls", "cat", "grep", "rg", "sed", "open", "kill",
        "docker", "kubectl", "gh", "claude", "codex", "waggle", "knock", "bash", "sh", "zsh", "sudo", "env", "export",
        "rm", "mv", "cp", "mkdir", "chmod", "launchctl", "defaults", "codesign", "xattr", "ssh", "node", "deno",
    ]

    /// True when the whole body reads as one shell command: one or a few lines
    /// with no markup, a "$ " prompt or a known tool name first, and it does not end
    /// like a sentence.
    static func looksLikeCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("`"), !trimmed.contains("\n\n"),
            trimmed.components(separatedBy: "\n").count <= 3, trimmed.count <= 400
        else { return false }
        var body = Substring(trimmed)
        let prompted = body.hasPrefix("$ ")
        if prompted { body = body.dropFirst(2) }
        if !prompted, [".", "!", "?", ":"].contains(where: { trimmed.hasSuffix($0) }) { return false }
        let first = body.prefix(while: { !$0.isWhitespace })
        let isPath = first.hasPrefix("./") || first.hasPrefix("/") || first.hasPrefix("~/")
        guard prompted || isPath || commandNames.contains(String(first)) else { return false }
        // A tool name in plain prose is not a command: it needs an argument with a
        // flag, path, pipe or assignment in it.
        let rest = body.dropFirst(first.count)
        return prompted || isPath || rest.contains(where: { "-/.=~&|>".contains($0) })
    }

    private static func appending(_ line: String, to block: AgentMarkdownBlock) -> AgentMarkdownBlock? {
        switch block {
        case .bullet(let level, let text): .bullet(level: level, text: text + " " + line)
        case .numbered(let level, let index, let text): .numbered(level: level, index: index, text: text + " " + line)
        default: nil
        }
    }

    /// A `|---|:--:|` row: only dashes, colons, spaces and pipes, with at least one dash and one pipe.
    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { "-:| ".contains($0) }
    }

    /// The cells of one table row, without the outer pipes. `\|` stays a pipe inside a cell.
    static func tableCells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for ch in body {
            if escaped { cell.append(ch == "|" ? "|" : "\\\(ch)"); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""; continue }
            cell.append(ch)
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func fitted(_ cells: [String], to count: Int) -> [String] {
        cells.count >= count ? Array(cells.prefix(count)) : cells + Array(repeating: "", count: count - cells.count)
    }

    static func headingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let rest = line.drop(while: { $0 == "#" })
        guard line.count - rest.count <= 6, rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    static func listMarker(_ line: String) -> (ordered: Bool, index: Int?, text: String)? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return (false, nil, String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix(while: \.isNumber)
        guard (1...3).contains(digits.count), let index = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (true, index, String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }
}
