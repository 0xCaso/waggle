import SwiftUI

/// Colours and type of the sources UI that the shared theme does not hold (values from the design file).
enum SourcesTheme {
    static let assumptionInk = Theme.AskDoc.Colors.variantOnText
    static let cardStroke = Theme.Colors.line2

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Theme.FontFamily.sans, size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Theme.FontFamily.mono, size: size).weight(weight)
    }

    /// Fill, stroke, icon and label of a pill. Selected (its card is pinned) is ink on ink.
    struct PillLook: Equatable {
        let fill: Color
        let stroke: Color
        let icon: Color
        let label: Color
    }

    static func pillLook(state: SourceState, selected: Bool) -> PillLook {
        if selected {
            return PillLook(fill: Theme.Colors.ink, stroke: Theme.Colors.ink, icon: .white, label: .white)
        }
        switch state {
        case .seen:
            return PillLook(fill: Theme.Colors.side, stroke: Theme.Colors.line, icon: Theme.Colors.ink3, label: Theme.Colors.ink2)
        case .stated:
            return PillLook(fill: .white, stroke: Theme.Colors.line, icon: Theme.Colors.ink3, label: Theme.Colors.ink2)
        case .assumption:
            return PillLook(fill: Theme.Colors.honeySoft, stroke: Theme.Colors.honey500, icon: assumptionInk, label: assumptionInk)
        }
    }

    /// An assumption always draws the dashed circle, whatever its kind.
    static func pillSymbol(for source: Source) -> String {
        source.state == .assumption ? SourceKind.none.symbol : source.drawnKind.symbol
    }
}

// MARK: - Pill

/// One pill beside its sentence. Hover shows the card, a click pins it.
struct SourcePillView: View {
    @ObservedObject var hub: SourcesHub
    let model: SourcePillModel
    let ids: [String]
    /// A pill inside a text view (WAG-357) gets its key from the text, and the text reports its place.
    var givenKey: String? = nil
    var reportsRect = true
    /// WAG-359: the click room around the shape (not drawn). A pill beside another gives up half the gap.
    var pads = PillHitArea.Pads.full
    /// False only to measure the shape alone.
    var hasHitArea = true

    @State private var ownKey = UUID().uuidString
    private var key: String { givenKey ?? ownKey }

    init(
        hub: SourcesHub, model: SourcePillModel, ids: [String], key: String? = nil, reportsRect: Bool = true,
        pads: PillHitArea.Pads = .full, hasHitArea: Bool = true
    ) {
        self.hub = hub
        self.model = model
        self.ids = ids
        self.givenKey = key
        self.reportsRect = reportsRect
        self.pads = pads
        self.hasHitArea = hasHitArea
    }

    var body: some View {
        let selected = hub.isPinned(key: key)
        let look = SourcesTheme.pillLook(state: model.state, selected: selected)
        HStack(spacing: 4) {
            Image(systemName: SourcesTheme.pillSymbol(for: model.first))
                .font(.system(size: 11))
                .foregroundColor(look.icon)
            Text(model.label)
                .font(SourcesTheme.sans(11.5, .medium))
                .foregroundColor(look.label)
                .lineLimit(1)
                .truncationMode(.tail)
            if let extra = model.extraText {
                Text(extra)
                    .font(SourcesTheme.sans(11.5, .medium))
                    .foregroundColor(look.label.opacity(0.6))
                    .fixedSize()
            }
        }
        .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 8))
        .background(Capsule().fill(look.fill))
        .overlay(Capsule().strokeBorder(look.stroke, lineWidth: 1))
        .frame(maxWidth: 260)
        .fixedSize(horizontal: true, vertical: false)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(SourcesHub.space)) }) {
            if reportsRect { hub.report(key: key, rect: $0, hit: PillHitArea.rect(visible: $0, pads: pads)) }
        }
        .padding(.leading, hasHitArea ? pads.leading : 0)
        .padding(.trailing, hasHitArea ? pads.trailing : 0)
        .frame(minHeight: hasHitArea ? PillHitArea.minHeight : 0)
        .contentShape(Rectangle())
        // The text around a pill is selectable; the pill itself never is.
        .textSelection(.disabled)
        .onHover { hub.pointerMoved(onPill: key, ids: ids, inside: $0) }
        .onTapGesture { hub.tap(key: key, ids: ids) }
        .pointerCursor()
        .onDisappear { if reportsRect { hub.forget(key: key) } }
        .task {
            // Evidence only: pin the card of the pill that cites this source.
            guard let open = hub.evidenceOpen, open == "pin:" + (ids.first ?? "") else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if hub.pinned == nil { hub.tap(key: key, ids: ids) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source: \(model.label)" + (model.extra > 0 ? ", and \(model.extra) more" : ""))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Text with pills

/// Lays out words and pills left to right and wraps them like text. A pill is centred on the middle of the
/// x-height of the words beside it (WAG-359), and never makes its row taller.
struct InlineFlowLayout: Layout {
    var wordGap: CGFloat = 4
    var pillGapBefore: CGFloat = 6
    var rowSpacing: CGFloat = 2
    /// The x-height of the text face, and the ascent and height of its line, for a row that holds only pills.
    var xHeight: CGFloat = 7
    var ascent: CGFloat = 13
    var lineHeight: CGFloat = 17

    /// Set on a pill: the click room that its view holds around the shape.
    struct PillPads: LayoutValueKey { static let defaultValue: PillHitArea.Pads? = nil }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, maxX: CGFloat = 0
        var rowStart = 0
        var rowBottoms: [CGFloat] = []
        func finishRow() {
            // The row sits on the lowest baseline of its words; a row of pills only uses the text face.
            var baseline: CGFloat?
            var bottom: CGFloat = 0
            for index in rowStart..<frames.count where subviews[index][PillPads.self] == nil {
                baseline = max(baseline ?? 0, subviews[index].dimensions(in: .unspecified)[.firstTextBaseline])
            }
            let line = baseline ?? ascent
            for index in rowStart..<frames.count {
                if subviews[index][PillPads.self] == nil {
                    let own = subviews[index].dimensions(in: .unspecified)[.firstTextBaseline]
                    frames[index].origin.y = y + line - own
                    bottom = max(bottom, line - own + frames[index].height)
                } else {
                    let centre = line - PillAlignment.centreAboveBaseline(xHeight: xHeight)
                    frames[index].origin.y = y + centre - frames[index].height / 2
                }
            }
            if baseline == nil { bottom = lineHeight }
            rowBottoms.append(bottom)
            rowStart = frames.count
        }
        for view in subviews {
            let pads = view[PillPads.self]
            var size = view.sizeThatFits(.unspecified)
            if let pads { size.width = min(size.width, width + pads.leading + pads.trailing) }
            let visible = size.width - (pads.map { $0.leading + $0.trailing } ?? 0)
            let gap = x == 0 ? 0 : (pads != nil ? pillGapBefore : wordGap)
            if x > 0, x + gap + visible > width {
                finishRow()
                y += (rowBottoms.last ?? 0) + rowSpacing
                x = 0
            }
            let origin = x == 0 ? 0 : x + gap
            // The view starts `leading` before the shape; the shape keeps its place.
            frames.append(CGRect(x: origin - (pads?.leading ?? 0), y: y, width: size.width, height: size.height))
            x = origin + visible
            maxX = max(maxX, x)
        }
        finishRow()
        return (frames, CGSize(width: maxX, height: y + (rowBottoms.last ?? 0)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = rows(subviews, width: bounds.width)
        for (view, frame) in zip(subviews, laid.frames) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

/// The pieces of a styled text: words, and the place of each marker.
enum InlineToken {
    case word(AttributedString)
    case marker(Int)

    static func tokens(_ text: AttributedString) -> [InlineToken] {
        var out: [InlineToken] = []
        var start: AttributedString.Index?
        var markers = 0
        let chars = text.characters
        var index = chars.startIndex
        func flush(_ end: AttributedString.Index) {
            if let begin = start { out.append(.word(AttributedString(text[begin..<end]))) }
            start = nil
        }
        while index < chars.endIndex {
            let character = chars[index]
            if character == SourceMarkers.placeholder {
                flush(index)
                out.append(.marker(markers))
                markers += 1
            } else if character.isWhitespace {
                flush(index)
            } else if start == nil {
                start = index
            }
            index = chars.index(after: index)
        }
        flush(chars.endIndex)
        return out
    }
}

/// A styled text whose markers are pills, wrapping with the words.
struct PillFlowText: View {
    @ObservedObject var hub: SourcesHub
    let text: AttributedString
    let groups: [[String]]
    let style: Theme.TextStyle
    let color: Color

    var body: some View {
        let gap = style.size * (style.lineHeight.map { $0 - 1 } ?? 0.25)
        let face = PromptBarLogic.sansFont(size: style.size)
        let tokens = InlineToken.tokens(text)
        // A pill that follows or precedes another pill shares the gap between them (WAG-359).
        let pillAt: [Bool] = tokens.map {
            if case .marker(let m) = $0 { return m < groups.count && hub.book.pill(ids: groups[m]) != nil }
            return false
        }
        InlineFlowLayout(
            wordGap: style.size * 0.27, rowSpacing: gap, xHeight: face.xHeight, ascent: face.ascender,
            lineHeight: face.ascender - face.descender + face.leading
        ) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { position, token in
                switch token {
                case .word(let word):
                    Text(word).font(style.font).tracking(style.letterSpacing ?? 0).foregroundColor(color).fixedSize()
                case .marker(let index):
                    if index < groups.count, let model = hub.book.pill(ids: groups[index]) {
                        let pads = PillHitArea.pads(
                            gapToPreviousPill: position > 0 && pillAt[position - 1] ? 6 : nil,
                            gapToNextPill: position + 1 < pillAt.count && pillAt[position + 1] ? 6 : nil)
                        SourcePillView(hub: hub, model: model, ids: groups[index], pads: pads)
                            .layoutValue(key: InlineFlowLayout.PillPads.self, value: pads)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// A one-line agent text on the request page (a note, a good point, a watch out, a step title). Its markers are
/// pills when the page has sources, else they are gone. `prefix` is a bold lead-in ("Why you:").
struct SourcedText: View {
    let text: String
    var prefix: String? = nil
    let style: Theme.TextStyle
    let color: Color
    /// WAG-357: where this text sits on the request page, when the person can comment on it. `nil` for text in an
    /// option row and for anything else that takes no comment.
    var target: AskCommentTarget? = nil
    var weight: NSFont.Weight = .regular
    var mode: AskTextContent.Mode = .line
    var mono = false
    @Environment(\.sourcesHub) private var hub
    @Environment(\.askComments) private var askHub

    var body: some View {
        if let target, let askHub {
            CommentableAskText(text: text, prefix: prefix, mode: mode, style: style, weight: weight, mono: mono, color: color, target: target, hub: askHub)
        } else if let hub, !hub.book.isEmpty, text.contains("[[s:"), let parsed = Self.resolvable(text, in: hub.book) {
            SourcedFlow(hub: hub, parsed: parsed, prefix: prefix, style: style, color: color)
        } else {
            let line = AgentMarkdown.singleLine(text)
            if let prefix {
                (Text(prefix + " ").fontWeight(.semibold) + Text(line)).knockTextStyle(style).foregroundColor(color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(line).knockTextStyle(style).foregroundColor(color).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func resolvable(_ text: String, in book: SourceBook) -> SourceMarkers.Parsed? { book.parsedWithPills(text) }
}

private struct SourcedFlow: View {
    let hub: SourcesHub
    let parsed: SourceMarkers.Parsed
    let prefix: String?
    let style: Theme.TextStyle
    let color: Color

    var body: some View {
        // The line is flat plain text: lists and markdown marks go, as in a queue row, but the markers stay.
        var line = AttributedString(AgentMarkdown.singleLine(parsed.text))
        line.font = style.font
        var lead = AttributedString()
        if let prefix {
            lead = AttributedString(prefix + " ")
            lead.font = style.font.weight(.semibold)
        }
        return PillFlowText(hub: hub, text: lead + line, groups: parsed.groups, style: style, color: color)
    }
}

// MARK: - Card

/// The card at a pill: what the source is, where it comes from and how sure Waggle is.
struct SourceCardView: View {
    @ObservedObject var hub: SourcesHub
    let anchor: SourcesHub.Anchor

    var body: some View {
        let sources = hub.book.pill(ids: anchor.ids)?.sources ?? []
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                if index > 0 { Rectangle().fill(Theme.Colors.line).frame(height: 1) }
                SourceDetailView(book: hub.book, source: source, boxFill: Theme.Colors.list, showsKindHead: true)
            }
            Rectangle().fill(Theme.Colors.line).frame(height: 1)
            HStack {
                Text(hub.isPinnedShown ? "Pinned. Click outside to close" : "Click the pill to keep this open")
                    .font(SourcesTheme.sans(11.5)).foregroundColor(Theme.Colors.ink3)
                Spacer(minLength: 8)
                Button { hub.openList(selecting: sources.first?.id) } label: {
                    Text("Show in Sources").font(SourcesTheme.sans(12, .semibold)).foregroundColor(Theme.Colors.ink)
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
        .padding(14)
        .frame(width: SourcesHub.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SourcesTheme.cardStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.13), radius: 12, x: 0, y: 8)
        .onHover { hub.pointerMoved(onCard: $0) }
        .accessibilityElement(children: .contain)
    }
}

/// The state mark: "Seen by Waggle" green with a check, "Stated by the agent" grey, "Not checked" honey.
struct SourceStateMark: View {
    let state: SourceState

    var body: some View {
        let fill: Color = state == .seen ? Theme.Colors.okSoft : state == .stated ? Theme.Colors.side : Theme.Colors.honeySoft
        let ink: Color = state == .seen ? Theme.Colors.ok : state == .stated ? Theme.Colors.ink3 : SourcesTheme.assumptionInk
        HStack(spacing: 4) {
            if state == .seen { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            Text(SourceBook.stateWord(state)).font(SourcesTheme.sans(10.5, .semibold))
        }
        .foregroundColor(ink)
        .padding(EdgeInsets(top: 2, leading: state == .seen ? 5 : 7, bottom: 2, trailing: 7))
        .background(Capsule().fill(fill))
        .fixedSize()
    }
}

/// The body of one source, in the card and in an open row of the list: title, excerpt, note, when line.
struct SourceDetailView: View {
    let book: SourceBook
    let source: Source
    /// The excerpt box fill: list grey in the card, white in an open row.
    let boxFill: Color
    /// The card names the kind and shows the state mark in its head; an open row does that in its own head.
    let showsKindHead: Bool

    /// WAG-357: the label, the excerpt and the note of one source are one plain text for a comment, in this order, a
    /// line break between them. Each view starts after the one before.
    static func bases(of source: Source) -> (excerpt: Int, note: Int) {
        let excerpt = source.label.utf16.count + 1
        let note = excerpt + (source.excerpt.map { $0.utf16.count + 1 } ?? 0)
        return (excerpt, note)
    }

    private func target(_ slot: String, base: Int) -> AskCommentTarget {
        AskCommentTarget(.source, sourceId: source.id, slot: slot + (showsKindHead ? "-card" : "-row"), baseOffset: base)
    }

    var body: some View {
        let bases = Self.bases(of: source)
        VStack(alignment: .leading, spacing: 9) {
            if showsKindHead {
                HStack(spacing: 6) {
                    Image(systemName: source.drawnKind.symbol).font(.system(size: 12)).foregroundColor(Theme.Colors.ink3)
                    Text(source.drawnKind.title.uppercased())
                        .font(SourcesTheme.mono(10.5, .semibold)).tracking(0.8).foregroundColor(Theme.Colors.ink3)
                    Spacer(minLength: 6)
                    SourceStateMark(state: source.state)
                }
                SourcedText(
                    text: source.label, style: Theme.TextStyle(font: SourcesTheme.sans(14, .semibold), size: 14, lineHeight: nil, letterSpacing: nil),
                    color: Theme.Colors.ink, target: target("label", base: 0), weight: .semibold, mode: .raw)
            }
            if let excerpt = source.excerpt, !excerpt.isEmpty {
                ExcerptBox(text: excerpt, fill: boxFill, target: target("excerpt", base: bases.excerpt))
            }
            if let note = source.note, !note.isEmpty {
                SourcedText(
                    text: note, style: Theme.TextStyle(font: SourcesTheme.sans(12.5), size: 12.5, lineHeight: 1.5, letterSpacing: nil),
                    color: Theme.Colors.ink2, target: target("note", base: bases.note))
            }
            if let link = SourceLink(source.ref?.url) {
                SourceLinkRow(link: link)
            }
            Text(book.whenLine(for: source)).font(SourcesTheme.sans(11.5)).foregroundColor(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }
}

/// WAG-407: the host of a source's web address and one action that opens it in the browser, on a click only.
struct SourceLinkRow: View {
    let link: SourceLink

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").font(.system(size: 11)).foregroundColor(Theme.Colors.ink3)
            Text(link.host).font(SourcesTheme.sans(12)).foregroundColor(Theme.Colors.ink2).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button { NSWorkspace.shared.open(link.url) } label: {
                Text("Open link").font(SourcesTheme.sans(12, .semibold)).foregroundColor(Theme.Colors.ink)
            }
            .buttonStyle(.plain).pointerCursor()
            .help(link.url.absoluteString)
            .accessibilityLabel("Open link to \(link.host)")
        }
    }
}

/// The quoted text of a source: mono 11, at most 6 lines, then it scrolls.
struct ExcerptBox: View {
    let text: String
    let fill: Color
    /// WAG-357: set when the person can comment on the excerpt.
    var target: AskCommentTarget? = nil
    static let lineHeight: CGFloat = 11 * 1.5
    static let maxLines = 6

    /// A rough count of the lines the text takes at the box width (about 46 mono characters a line).
    static func estimatedLines(_ text: String) -> Int {
        text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int((Double($1.count) / 46).rounded(.up))) }
    }

    var body: some View {
        let label = SourceExcerptText(text: text, target: target)
        Group {
            if Self.estimatedLines(text) > Self.maxLines {
                ScrollView(.vertical) { label.frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: Self.lineHeight * CGFloat(Self.maxLines))
            } else {
                label.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Colors.line, lineWidth: 1))
    }
}

// MARK: - Button

/// "Sources · 7" between the recommended block and the options. A round with no sources gets nothing.
struct SourcesButtonSlot: View {
    @Environment(\.sourcesHub) private var hub

    var body: some View {
        if let hub, SourcesLayout.showsButton(hub.book) {
            SourcesButton(hub: hub)
        }
    }
}

struct SourcesButton: View {
    @ObservedObject var hub: SourcesHub

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Button { hub.openList() } label: {
                HStack(spacing: 6) {
                    HStack(spacing: -4) {
                        ForEach(Array(hub.book.dotKinds.enumerated()), id: \.offset) { _, kind in
                            Image(systemName: kind.symbol)
                                .font(.system(size: 8))
                                .foregroundColor(Theme.Colors.ink2)
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(Color.white))
                                .overlay(Circle().strokeBorder(Theme.Colors.ink, lineWidth: 1))
                        }
                    }
                    Text(hub.book.buttonText).font(SourcesTheme.sans(11.5, .semibold)).foregroundColor(.white)
                }
                .padding(EdgeInsets(top: 4, leading: 5, bottom: 4, trailing: 10))
                .background(Capsule().fill(Theme.Colors.ink))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).pointerCursor()
            .accessibilityLabel("\(hub.book.buttonText). Open the list of sources.")
            Spacer(minLength: 0)
        }
    }
}

// MARK: - List

/// The Sources list at the right edge of the window: one row per source, the open one in place.
struct SourcesPanelView: View {
    @ObservedObject var hub: SourcesHub

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sources").font(SourcesTheme.sans(17, .semibold)).tracking(-0.3).foregroundColor(Theme.Colors.ink)
                Spacer()
                Button { hub.closeList() } label: {
                    Image(systemName: "xmark").font(.system(size: 15)).foregroundColor(Theme.Colors.ink3)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().accessibilityLabel("Close the list of sources")
            }
            Text(hub.book.summary).font(SourcesTheme.sans(11.5)).foregroundColor(Theme.Colors.ink3)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(hub.book.sources) { source in
                        SourceRowView(hub: hub, source: source, isOpen: hub.openRowId == source.id)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 22, leading: 20, bottom: 22, trailing: 20))
        .frame(width: SourcesHub.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.Colors.line).frame(width: 1) }
        .shadow(color: .black.opacity(0.12), radius: 14, x: -8, y: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
    }
}

struct SourceRowView: View {
    @ObservedObject var hub: SourcesHub
    let source: Source
    let isOpen: Bool

    private var noteLine: String? {
        source.note.flatMap { AgentMarkdown.singleLine($0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        let ink = source.state == .assumption ? SourcesTheme.assumptionInk : Theme.Colors.ink2
        VStack(alignment: .leading, spacing: 9) {
            Button { hub.toggleRow(source.id) } label: {
                HStack(spacing: 9) {
                    Image(systemName: SourcesTheme.pillSymbol(for: source)).font(.system(size: 13)).foregroundColor(ink)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.label).font(SourcesTheme.sans(13, .semibold)).foregroundColor(Theme.Colors.ink)
                            .lineLimit(isOpen ? nil : 1).multilineTextAlignment(.leading)
                        if let sub = isOpen ? source.drawnKind.title : noteLine {
                            Text(sub).font(SourcesTheme.sans(11.5)).foregroundColor(Theme.Colors.ink3).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    if isOpen {
                        SourceStateMark(state: source.state)
                    } else {
                        closedMark
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .accessibilityValue(isOpen ? "Open" : "Closed")
            if isOpen {
                SourceDetailView(book: hub.book, source: source, boxFill: .white, showsKindHead: false)
                    .padding(.leading, 25)
            }
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: isOpen ? 12 : 9, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(isOpen ? Theme.Colors.list : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isOpen ? Theme.Colors.ink : Color.clear, lineWidth: 1))
    }

    @ViewBuilder
    private var closedMark: some View {
        switch source.state {
        case .seen:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.Colors.ok)
        case .stated:
            Text("Stated").font(SourcesTheme.sans(10.5, .semibold)).foregroundColor(Theme.Colors.ink3)
        case .assumption:
            Text("Not checked").font(SourcesTheme.sans(10.5, .semibold)).foregroundColor(SourcesTheme.assumptionInk)
        }
    }
}

// MARK: - Host

/// Wraps the content of a request page: the card and the list draw over it, and a click that lands nowhere
/// useful closes them.
struct SourcesHost<Content: View>: View {
    @ObservedObject var hub: SourcesHub
    let content: Content
    @State private var cardSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(hub: SourcesHub, @ViewBuilder content: () -> Content) {
        self.hub = hub
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.sourcesHub, hub)
            .coordinateSpace(name: SourcesHub.space)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) {
                EvidenceLayoutLog.event("sourcesHostSize", "\($0.width)x\($0.height)")
                hub.setHostSize($0)
            }
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named(SourcesHub.space)).onEnded { hub.clickedOutside(at: $0.location) })
            .overlay(alignment: .topLeading) { card }
            .overlay(alignment: .trailing) {
                if hub.isListOpen {
                    SourcesPanelView(hub: hub)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 12)))
                }
            }
            .background {
                if hub.isOpen {
                    Button("Close sources") { hub.dismissTopmost() }
                        .keyboardShortcut(.escape, modifiers: []).opacity(0)
                }
            }
    }

    @ViewBuilder
    private var card: some View {
        if let anchor = hub.shown, hub.book.pill(ids: anchor.ids) != nil {
            let origin = SourcesCardPlace.origin(anchor: anchor.rect, card: cardSize, host: hub.hostSize)
            SourceCardView(hub: hub, anchor: anchor)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { cardSize = $0 }
                .offset(x: origin.x, y: origin.y)
                .onChange(of: origin) { _, new in hub.cardRect = CGRect(origin: new, size: cardSize) }
                .onAppear { hub.cardRect = CGRect(origin: origin, size: cardSize) }
                .transition(.opacity)
        }
    }
}

/// Where the card goes. Plain geometry, so a test can check it.
enum SourcesCardPlace {
    /// 8 px under the pill, left edges aligned, kept inside the window. It opens above the pill when there
    /// is no room under it.
    static func origin(anchor: CGRect, card: CGSize, host: CGSize) -> CGPoint {
        let width = card.width > 0 ? card.width : 340
        var x = anchor.minX
        if host.width > 0 { x = min(x, host.width - width - 8) }
        x = max(x, 8)
        var y = anchor.maxY + 8
        if host.height > 0, card.height > 0, y + card.height > host.height - 8 {
            y = max(8, anchor.minY - 8 - card.height)
        }
        return CGPoint(x: x, y: y)
    }
}

/// The quoted lines of a source: mono 11, line breaks kept. Commentable on the request page (WAG-357).
private struct SourceExcerptText: View {
    let text: String
    let target: AskCommentTarget?
    @Environment(\.askComments) private var askHub

    var body: some View {
        if let target, askHub != nil {
            SourcedText(
                text: text, style: Theme.TextStyle(font: SourcesTheme.mono(11), size: 11, lineHeight: 1.5, letterSpacing: nil),
                color: Theme.Colors.ink2, target: target, mode: .raw, mono: true)
        } else {
            Text(text).font(SourcesTheme.mono(11)).lineSpacing(11 * 0.5).foregroundColor(Theme.Colors.ink2)
        }
    }
}
