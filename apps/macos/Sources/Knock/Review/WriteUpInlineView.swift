import SwiftUI

/// WAG-321: one word of a block in the inline view: plain, added or removed.
struct WriteUpWordRun: Equatable {
    enum Kind: Equatable { case plain, added, removed }
    let text: String
    let kind: Kind
    /// No space before this word: it follows the one before without a gap (a full stop after a word).
    let glued: Bool
    /// The word before (after) is marked the same way: the highlight runs on without a break.
    var joinsPrev = false
    var joinsNext = false
    /// The word after has no space before it.
    var gluedNext = false

    /// The words of a block, in reading order. In a changed block each removed word comes right before the
    /// words that replace it. An added block is all added words, a removed block all removed words.
    static func runs(for entry: WriteUpDiff.Entry) -> [WriteUpWordRun] {
        let segments: [WriteUpDiff.Segment]
        switch entry.change {
        case .changed: segments = entry.segments
        case .added: segments = [WriteUpDiff.Segment(kind: .added, text: entry.unit.text)]
        case .removed: segments = [WriteUpDiff.Segment(kind: .removed, text: entry.unit.text)]
        case .unchanged, .moved: segments = [WriteUpDiff.Segment(kind: .same, text: entry.unit.text)]
        }
        var out: [WriteUpWordRun] = []
        var previousEndsWithSpace = true
        for segment in segments {
            let kind: Kind = segment.kind == .added ? .added : (segment.kind == .removed ? .removed : .plain)
            var spaceBefore = previousEndsWithSpace || segment.text.first == " "
            for word in segment.text.split(separator: " ") {
                out.append(WriteUpWordRun(text: String(word), kind: kind, glued: !spaceBefore))
                spaceBefore = true
            }
            if !segment.text.isEmpty { previousEndsWithSpace = segment.text.last == " " }
        }
        for i in out.indices where out[i].kind != .plain {
            if i > 0, out[i - 1].kind == out[i].kind { out[i].joinsPrev = true }
            if i + 1 < out.count, out[i + 1].kind == out[i].kind { out[i].joinsNext = true }
        }
        for i in out.indices where i + 1 < out.count {
            out[i].gluedNext = out[i + 1].glued
        }
        return out
    }
}

private struct GluedKey: LayoutValueKey { static let defaultValue = false }

/// Words left to right, wrapping at the width, so each highlighted word can be its own rounded chip.
private struct WordFlowLayout: Layout {
    var gap: CGFloat = 3
    var lineGap: CGFloat = 2

    private struct Placed { var origin: CGPoint; var size: CGSize }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [Placed], size: CGSize) {
        var frames: [Placed] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let space = subview[GluedKey.self] || x == 0 ? 0 : gap
            if x > 0, x + space + size.width > width {
                y += lineHeight + lineGap; x = 0; lineHeight = 0
            }
            let start = x == 0 ? 0 : x + space
            frames.append(Placed(origin: CGPoint(x: start, y: y), size: size))
            x = start + size.width
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x)
        }
        return (frames, CGSize(width: widest, height: y + lineHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(subviews, width: bounds.width)
        for (subview, placed) in zip(subviews, laid.frames) {
            subview.place(at: CGPoint(x: bounds.minX + placed.origin.x, y: bounds.minY + placed.origin.y), proposal: ProposedViewSize(placed.size))
        }
    }
}

/// The new version in full with each change marked in place. Plain ink for what stayed. A changed or added
/// block has a honey bar on its left; inside it removed words are watch on watchSoft and added words ok on okSoft.
struct WriteUpInlineBody: View {
    @ObservedObject var model: WriteUpChangesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result = model.result {
                ForEach(Array(result.entries.enumerated()), id: \.offset) { index, entry in
                    WriteUpInlineEntry(entry: entry, index: index, model: model).id(index)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The inline body, with the scrolling the up and down buttons ask for. `scrolls` off leaves it to a scroll
/// view the page already has.
struct WriteUpInlineView: View {
    @ObservedObject var model: WriteUpChangesModel
    let insets: EdgeInsets
    var scrolls = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if scrolls {
                    ScrollView { WriteUpInlineBody(model: model).padding(insets) }
                } else {
                    WriteUpInlineBody(model: model).padding(insets)
                }
            }
            .onChange(of: model.scrollRequest) { _, request in
                guard let request else { return }
                if reduceMotion {
                    proxy.scrollTo(request.entry, anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(request.entry, anchor: .top) }
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(120))
                model.openAtFirstChangeIfNeeded()
            }
        }
    }
}

/// WAG-322: the inline changes view inside the commentable text, so select-to-comment works as on the plain
/// write-up. The scrolling, the honey bars and the flash come from the same model as the read-only view.
struct WriteUpCommentableInlineView: View {
    @ObservedObject var model: WriteUpChangesModel
    let markdown: String
    let revision: Int
    @ObservedObject var store: CommentsSessionStore
    var extraComments: [Comment] = []
    var canComment = true
    var onSelectComment: (String) -> Void = { _ in }

    var body: some View {
        CommentableMarkdownView(
            markdown: markdown, revision: revision, store: store, extraComments: extraComments, canComment: canComment,
            onSelectComment: onSelectComment, changes: model.result,
            scrollRequest: model.scrollRequest, flashRequest: model.flashRequest
        )
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            model.openAtFirstChangeIfNeeded()
        }
    }
}

/// One block. The text column keeps its place whether or not the bar shows.
private struct WriteUpInlineEntry: View {
    let entry: WriteUpDiff.Entry
    let index: Int
    @ObservedObject var model: WriteUpChangesModel
    @State private var flashing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(entry.change == .unchanged ? Color.clear : Theme.Colors.honey500)
                .frame(width: 3)
                .cornerRadius(1.5)
            VStack(alignment: .leading, spacing: 2) {
                if entry.change == .moved {
                    Text("MOVED").knockTextStyle(Theme.Typography.labelCaps10_5w600).foregroundColor(Theme.Colors.ink3)
                }
                line
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.honeySoft).opacity(flashing ? 1 : 0))
        .onChange(of: model.flashRequest) { _, request in
            guard !reduceMotion, let request, request.entry == index else { return }
            flashing = true
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.6)) { flashing = false } }
        }
    }

    private var style: Theme.TextStyle {
        let unit = entry.unit
        switch unit.kind {
        case .heading:
            switch unit.level {
            case 1: return Theme.Typography.cardTitle15w650
            case 2: return Theme.Typography.rowTitle13_5w600
            default: return Theme.Typography.buttonSm12_5w600
            }
        case .code: return Theme.Typography.monoMeta12w400
        case .tableRow: return unit.isTableHeader ? Theme.Typography.buttonSm12_5w600 : Theme.Typography.body12_5w400
        default: return Theme.Typography.body13w400
        }
    }

    private var line: some View {
        HStack(alignment: .top, spacing: 8) {
            if entry.unit.kind == .listItem {
                Text(entry.unit.ordered ? "\(entry.unit.index)." : "•")
                    .knockTextStyle(Theme.Typography.body13w400).foregroundColor(Theme.Colors.ink3)
                    .frame(minWidth: 14, alignment: .trailing)
            }
            switch entry.change {
            case .unchanged, .moved:
                Text(plain).knockTextStyle(style).foregroundColor(Theme.Colors.ink)
            case .removed:
                Text(entry.unit.text)
                    .knockTextStyle(style)
                    .foregroundColor(Theme.AskDoc.Colors.watch)
                    .padding(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.AskDoc.Colors.watchSoft))
            case .changed, .added:
                WordFlowLayout {
                    ForEach(Array(WriteUpWordRun.runs(for: entry).enumerated()), id: \.offset) { _, run in
                        word(run).layoutValue(key: GluedKey.self, value: run.glued || (run.joinsPrev && isMarked(run)))
                    }
                }
            }
        }
    }

    private var plain: AttributedString {
        entry.unit.kind == .code || entry.unit.kind == .tableRow
            ? AttributedString(entry.unit.text) : MarkdownDocument.inline(entry.unit.text)
    }

    /// A new section's heading keeps plain ink: the bar marks it, the words under it carry the green.
    private func isMarked(_ run: WriteUpWordRun) -> Bool {
        run.kind != .plain && !(entry.change == .added && entry.unit.kind == .heading)
    }

    @ViewBuilder
    private func word(_ run: WriteUpWordRun) -> some View {
        if !isMarked(run) {
            Text(run.text).knockTextStyle(style).foregroundColor(Theme.Colors.ink)
        } else {
            let removed = run.kind == .removed
            Text(run.text).knockTextStyle(style)
                .foregroundColor(removed ? Theme.AskDoc.Colors.watch : Theme.Colors.ok)
                .padding(EdgeInsets(top: 0, leading: run.glued ? 0 : (run.joinsPrev ? 1.5 : 3), bottom: 0, trailing: run.gluedNext ? 0 : (run.joinsNext ? 1.5 : 3)))
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: run.joinsPrev ? 0 : 4, bottomLeadingRadius: run.joinsPrev ? 0 : 4,
                        bottomTrailingRadius: run.joinsNext ? 0 : 4, topTrailingRadius: run.joinsNext ? 0 : 4)
                    .fill(removed ? Theme.AskDoc.Colors.watchSoft : Theme.Colors.okSoft))
        }
    }
}

/// "3 changes since v7" with the previous and next buttons, for the header of a write-up. Nothing shows
/// without changes.
struct WriteUpChangesControls: View {
    @ObservedObject var hub: WriteUpChangesHub

    var body: some View {
        if let model = hub.active {
            Inner(model: model)
        }
    }

    private struct Inner: View {
        @ObservedObject var model: WriteUpChangesModel

        var body: some View {
            if model.hasChanges {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { model.isOn }, set: { model.setShowChanges($0) })) {
                        Text("Show changes")
                            .knockTextStyle(Theme.AskDoc.Chrome.smallButton)
                            .foregroundColor(Theme.Colors.ink)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .pointerCursor()
                    .accessibilityLabel("Show changes")
                    if let title = model.countTitle {
                        Text(title)
                            .knockTextStyle(Theme.AskDoc.Chrome.smallButton)
                            .foregroundColor(Theme.Colors.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                        button("chevron.up", help: "Previous change") { model.previous() }
                        button("chevron.down", help: "Next change") { model.next() }
                    }
                }
            }
        }

        private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Colors.ink2)
                    .frame(width: 24, height: 24)
                    .background(Theme.Colors.win)
                    .cornerRadius(Theme.AskDoc.Chrome.smallButtonRadius)
                    .overlay(RoundedRectangle(cornerRadius: Theme.AskDoc.Chrome.smallButtonRadius).stroke(Theme.Colors.line2, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(help)
            .accessibilityLabel(help)
        }
    }
}
