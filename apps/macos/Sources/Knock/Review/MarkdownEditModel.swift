import Foundation

/// HAIL-168: the state of editing a markdown explanation in place.
///
/// The person edits the rendered text, not the markdown. The model keeps every character the
/// document had, each marked `kept`, `deleted` (it stays on screen, struck through) or `added`
/// (typed by the person). Deleting an original character marks it; deleting an added one removes it.
/// Nothing the person types is ever written as markdown syntax: `markdown()` writes the edited
/// blocks again from their characters and escapes every mark, so no link, image or HTML can come
/// out of an edit. A block the person did not touch keeps its source text exactly.
struct MarkdownEditModel: Equatable {
    enum State: Equatable { case kept, deleted, added }

    enum Role: Equatable {
        /// Text the person can edit.
        case text
        /// A list bullet or number the renderer drew. Not editable.
        case marker
        /// The newline that ends an original block. Not editable.
        case blockEnd
        /// A paragraph or list item break the person typed (Return).
        case lineBreak
    }

    /// One UTF-16 unit of the document.
    struct Unit: Equatable {
        var u: UInt16
        var state: State
        var role: Role
        /// The index of the block it belongs to in `base.blocks`.
        var block: Int
        var style: RenderedMarkdown.Style
        var link: Int
    }

    let base: RenderedMarkdown
    private(set) var units: [Unit]
    private var past: [[Unit]] = []
    private var future: [[Unit]] = []

    init(markdown: String) {
        let base = RenderedMarkdown.parse(markdown)
        self.base = base
        var blockOf = [Int](repeating: 0, count: base.text.count)
        for (index, block) in base.blocks.enumerated() {
            for i in block.range where i < blockOf.count { blockOf[i] = index }
        }
        units = base.text.indices.map { i in
            let role: Role
            if base.source[i] >= 0 {
                role = .text
            } else {
                role = base.styles[i].contains(.marker) ? .marker : .blockEnd
            }
            return Unit(
                u: base.text[i], state: .kept, role: role, block: blockOf[i], style: base.styles[i],
                link: base.linkIndex[i])
        }
    }

    // MARK: State

    /// The text as it shows while editing: kept, deleted and added characters together.
    var displayText: [UInt16] { units.map(\.u) }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// True when the markdown the edit would save differs from the original.
    var hasChanges: Bool {
        units.contains { $0.state != .kept } && markdown() != String(decoding: base.sourceText, as: UTF16.self)
    }

    mutating func undo() -> Bool {
        guard let previous = past.popLast() else { return false }
        future.append(units)
        units = previous
        return true
    }

    mutating func redo() -> Bool {
        guard let next = future.popLast() else { return false }
        past.append(units)
        units = next
        return true
    }

    // MARK: Editing

    /// Replaces a range of the displayed text with typed text. Returns the new caret position, or
    /// `nil` when the edit changes nothing (it touched only protected characters, or it would write
    /// somewhere the source has no place for).
    mutating func replace(_ range: Range<Int>, with typed: String) -> Int? {
        guard range.lowerBound >= 0, range.upperBound <= units.count else { return nil }

        // What the range removes. Original text is marked, added text goes away. Protected
        // characters (bullets, block ends) stay. An added break takes its added bullet with it.
        var removeAdded = Set<Int>()
        var marked = Set<Int>()
        for k in range {
            let unit = units[k]
            switch (unit.state, unit.role) {
            case (.kept, .text): marked.insert(k)
            case (.added, .text): removeAdded.insert(k)
            case (.added, .lineBreak):
                removeAdded.insert(k)
                var m = k + 1
                while m < units.count, units[m].state == .added, units[m].role == .marker {
                    removeAdded.insert(m)
                    m += 1
                }
            default: break
            }
        }

        let insertAt = range.upperBound
        var out: [Unit] = []
        out.reserveCapacity(units.count + typed.utf16.count)
        var insertIndex = 0
        for k in 0..<units.count {
            if k == insertAt { insertIndex = out.count }
            if removeAdded.contains(k) { continue }
            var unit = units[k]
            if marked.contains(k) { unit.state = .deleted }
            out.append(unit)
        }
        if insertAt >= units.count { insertIndex = out.count }

        // Typing over a selection keeps the look the selection had, when all of it shared one.
        var hint: (style: RenderedMarkdown.Style, link: Int)?
        for k in marked.union(removeAdded).sorted() where units[k].role == .text {
            let unit = units[k]
            if let current = hint {
                hint = (current.style.intersection(unit.style), current.link == unit.link ? current.link : -1)
            } else {
                hint = (unit.style, unit.link)
            }
        }

        var inserted: [Unit] = []
        if !typed.isEmpty {
            guard let made = Self.insertedUnits(for: typed, at: insertIndex, in: out, base: base, hint: hint) else { return nil }
            inserted = made
        }
        guard !marked.isEmpty || !removeAdded.isEmpty || !inserted.isEmpty else { return nil }

        past.append(units)
        future.removeAll()
        out.insert(contentsOf: inserted, at: insertIndex)
        units = out
        return insertIndex + inserted.count
    }

    private static func insertedUnits(
        for typed: String, at index: Int, in out: [Unit], base: RenderedMarkdown,
        hint: (style: RenderedMarkdown.Style, link: Int)?
    ) -> [Unit]? {
        let prev = index > 0 ? out[index - 1] : nil
        let next = index < out.count ? out[index] : nil
        let block: Int
        if let prev, prev.role != .blockEnd {
            block = prev.block
        } else if let next {
            block = next.block
        } else {
            return nil
        }
        let info = base.blocks[block]
        guard info.source != nil else { return nil }

        // The style is the one the characters on both sides share, so typing inside bold is bold
        // and typing at its edge is plain.
        var style: RenderedMarkdown.Style = []
        var link = -1
        if case .code = info.kind {
            style = .code
        } else if let hint {
            style = hint.style.subtracting(.marker)
            link = hint.link
        } else if let prev, let next, prev.block == block, next.block == block, prev.role == .text, next.role == .text {
            style = prev.style.intersection(next.style).subtracting(.marker)
            if prev.link >= 0, prev.link == next.link { link = prev.link }
        }

        var result: [Unit] = []
        let normalized = typed.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for u in normalized.utf16 {
            if u == 10 {
                switch info.kind {
                case .tableCell:
                    return nil
                case .code:
                    result.append(Unit(u: 10, state: .added, role: .text, block: block, style: .code, link: -1))
                case .listItem:
                    result.append(Unit(u: 10, state: .added, role: .lineBreak, block: block, style: [], link: -1))
                    for m in listMarkerDisplay(info.listMarker).utf16 + [9] {
                        result.append(Unit(u: m, state: .added, role: .marker, block: block, style: .marker, link: -1))
                    }
                case .heading, .paragraph:
                    result.append(Unit(u: 10, state: .added, role: .lineBreak, block: block, style: [], link: -1))
                }
                continue
            }
            // Keep the cell grid and the fences safe.
            if case .tableCell = info.kind, u == 124 { continue }
            let value: UInt16 = u == 9 ? 32 : u
            result.append(Unit(u: value, state: .added, role: .text, block: block, style: style, link: link))
        }
        return result
    }

    private static func listMarkerDisplay(_ sourceMarker: String) -> String {
        if sourceMarker.hasSuffix("."), let n = Int(sourceMarker.dropLast()) { return "\(n + 1)." }
        return "•"
    }

    // MARK: Comparison

    /// An old document with a later one drawn over it: what the later one dropped is struck
    /// through, what it added is marked as added. Used by "Compare with v1" (read-only).
    static func comparison(from old: String, to new: String) -> MarkdownEditModel {
        var model = MarkdownEditModel(markdown: old)
        let before = tokens(String(decoding: model.displayText, as: UTF16.self))
        let after = tokens(RenderedMarkdown.parse(new).string)
        var offsets = [0]
        for token in before { offsets.append(offsets.last! + token.utf16.count) }
        for hunk in diffHunks(before, after).reversed() {
            let range = offsets[hunk.old.lowerBound]..<offsets[hunk.old.upperBound]
            _ = model.replace(range, with: after[hunk.new].joined())
        }
        model.past = []
        model.future = []
        return model
    }

    /// Words, runs of spaces and single other characters.
    private static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        var space = ""
        func flush() {
            if !word.isEmpty { out.append(word); word = "" }
            if !space.isEmpty { out.append(space); space = "" }
        }
        for ch in text {
            if ch.isLetter || ch.isNumber {
                if !space.isEmpty { out.append(space); space = "" }
                word.append(ch)
            } else if ch == " " || ch == "\t" {
                if !word.isEmpty { out.append(word); word = "" }
                space.append(ch)
            } else {
                flush()
                out.append(String(ch))
            }
        }
        flush()
        return out
    }

    /// The groups of tokens that differ, from the longest common subsequence.
    private static func diffHunks(_ a: [String], _ b: [String]) -> [(old: Range<Int>, new: Range<Int>)] {
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let ma = Array(a[head..<(a.count - tail)])
        let mb = Array(b[head..<(b.count - tail)])
        if ma.isEmpty && mb.isEmpty { return [] }
        if ma.count * mb.count > 4_000_000 { return [(head..<(head + ma.count), head..<(head + mb.count))] }
        let w = mb.count + 1
        var table = [Int](repeating: 0, count: (ma.count + 1) * w)
        for i in stride(from: ma.count - 1, through: 0, by: -1) {
            for j in stride(from: mb.count - 1, through: 0, by: -1) {
                table[i * w + j] = ma[i] == mb[j] ? table[(i + 1) * w + j + 1] + 1 : max(table[(i + 1) * w + j], table[i * w + j + 1])
            }
        }
        var hunks: [(old: Range<Int>, new: Range<Int>)] = []
        var i = 0
        var j = 0
        var open: (oldStart: Int, newStart: Int)?
        func close() {
            if let o = open { hunks.append((head + o.oldStart..<head + i, head + o.newStart..<head + j)); open = nil }
        }
        while i < ma.count || j < mb.count {
            if i < ma.count, j < mb.count, ma[i] == mb[j] {
                close()
                i += 1
                j += 1
            } else {
                if open == nil { open = (i, j) }
                if j >= mb.count || (i < ma.count && table[(i + 1) * w + j] >= table[i * w + j + 1]) { i += 1 } else { j += 1 }
            }
        }
        close()
        return hunks
    }

    // MARK: Markdown out

    /// The markdown the edit saves. Untouched blocks keep their source text; an edited block is
    /// written again from its characters.
    func markdown() -> String {
        let source = base.sourceText
        var perBlock = [[Unit]](repeating: [], count: base.blocks.count)
        for unit in units where unit.role != .blockEnd { perBlock[unit.block].append(unit) }

        var edits: [(range: Range<Int>, text: [UInt16])] = []
        for (index, block) in base.blocks.enumerated() {
            guard let range = block.source else { continue }
            let all = perBlock[index]
            guard all.contains(where: { $0.state != .kept }) else { continue }
            let live = all.filter { $0.state != .deleted }
            if let text = Self.blockMarkdown(block, live: live, links: base.links) {
                edits.append((range, Array(text.utf16)))
            } else {
                // The block lost all its text: take the line away with its line break.
                var end = range.upperBound
                if end + 1 < source.count, source[end] == 13, source[end + 1] == 10 { end += 2 }
                else if end < source.count, source[end] == 10 || source[end] == 13 { end += 1 }
                edits.append((range.lowerBound..<end, []))
            }
        }
        var result = source
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.text)
        }
        return String(decoding: result, as: UTF16.self)
    }

    /// The source text for one edited block, or `nil` when the block has no text left and goes
    /// away. A cell or a code block stays, empty.
    private static func blockMarkdown(_ block: RenderedMarkdown.Block, live: [Unit], links: [URL]) -> String? {
        switch block.kind {
        case .code:
            let text = String(decoding: live.filter { $0.role == .text }.map(\.u), as: UTF16.self)
            // A line the person typed must not close the fence.
            return text.components(separatedBy: "\n").map { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("```") ? "\u{200B}" + line : line
            }.joined(separator: "\n")
        case .tableCell:
            let cellUnits = live.filter { $0.role == .text && $0.u != 124 }.map { unit -> Unit in
                var flat = unit
                if flat.u == 10 { flat.u = 32 }
                return flat
            }
            return inlineMarkdown(cellUnits, links: links).trimmingCharacters(in: .whitespacesAndNewlines)
        case .heading, .paragraph, .listItem:
            var segments: [[Unit]] = [[]]
            for unit in live {
                switch unit.role {
                case .lineBreak: segments.append([])
                case .text: segments[segments.count - 1].append(unit)
                default: break
                }
            }
            let texts = segments
                .map { inlineMarkdown($0, links: links).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !texts.isEmpty else { return nil }
            switch block.kind {
            case .heading(let level):
                let first = String(repeating: "#", count: level) + " " + texts[0]
                return ([first] + texts.dropFirst()).joined(separator: "\n\n")
            case .listItem:
                if block.listMarker.hasSuffix("."), let start = Int(block.listMarker.dropLast()) {
                    return texts.enumerated().map { "\(start + $0.offset). \($0.element)" }.joined(separator: "\n")
                }
                let mark = block.listMarker.isEmpty ? "-" : block.listMarker
                return texts.map { "\(mark) \($0)" }.joined(separator: "\n")
            default:
                return texts.joined(separator: "\n\n")
            }
        }
    }

    // MARK: Inline

    private struct Run {
        var text: String
        var style: RenderedMarkdown.Style
        var link: Int
        /// The range of the run in the unit list.
        var start: Int
        var end: Int
    }

    /// Inline markdown for a run of text characters: bold, italics, strikethrough, inline code and
    /// links written from the characters' styles. Every other mark in the text is escaped.
    static func inlineMarkdown(_ units: [Unit], links: [URL]) -> String {
        var runs: [Run] = []
        var i = 0
        while i < units.count {
            var j = i + 1
            let style = units[i].style.subtracting(.marker)
            while j < units.count, units[j].style.subtracting(.marker) == style, units[j].link == units[i].link { j += 1 }
            runs.append(Run(
                text: String(decoding: units[i..<j].map(\.u), as: UTF16.self), style: style, link: units[i].link,
                start: i, end: j))
            i = j
        }
        let out = serialize(runs[...], level: 0, units: units, links: links)
        return escapeLineStart(out)
    }

    private static func key(_ level: Int, _ run: Run) -> Int {
        switch level {
        case 0: return run.link
        case 1: return run.style.contains(.strike) ? 1 : 0
        case 2: return run.style.contains(.bold) ? 1 : 0
        case 3: return run.style.contains(.italic) ? 1 : 0
        default: return run.style.contains(.code) ? 1 : 0
        }
    }

    private static func serialize(_ runs: ArraySlice<Run>, level: Int, units: [Unit], links: [URL]) -> String {
        if level == 5 { return runs.map { escape($0.text) }.joined() }
        var out = ""
        var i = runs.startIndex
        while i < runs.endIndex {
            let k = key(level, runs[i])
            var j = i + 1
            while j < runs.endIndex, key(level, runs[j]) == k { j += 1 }
            let group = runs[i..<j]
            let active = level == 0 ? k >= 0 && k < links.count : k == 1
            if !active {
                out += serialize(group, level: level + 1, units: units, links: links)
            } else if level == 0 {
                let inner = serialize(group, level: 1, units: units, links: links)
                let url = links[k].absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                out += inner.isEmpty ? "" : "[\(inner)](\(url))"
            } else if level == 4 {
                let text = group.map(\.text).joined()
                var longest = 0
                var current = 0
                for ch in text {
                    current = ch == "`" ? current + 1 : 0
                    longest = max(longest, current)
                }
                let fence = String(repeating: "`", count: longest + 1)
                out += text.trimmingCharacters(in: .whitespaces).isEmpty ? text : fence + text + fence
            } else {
                let inner = serialize(group, level: level + 1, units: units, links: links)
                let core = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if core.isEmpty {
                    out += inner
                } else {
                    let lead = String(inner.prefix(while: { $0.isWhitespace }))
                    let trail = String(inner.reversed().prefix(while: { $0.isWhitespace }).reversed())
                    let delimiter: String
                    switch level {
                    case 1: delimiter = "~~"
                    case 2: delimiter = "**"
                    default:
                        let before = group.first.map { $0.start > 0 && isAlnum(units[$0.start - 1].u) } ?? false
                        let after = group.last.map { $0.end < units.count && isAlnum(units[$0.end].u) } ?? false
                        delimiter = before || after ? "*" : "_"
                    }
                    out += lead + delimiter + core + delimiter + trail
                }
            }
            i = j
        }
        return out
    }

    private static func isAlnum(_ u: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(u) else { return false }
        return scalar.properties.isAlphabetic || (48...57).contains(u)
    }

    /// Every character that could start markdown syntax gets a backslash.
    private static let escaped: Set<Character> = ["\\", "`", "*", "_", "~", "[", "]", "(", ")", "<", ">", "!", "&", "|"]

    private static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            if escaped.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// A line that starts with "#", "-", "+" or "1." would turn into a heading or a list.
    private static func escapeLineStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        if first == "#" || first == "-" || first == "+" { return "\\" + text }
        if first.isNumber {
            let digits = text.prefix(while: { $0.isNumber })
            let rest = text.dropFirst(digits.count)
            if rest.hasPrefix(".") { return digits + "\\" + rest }
        }
        return text
    }
}
