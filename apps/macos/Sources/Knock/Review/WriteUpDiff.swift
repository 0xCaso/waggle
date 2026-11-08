import Foundation

/// WAG-320: what changed between two versions of a write-up. Pure: no view, no file, no client.
/// The diff runs on the blocks `MarkdownDocument` parses (headings, paragraphs, list items, code,
/// table rows). A block that stayed is `unchanged`, a new one is `added`, a gone one is `removed`.
/// A block that is mostly the same text with a few words moved or changed is `changed`, and carries a
/// word-level diff. A block that appears in both versions at another place is `moved`.
enum WriteUpDiff {
    enum UnitKind: Equatable {
        case heading, paragraph, listItem, code, tableRow
    }

    /// One comparable block. A table gives one unit per row, the header row included.
    struct Unit: Equatable {
        let kind: UnitKind
        let level: Int
        let ordered: Bool
        let index: Int
        let text: String
        var isTableHeader = false

        /// What decides "same": the kind and the text. A list number or heading level alone is no change.
        fileprivate var key: String { "\(kind)|\(text)" }
    }

    enum Change: Equatable {
        case unchanged, added, removed, changed, moved
    }

    /// One run of words in a changed block.
    struct Segment: Equatable {
        enum Kind: Equatable { case same, added, removed }
        let kind: Kind
        let text: String
    }

    struct Entry: Equatable {
        let change: Change
        /// The new block, or the old one for `removed`.
        let unit: Unit
        /// Only for `changed`: the words, in order.
        let segments: [Segment]
    }

    enum SectionStatus: Equatable {
        case unchanged, changed, added, removed
    }

    /// The blocks under one heading (or before the first heading).
    struct Section: Equatable {
        let entries: [Entry]
        var status: SectionStatus {
            if entries.allSatisfy({ $0.change == .unchanged }) { return .unchanged }
            if entries.allSatisfy({ $0.change == .added }) { return .added }
            if entries.allSatisfy({ $0.change == .removed }) { return .removed }
            return .changed
        }
    }

    struct Result: Equatable {
        let sections: [Section]
        var isUnchanged: Bool { sections.allSatisfy { $0.status == .unchanged } }
        var changedCount: Int { sections.filter { $0.status == .changed }.count }
        var addedCount: Int { sections.filter { $0.status == .added }.count }
        var removedCount: Int { sections.filter { $0.status == .removed }.count }

        /// Every block of the new version in order, with the removed ones in place (WAG-321).
        var entries: [Entry] { sections.flatMap(\.entries) }

        /// "3 sections changed, 1 added", or "Nothing changed since v7."
        func summary(since base: Int) -> String {
            guard !isUnchanged else { return "Nothing changed since v\(base)." }
            var parts: [String] = []
            if changedCount > 0 { parts.append("\(changedCount) \(changedCount == 1 ? "section" : "sections") changed") }
            if addedCount > 0 { parts.append("\(addedCount) added") }
            if removedCount > 0 { parts.append("\(removedCount) removed") }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - Diff

    static func diff(old: String, new: String) -> Result {
        let entries = entries(old: units(of: old), new: units(of: new))
        return Result(sections: sections(of: entries))
    }

    static func units(of markdown: String) -> [Unit] {
        MarkdownDocument.parse(markdown).flatMap { block -> [Unit] in
            switch block {
            case .heading(let level, let text):
                return [Unit(kind: .heading, level: level, ordered: false, index: 0, text: text)]
            case .paragraph(let text):
                return [Unit(kind: .paragraph, level: 0, ordered: false, index: 0, text: text)]
            case .listItem(let ordered, let index, let text):
                return [Unit(kind: .listItem, level: 0, ordered: ordered, index: index, text: text)]
            case .codeBlock(let text):
                return [Unit(kind: .code, level: 0, ordered: false, index: 0, text: text)]
            case .table(let headers, let rows):
                let head = Unit(kind: .tableRow, level: 0, ordered: false, index: 0, text: headers.joined(separator: " | "), isTableHeader: true)
                return [head] + rows.map {
                    Unit(kind: .tableRow, level: 0, ordered: false, index: 0, text: $0.joined(separator: " | "))
                }
            }
        }
    }

    private enum Op {
        case keep(Unit), remove(Unit), add(Unit), moved(Unit)
    }

    private static func entries(old: [Unit], new: [Unit]) -> [Entry] {
        var ops = lcsOps(old: old, new: new)
        // A block that left one place and came back at another is a move, not a remove plus an add.
        var removedByKey: [String: [Int]] = [:]
        for (i, op) in ops.enumerated() { if case .remove(let u) = op { removedByKey[u.key, default: []].append(i) } }
        var dropped = Set<Int>()
        for (i, op) in ops.enumerated() {
            guard case .add(let u) = op, var list = removedByKey[u.key], !list.isEmpty else { continue }
            dropped.insert(list.removeFirst())
            removedByKey[u.key] = list
            ops[i] = .moved(u)
        }
        let live = ops.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)

        var out: [Entry] = []
        var removes: [Unit] = []
        var adds: [Unit] = []
        func flushRun() {
            guard !removes.isEmpty || !adds.isEmpty else { return }
            // Pair each added block with a similar removed one, in order.
            var matches: [Int?] = []
            var pointer = 0
            for added in adds {
                if let hit = (pointer..<removes.count).first(where: { similar(removes[$0], added) }) {
                    matches.append(hit)
                    pointer = hit + 1
                } else {
                    matches.append(nil)
                }
            }
            pointer = 0
            for (k, added) in adds.enumerated() {
                if let hit = matches[k] {
                    for skipped in removes[pointer..<hit] { out.append(Entry(change: .removed, unit: skipped, segments: [])) }
                    out.append(Entry(change: .changed, unit: added, segments: words(old: removes[hit].text, new: added.text)))
                    pointer = hit + 1
                } else {
                    let limit = matches[(k + 1)...].compactMap { $0 }.first ?? removes.count
                    for skipped in removes[pointer..<limit] { out.append(Entry(change: .removed, unit: skipped, segments: [])) }
                    pointer = limit
                    out.append(Entry(change: .added, unit: added, segments: []))
                }
            }
            for rest in removes[pointer...] { out.append(Entry(change: .removed, unit: rest, segments: [])) }
            removes = []
            adds = []
        }
        for op in live {
            switch op {
            case .remove(let u): removes.append(u)
            case .add(let u): adds.append(u)
            case .keep(let u):
                flushRun()
                out.append(Entry(change: .unchanged, unit: u, segments: []))
            case .moved(let u):
                flushRun()
                out.append(Entry(change: .moved, unit: u, segments: []))
            }
        }
        flushRun()
        return out
    }

    private static func sections(of entries: [Entry]) -> [Section] {
        var result: [Section] = []
        var current: [Entry] = []
        for entry in entries {
            if entry.unit.kind == .heading, !current.isEmpty {
                result.append(Section(entries: current))
                current = []
            }
            current.append(entry)
        }
        if !current.isEmpty { result.append(Section(entries: current)) }
        return result
    }

    private static func lcsOps(old: [Unit], new: [Unit]) -> [Op] {
        let n = old.count, m = new.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = old[i].key == new[j].key ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, old[i].key == new[j].key {
                ops.append(.keep(new[j])); i += 1; j += 1
            } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                ops.append(.add(new[j])); j += 1
            } else {
                ops.append(.remove(old[i])); i += 1
            }
        }
        return ops
    }

    /// The same kind of block, and most of the shorter text is in the longer one (an added clause still counts).
    private static func similar(_ a: Unit, _ b: Unit) -> Bool {
        guard a.kind == b.kind else { return false }
        func bag(_ text: String) -> Set<String> {
            Set(text.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty })
        }
        let x = bag(a.text), y = bag(b.text)
        let shared = x.intersection(y).count
        guard shared >= 2 else { return false }
        return Double(shared) / Double(min(x.count, y.count)) >= 0.6
    }

    /// Words and punctuation marks, each with the spaces that follow it, so the pieces join back to the text.
    private static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSpace = false
        for ch in text {
            if ch == " " {
                current.append(ch); inSpace = true
            } else if ch.isPunctuation || ch.isSymbol {
                if !current.isEmpty { out.append(current) }
                current = String(ch); inSpace = false
            } else {
                if inSpace || (current.last.map { $0.isPunctuation || $0.isSymbol } ?? false) { out.append(current); current = "" }
                current.append(ch); inSpace = false
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Word-level diff of one changed block. Runs of the same kind merge into one segment, and the
    /// segments joined without the removed ones give the new text.
    static func words(old: String, new: String) -> [Segment] {
        let a = tokens(old), b = tokens(new)
        func same(_ x: String, _ y: String) -> Bool { x.trimmingCharacters(in: .whitespaces) == y.trimmingCharacters(in: .whitespaces) }
        let n = a.count, m = b.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = same(a[i], b[j]) ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var raw: [(Segment.Kind, String)] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, same(a[i], b[j]) {
                raw.append((.same, b[j])); i += 1; j += 1
            } else if i < n, j == m || table[i + 1][j] >= table[i][j + 1] {
                raw.append((.removed, a[i])); i += 1
            } else {
                raw.append((.added, b[j])); j += 1
            }
        }
        var out: [Segment] = []
        for (kind, text) in raw {
            if let last = out.last, last.kind == kind {
                out[out.count - 1] = Segment(kind: kind, text: last.text + text)
            } else {
                out.append(Segment(kind: kind, text: text))
            }
        }
        return out
    }
}
