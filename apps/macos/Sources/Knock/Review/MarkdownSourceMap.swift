import Foundation

/// HAIL-150: a markdown artifact rendered to plain text plus a map back to its SOURCE.
///
/// A text comment anchors to a range of the markdown source (`TextAnchor.start`/`end`, UTF-16
/// offsets, the same unit a JavaScript string and `NSString` use). The operator selects text in the
/// rendered view, so every rendered character needs to know which source character it came from.
/// This parser builds both at once. It handles the same blocks and inline marks `MarkdownDocument`
/// does (headings, flat lists, fenced code, tables, bold, italics, inline code, links), and like it,
/// never produces an image or raw HTML.
///
/// `source[i]` is the source offset of rendered character `i`, or `-1` for text the renderer added
/// (a list bullet, a block's trailing newline). Syntax marks (`**`, `` ` ``, `#`) have no rendered
/// character, so no rendered range ever starts or ends on one.
struct RenderedMarkdown: Equatable {
    struct Style: OptionSet, Equatable {
        let rawValue: UInt8
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
        static let code = Style(rawValue: 4)
        static let strike = Style(rawValue: 8)
        /// A list bullet or number the renderer added.
        static let marker = Style(rawValue: 16)
        /// WAG-322: a word the newer version added, or an older word shown struck in place (inline changes view).
        static let added = Style(rawValue: 32)
        static let removed = Style(rawValue: 64)
    }

    enum BlockKind: Equatable {
        case heading(level: Int)
        case paragraph
        case listItem
        case code
        case tableCell(row: Int, column: Int, columns: Int, isHeader: Bool, isLastRow: Bool)
    }

    struct Block: Equatable {
        /// The rendered range of the block, including its trailing newline.
        let range: Range<Int>
        let kind: BlockKind
        /// The source range the block's own text sits in (HAIL-168, in-place edit): a paragraph's
        /// lines, a heading or list line, a code block's lines between the fences, a table cell's
        /// text. `nil` when the block has no place in the source to write to.
        var source: Range<Int>? = nil
        /// A list item's marker as the source writes it ("-", "*" or "3.").
        var listMarker: String = ""
        /// WAG-322: the block changed since the older version (a honey bar shows beside it), and the place of
        /// its entry in `WriteUpDiff.Result.entries`. Both stay unset without the inline changes view.
        var marked = false
        var entry: Int? = nil
    }

    /// The rendered text, UTF-16.
    var text: [UInt16] = []
    /// Per rendered character: its source offset, or -1.
    var source: [Int] = []
    /// Per rendered character: its inline style.
    var styles: [Style] = []
    /// Per rendered character: an index into `links`, or -1.
    var linkIndex: [Int] = []
    var links: [URL] = []
    var blocks: [Block] = []
    /// The source the map was built from.
    var sourceText: [UInt16] = []

    var string: String { String(decoding: text, as: UTF16.self) }

    // MARK: Mapping

    /// The source range a rendered selection covers, with the selection's edge whitespace and
    /// renderer-added characters left out. `nil` when the selection holds no source text.
    func sourceRange(forRendered range: Range<Int>) -> Range<Int>? {
        let clamped = max(0, range.lowerBound)..<min(text.count, range.upperBound)
        guard clamped.lowerBound < clamped.upperBound else { return nil }
        var first: Int?
        var last: Int?
        for i in clamped where source[i] >= 0 && !Self.isSpace(text[i]) {
            if first == nil { first = i }
            last = i
        }
        guard let first, let last else { return nil }
        return source[first]..<(source[last] + 1)
    }

    /// The exact source text of a source range.
    func quote(forSource range: Range<Int>) -> String {
        let r = max(0, range.lowerBound)..<min(sourceText.count, range.upperBound)
        guard r.lowerBound < r.upperBound else { return "" }
        return String(decoding: sourceText[r], as: UTF16.self)
    }

    /// The rendered range a source range lands on: from its first rendered character to its last.
    /// `nil` when the range holds no rendered character (all syntax marks, or out of range).
    func renderedRange(forSource range: Range<Int>) -> Range<Int>? {
        var first: Int?
        var last: Int?
        for i in 0..<source.count where source[i] >= range.lowerBound && source[i] < range.upperBound {
            if first == nil { first = i }
            last = i
        }
        guard let first, let last else { return nil }
        return first..<(last + 1)
    }

    private static func isSpace(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 }

    // MARK: Parsing

    static func parse(_ markdown: String) -> RenderedMarkdown {
        var builder = Builder(source: Array(markdown.utf16))
        builder.run()
        return builder.result
    }

    private struct Builder {
        let s: [UInt16]
        var result = RenderedMarkdown()

        init(source: [UInt16]) {
            s = source
            result.sourceText = source
        }

        // Lines as (start, end) with `end` exclusive, before the "\n" and any "\r".
        private lazy var lines: [(Int, Int)] = {
            var out: [(Int, Int)] = []
            var start = 0
            for i in 0..<s.count where s[i] == 10 {
                out.append((start, i > start && s[i - 1] == 13 ? i - 1 : i))
                start = i + 1
            }
            out.append((start, s.count > start && s[s.count - 1] == 13 ? s.count - 1 : s.count))
            return out
        }()

        private func trimmed(_ r: (Int, Int)) -> (Int, Int) {
            var (a, b) = r
            while a < b, s[a] == 32 || s[a] == 9 { a += 1 }
            while b > a, s[b - 1] == 32 || s[b - 1] == 9 { b -= 1 }
            return (a, b)
        }

        mutating func run() {
            let lines = self.lines
            var paragraph: (Int, Int)?
            var i = 0

            func flush(_ b: inout Builder) {
                if let p = paragraph {
                    b.block(.paragraph, source: p.0..<p.1) { $0.inline(p.0..<p.1, style: []) }
                    paragraph = nil
                }
            }

            while i < lines.count {
                let t = trimmed(lines[i])
                if t.0 == t.1 {
                    flush(&self)
                    i += 1
                    continue
                }
                if let (level, textStart) = headingLevel(t) {
                    flush(&self)
                    let inner = trimmed((textStart, t.1))
                    block(.heading(level: level), source: t.0..<t.1) { $0.inline(inner.0..<inner.1, style: []) }
                    i += 1
                    continue
                }
                if hasFence(t) {
                    flush(&self)
                    i += 1
                    var first: Int?
                    var last = 0
                    while i < lines.count, !hasFence(trimmed(lines[i])) {
                        if first == nil { first = lines[i].0 }
                        last = lines[i].1
                        i += 1
                    }
                    if i < lines.count { i += 1 }
                    if let first {
                        block(.code, source: first..<last) { b in
                            for k in first..<last where b.s[k] != 13 { b.emit(b.s[k], k, style: .code) }
                        }
                    }
                    continue
                }
                if contains(t, 124), i + 1 < lines.count, isTableSeparator(trimmed(lines[i + 1])) {
                    flush(&self)
                    let header = splitRow(t)
                    i += 2
                    var rows: [[(Int, Int)]] = []
                    while i < lines.count {
                        let row = trimmed(lines[i])
                        guard contains(lines[i], 124), row.0 < row.1 else { break }
                        rows.append(splitRow(row))
                        i += 1
                    }
                    emitTable(header: header, rows: rows)
                    continue
                }
                if let item = listItem(t) {
                    flush(&self)
                    block(.listItem, source: t.0..<t.1, listMarker: item.sourceMarker) { b in
                        for u in item.marker.utf16 { b.emit(u, -1, style: .marker) }
                        b.emit(9, -1, style: .marker)
                        b.inline(item.text.0..<item.text.1, style: [])
                    }
                    i += 1
                    continue
                }
                if let p = paragraph { paragraph = (p.0, t.1) } else { paragraph = (t.0, t.1) }
                i += 1
            }
            flush(&self)
            // The last block needs no trailing newline.
            if result.source.last == -1, result.text.last == 10, let lastBlock = result.blocks.last {
                result.text.removeLast()
                result.source.removeLast()
                result.styles.removeLast()
                result.linkIndex.removeLast()
                let trimmedBlock = Block(
                    range: lastBlock.range.lowerBound..<(lastBlock.range.upperBound - 1), kind: lastBlock.kind,
                    source: lastBlock.source, listMarker: lastBlock.listMarker)
                result.blocks[result.blocks.count - 1] = trimmedBlock
            }
        }

        // MARK: Blocks

        private mutating func block(
            _ kind: BlockKind, source: Range<Int>? = nil, listMarker: String = "", _ body: (inout Builder) -> Void
        ) {
            let start = result.text.count
            body(&self)
            emit(10, -1, style: [])
            result.blocks.append(Block(range: start..<result.text.count, kind: kind, source: source, listMarker: listMarker))
        }

        private mutating func emitTable(header: [(Int, Int)], rows: [[(Int, Int)]]) {
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            let all = [header] + rows
            for (r, cells) in all.enumerated() {
                for c in 0..<columns {
                    let cell = c < cells.count ? cells[c] : (0, 0)
                    let cellSource: Range<Int>? = c < cells.count ? cell.0..<cell.1 : nil
                    block(
                        .tableCell(row: r, column: c, columns: columns, isHeader: r == 0, isLastRow: r == all.count - 1),
                        source: cellSource
                    ) { b in
                        if cell.0 < cell.1 { b.inline(cell.0..<cell.1, style: []) }
                    }
                }
            }
        }

        private func contains(_ r: (Int, Int), _ u: UInt16) -> Bool {
            (r.0..<r.1).contains { s[$0] == u }
        }

        private func hasFence(_ t: (Int, Int)) -> Bool {
            t.1 - t.0 >= 3 && s[t.0] == 96 && s[t.0 + 1] == 96 && s[t.0 + 2] == 96
        }

        private func headingLevel(_ t: (Int, Int)) -> (Int, Int)? {
            var level = 0
            var k = t.0
            while k < t.1, s[k] == 35, level < 6 { level += 1; k += 1 }
            guard level > 0, k < t.1, s[k] == 32 else { return nil }
            return (level, k)
        }

        private func listItem(_ t: (Int, Int)) -> (marker: String, sourceMarker: String, text: (Int, Int))? {
            if t.1 - t.0 >= 2, s[t.0 + 1] == 32, s[t.0] == 45 || s[t.0] == 42 {
                return ("•", s[t.0] == 45 ? "-" : "*", trimmed((t.0 + 2, t.1)))
            }
            // "N. " with a number of up to three digits.
            var k = t.0
            while k < t.1, s[k] >= 48, s[k] <= 57, k - t.0 < 3 { k += 1 }
            guard k > t.0, k + 1 < t.1, s[k] == 46, s[k + 1] == 32 else { return nil }
            let number = String(decoding: s[t.0..<k], as: UTF16.self)
            return ("\(number).", "\(number).", trimmed((k + 2, t.1)))
        }

        private func isTableSeparator(_ t: (Int, Int)) -> Bool {
            guard contains(t, 45) else { return false }
            let hasPipe = contains(t, 124)
            guard hasPipe || !contains(t, 32) else { return false }
            var sawCell = false
            for k in t.0..<t.1 {
                switch s[k] {
                case 124: break
                case 45, 58, 32: sawCell = true
                default: return false
                }
            }
            return sawCell
        }

        private func splitRow(_ t: (Int, Int)) -> [(Int, Int)] {
            var (a, b) = t
            if a < b, s[a] == 124 { a += 1 }
            if b > a, s[b - 1] == 124 { b -= 1 }
            var cells: [(Int, Int)] = []
            var start = a
            for k in a...b where k == b || s[k] == 124 {
                cells.append(trimmed((start, k)))
                start = k + 1
            }
            return cells
        }

        // MARK: Inline

        private mutating func emit(_ u: UInt16, _ src: Int, style: Style, link: Int = -1) {
            result.text.append(u)
            result.source.append(src)
            result.styles.append(style)
            result.linkIndex.append(link)
        }

        private func isPunctuation(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return false }
            return u < 128 && !(scalar.properties.isAlphabetic || (48...57).contains(u) || u == 32)
        }

        private func isAlnum(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return false }
            return scalar.properties.isAlphabetic || (48...57).contains(u)
        }

        private func isSpace(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 }

        private func run(of u: UInt16, at i: Int, end: Int) -> Int {
            var k = i
            while k < end, s[k] == u { k += 1 }
            return k - i
        }

        /// The index of the closing run for an emphasis mark opened at `open` with `m` marks.
        private func findClosing(_ u: UInt16, _ m: Int, from: Int, end: Int, openAt open: Int) -> Int? {
            guard from < end, !isSpace(s[from]) else { return nil }
            var k = from
            while k < end {
                if s[k] == 92 { k += 2; continue }
                if s[k] == 96 {
                    // Skip a code span.
                    let n = run(of: 96, at: k, end: end)
                    var j = k + n
                    var found = false
                    while j < end {
                        if s[j] == 96, run(of: 96, at: j, end: end) == n { found = true; j += n; break }
                        j += 1
                    }
                    k = found ? j : k + n
                    continue
                }
                if s[k] == u {
                    let r = run(of: u, at: k, end: end)
                    let closes = m == 1 ? r == 1 : r >= m
                    if closes, k > from, !isSpace(s[k - 1]) {
                        if u == 95 {
                            let after = k + m
                            if after < end, isAlnum(s[after]) { k += r; continue }
                        }
                        return k
                    }
                    k += r
                    continue
                }
                k += 1
            }
            return nil
        }

        private mutating func inline(_ range: Range<Int>, style: Style, link: Int = -1) {
            var i = range.lowerBound
            let end = range.upperBound
            while i < end {
                let c = s[i]
                if c == 92, i + 1 < end, isPunctuation(s[i + 1]) {
                    emit(s[i + 1], i + 1, style: style, link: link)
                    i += 2
                    continue
                }
                if c == 96 {
                    let n = run(of: 96, at: i, end: end)
                    var j = i + n
                    var close: Int?
                    while j < end {
                        if s[j] == 96 {
                            let r = run(of: 96, at: j, end: end)
                            if r == n { close = j; break }
                            j += r
                        } else {
                            j += 1
                        }
                    }
                    if let close, close > i + n {
                        for k in (i + n)..<close { emit(s[k] == 10 ? 32 : s[k], k, style: style.union(.code), link: link) }
                        i = close + n
                    } else {
                        for k in i..<(i + n) { emit(s[k], k, style: style, link: link) }
                        i += n
                    }
                    continue
                }
                if c == 42 || c == 95 || c == 126 {
                    let n = run(of: c, at: i, end: end)
                    let m = c == 126 ? (n >= 2 ? 2 : 0) : min(n, 3)
                    let leftOK = c != 95 || i == range.lowerBound || !isAlnum(s[i - 1])
                    if m > 0, leftOK, let close = findClosing(c, m, from: i + m, end: end, openAt: i) {
                        var inner = style
                        if c == 126 { inner.insert(.strike) } else {
                            if m >= 2 { inner.insert(.bold) }
                            if m == 1 || m == 3 { inner.insert(.italic) }
                        }
                        inline((i + m)..<close, style: inner, link: link)
                        i = close + m
                        continue
                    }
                    for k in i..<(i + n) { emit(s[k], k, style: style, link: link) }
                    i += n
                    continue
                }
                if c == 91, link < 0, !(i > range.lowerBound && s[i - 1] == 33), let parsed = parseLink(at: i, end: end) {
                    result.links.append(parsed.url)
                    inline(parsed.label, style: style, link: result.links.count - 1)
                    i = parsed.next
                    continue
                }
                if c == 10 {
                    emit(32, i, style: style, link: link)
                    i += 1
                    while i < end, s[i] == 32 || s[i] == 9 { i += 1 }
                    continue
                }
                emit(c, i, style: style, link: link)
                i += 1
            }
        }

        /// `[label](url)` at `i`. Only http, https and mailto links become links (the text of any
        /// other scheme stays plain text).
        private func parseLink(at i: Int, end: Int) -> (label: Range<Int>, url: URL, next: Int)? {
            var depth = 0
            var k = i
            var closeBracket: Int?
            while k < end {
                if s[k] == 92 { k += 2; continue }
                if s[k] == 91 { depth += 1 }
                if s[k] == 93 {
                    depth -= 1
                    if depth == 0 { closeBracket = k; break }
                }
                k += 1
            }
            guard let closeBracket, closeBracket + 1 < end, s[closeBracket + 1] == 40, closeBracket > i + 1 else { return nil }
            var j = closeBracket + 2
            while j < end, s[j] != 41, s[j] != 10 { j += 1 }
            guard j < end, s[j] == 41 else { return nil }
            let raw = String(decoding: s[(closeBracket + 2)..<j], as: UTF16.self).trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return nil }
            return ((i + 1)..<closeBracket, url, j + 1)
        }
    }
}
