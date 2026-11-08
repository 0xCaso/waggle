import Foundation

/// WAG-322: the new version's `RenderedMarkdown` with the changes since an older version marked in place, so the
/// commentable text view can show them and still map every selection to the new source.
///
/// Added words get `.added`. Removed words and removed blocks are inserted as extra characters with source `-1` and
/// `.removed`, so a selection over them anchors to the new text only, and a selection of only removed text holds no
/// source text and gives no comment. Changed and added blocks get `marked` for the honey bar.
extension RenderedMarkdown {
    private struct Splice {
        let at: Int
        let chars: [UInt16]
        let styles: [Style]
        let entry: Int
        /// A whole removed block, with its own newline. Otherwise the chars sit inside a block.
        let isBlock: Bool
    }

    func markingChanges(_ result: WriteUpDiff.Result) -> RenderedMarkdown {
        let entries = result.entries
        // Each new-version entry owns the blocks it renders to (a table row is one block per cell).
        var groups: [Int: Range<Int>] = [:]
        var b = 0
        for (e, entry) in entries.enumerated() where entry.change != .removed {
            guard b < blocks.count else { return self }
            if entry.unit.kind == .tableRow {
                guard case .tableCell(let row, _, _, _, _) = blocks[b].kind else { return self }
                var end = b
                while end < blocks.count, case .tableCell(let r, _, _, _, _) = blocks[end].kind, r == row { end += 1 }
                groups[e] = b..<end
                b = end
            } else {
                guard Self.kind(blocks[b].kind, matches: entry.unit.kind) else { return self }
                groups[e] = b..<(b + 1)
                b += 1
            }
        }
        guard b == blocks.count else { return self }

        var out = self
        var splices: [Splice] = []
        for (e, entry) in entries.enumerated() {
            guard let group = groups[e] else { continue }
            for i in group { out.blocks[i].entry = e }
            guard entry.change != .unchanged else { continue }
            for i in group { out.blocks[i].marked = true }
            guard group.count == 1, [.paragraph, .listItem, .heading].contains(entry.unit.kind) else { continue }
            let block = blocks[group.lowerBound]
            var start = block.range.lowerBound
            while start < block.range.upperBound, styles[start].contains(.marker) { start += 1 }
            let end = text[block.range.upperBound - 1] == 10 ? block.range.upperBound - 1 : block.range.upperBound
            if entry.change == .added {
                if entry.unit.kind != .heading { for i in start..<end { out.styles[i].insert(.added) } }
            } else if entry.change == .changed {
                markWords(entry, contentStart: start, contentEnd: end, into: &out, splices: &splices, entry: e)
            }
        }
        // A removed block goes before the next block of the new version, or at the end (after a newline that ends
        // the last block, added once).
        let endsOpen = entries.enumerated().contains { e, entry in
            entry.change == .removed && !((e + 1)..<entries.count).contains { groups[$0] != nil }
        }
        if endsOpen, let last = out.blocks.indices.last {
            out.text.append(10); out.source.append(-1); out.styles.append([]); out.linkIndex.append(-1)
            out.blocks[last] = out.blocks[last].extended(by: 1)
        }
        for (e, entry) in entries.enumerated() where entry.change == .removed {
            let next = ((e + 1)..<entries.count).first { groups[$0] != nil }
            let at = next.flatMap { groups[$0] }.map { blocks[$0.lowerBound].range.lowerBound } ?? out.text.count
            let chars = Array(entry.unit.text.utf16)
            splices.append(Splice(at: at, chars: chars, styles: [Style](repeating: .removed, count: chars.count), entry: e, isBlock: true))
        }
        // Back to front, so the places not yet used stay right. Equal places: the later one first.
        let order = splices.enumerated().sorted { $0.element.at != $1.element.at ? $0.element.at > $1.element.at : $0.element.entry != $1.element.entry ? $0.element.entry > $1.element.entry : $0.offset > $1.offset }
        for (_, splice) in order { out.insert(splice) }
        return out
    }

    private static func kind(_ block: BlockKind, matches unit: WriteUpDiff.UnitKind) -> Bool {
        switch (block, unit) {
        case (.heading, .heading), (.paragraph, .paragraph), (.listItem, .listItem), (.code, .code): return true
        default: return false
        }
    }

    /// Marks the added words of a changed block and queues the removed words. Skips the block (the bar still
    /// shows) when the unit text and the rendered block text differ, so a mark never lands on the wrong word.
    private func markWords(_ entry: WriteUpDiff.Entry, contentStart: Int, contentEnd: Int, into out: inout RenderedMarkdown,
                           splices: inout [Splice], entry e: Int) {
        let unit = RenderedMarkdown.parse(entry.unit.text)
        guard Array(text[contentStart..<contentEnd]) == unit.text else { return }
        var offset = 0
        for segment in entry.segments {
            let length = segment.text.utf16.count
            switch segment.kind {
            case .same:
                break
            case .added:
                let kept = segment.text.utf16.count - segment.text.reversed().prefix { $0 == " " }.count
                if kept > 0, let r = unit.renderedRange(forSource: offset..<(offset + kept)) {
                    for i in r { out.styles[contentStart + i].insert(.added) }
                }
            case .removed:
                let local = unit.source.firstIndex { $0 >= offset } ?? unit.text.count
                let chars = Array(segment.text.utf16)
                let trailing = segment.text.reversed().prefix { $0 == " " }.count
                let styles = (0..<chars.count).map { $0 < chars.count - trailing ? Style.removed : [] }
                splices.append(Splice(at: contentStart + local, chars: chars, styles: styles, entry: e, isBlock: false))
            }
            if segment.kind != .removed { offset += length }
        }
    }

    private mutating func insert(_ splice: Splice) {
        var chars = splice.chars
        var styles = splice.styles
        if splice.isBlock {
            chars.append(10)
            styles.append([])
        }
        let at = splice.at
        let n = chars.count
        let index = blocks.firstIndex { $0.range.lowerBound >= at } ?? blocks.count
        text.insert(contentsOf: chars, at: at)
        source.insert(contentsOf: [Int](repeating: -1, count: n), at: at)
        self.styles.insert(contentsOf: styles, at: at)
        linkIndex.insert(contentsOf: [Int](repeating: -1, count: n), at: at)
        for i in blocks.indices {
            let r = blocks[i].range
            if r.lowerBound > at || (splice.isBlock && r.lowerBound == at) {
                blocks[i] = blocks[i].moved(by: n)
            } else if r.upperBound > at {
                blocks[i] = blocks[i].extended(by: n)
            }
        }
        if splice.isBlock {
            var block = Block(range: at..<(at + n), kind: .paragraph)
            block.marked = true
            block.entry = splice.entry
            blocks.insert(block, at: index)
        }
    }
}

private extension RenderedMarkdown.Block {
    func moved(by n: Int) -> RenderedMarkdown.Block {
        RenderedMarkdown.Block(range: (range.lowerBound + n)..<(range.upperBound + n), kind: kind, source: source, listMarker: listMarker, marked: marked, entry: entry)
    }

    func extended(by n: Int) -> RenderedMarkdown.Block {
        RenderedMarkdown.Block(range: range.lowerBound..<(range.upperBound + n), kind: kind, source: source, listMarker: listMarker, marked: marked, entry: entry)
    }
}
