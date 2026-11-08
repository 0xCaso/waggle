import SwiftUI

/// The quick replies of the chip row (WAG-411): one click sends the words as the reply.
enum QuickReply: CaseIterable, Identifiable {
    case letsDiscuss, lookAtMyComments, showMeMore

    var label: String {
        switch self {
        case .letsDiscuss: return "Let's discuss"
        case .lookAtMyComments: return "Look at my comments"
        case .showMeMore: return "Show me more"
        }
    }

    var id: String { label }

    /// What the agent reads. "Look at my comments" also asks it to act on each one.
    var text: String {
        switch self {
        case .lookAtMyComments: return "Look at my comments and act on each one."
        default: return label
        }
    }

    /// The word in the usage log: a code, never the text.
    var usageName: String {
        switch self {
        case .letsDiscuss: return "lets_discuss"
        case .lookAtMyComments: return "my_comments"
        case .showMeMore: return "show_more"
        }
    }

    /// The chips to show, in order. "Look at my comments" shows only when comments are pinned.
    static func visible(hasComments: Bool) -> [QuickReply] {
        allCases.filter { $0 != .lookAtMyComments || hasComments }
    }

    /// The reply text: a typed draft stays and the quick reply follows it on a new line.
    static func message(draft: String?, reply: QuickReply) -> String {
        let typed = draft?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return typed.isEmpty ? reply.text : "\(typed)\n\(reply.text)"
    }

    @MainActor
    func report() {
        UsageReporter.current?.record(.quickReplyPicked, variantName: usageName)
    }
}

/// The chip row right above the input (WAG-411, was the "Ask for" row of HAIL-111 and WAG-367): the quick
/// replies, a divider, one chip for each quick ask, then "…". A chip sends on one click. "…" opens the full
/// panel. Every chip is in the row. When they do not fit, the row scrolls sideways, with a fade on the side
/// that has more. `onQuickReply` is nil where a plain reply makes no sense: then the row has no quick replies.
struct AskForDetailRowView: View {
    @ObservedObject var composer: ComposerViewModel
    let onSend: () -> Void
    let onSendFormat: (ReplyFormat) -> Void
    var onQuickReply: ((QuickReply) -> Void)? = nil
    /// True when comments are pinned: then "Look at my comments" shows.
    var hasComments = false

    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private static let dots = "…"
    private static let space = "chipRow"

    var body: some View {
        let fades = ChipRowEdges.fades(offset: offset, content: contentWidth, container: containerWidth)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let onQuickReply {
                    ForEach(QuickReply.visible(hasComments: hasComments || ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_QUICK_COMMENTS"] == "1")) { reply in
                        Button(reply.label) { onQuickReply(reply) }
                            .buttonStyle(DetailPillStyle(isQuick: true))
                            .accessibilityLabel(reply.label)
                    }
                    Rectangle().fill(Theme.Colors.line).frame(width: 1, height: 16).padding(.horizontal, 2)
                }
                ForEach(DetailPill.all) { pill in
                    Button(pill.label) { send(pill) }
                        .buttonStyle(DetailPillStyle())
                        .accessibilityLabel("Ask for \(pill.label)")
                }
                Button(Self.dots) { composer.beginAskingForDetail(fromDots: true) }
                    .buttonStyle(DetailPillStyle())
                    .accessibilityLabel("More ways to ask")
                    .help("More ways to ask")
            }
            .padding(.horizontal, 14)
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ChipRowMetrics.self, value: ChipRowMetrics.Value(
                        offset: -proxy.frame(in: .named(Self.space)).minX, content: proxy.size.width))
                })
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(ChipRowMetrics.self) { metrics in
            if offset != metrics.offset { offset = metrics.offset }
            if contentWidth != metrics.content { contentWidth = metrics.content }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { if containerWidth != $0 { containerWidth = $0 } }
        .mask(
            HStack(spacing: 0) {
                edge(leading: true, fades: fades.leading)
                Rectangle()
                edge(leading: false, fades: fades.trailing)
            })
        .animation(.easeOut(duration: 0.15), value: fades.leading)
        .animation(.easeOut(duration: 0.15), value: fades.trailing)
        .frame(height: 28)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One end of the mask: a soft edge (clear at the border) when the row has more that way, else solid.
    private func edge(leading: Bool, fades: Bool) -> some View {
        LinearGradient(
            colors: [.black.opacity(fades ? 0 : 1), .black], startPoint: leading ? .leading : .trailing,
            endPoint: leading ? .trailing : .leading)
            .frame(width: 28)
    }

    private func send(_ pill: DetailPill) {
        switch pill.pick {
        case .quick(let index):
            composer.fillDetailChip(ComposerViewModel.detailChips[index])
            DetailPill.report(format: "none", pick: ComposerViewModel.detailChipUsageNames[index], fromRow: true)
            onSend()
        case .ask(let text, let usage):
            composer.fillDetailChip(text)
            DetailPill.report(format: "none", pick: usage, fromRow: true)
            onSend()
        case .format(let format):
            DetailPill.report(format: format.rawValue, pick: nil, fromRow: true)
            onSendFormat(format)
        }
    }
}

/// Where the chip row has more to show (WAG-411): a fade on that side only.
enum ChipRowEdges {
    static func fades(offset: CGFloat, content: CGFloat, container: CGFloat) -> (leading: Bool, trailing: Bool) {
        guard container > 0, content > container + 1 else { return (false, false) }
        return (offset > 2, offset + container < content - 2)
    }
}

/// The scroll offset and the content width of the chip row, read from its content.
struct ChipRowMetrics: PreferenceKey {
    struct Value: Equatable { var offset: CGFloat = 0; var content: CGFloat = 0 }
    static let defaultValue = Value()
    static func reduce(value: inout Value, nextValue: () -> Value) { value = nextValue() }
}

/// One pill of the "Ask for" row (WAG-367): the words name what comes back.
struct DetailPill: Identifiable {
    enum Pick: Equatable {
        /// The index of the quick ask in `ComposerViewModel.detailChips`.
        case quick(Int)
        /// A request that only the row has: its text and its word in the usage log.
        case ask(String, usage: String)
        case format(ReplyFormat)
    }

    let label: String
    let pick: Pick
    var id: String { label }

    static let all: [DetailPill] = [
        DetailPill(label: "how it works", pick: .quick(0)),
        DetailPill(label: "the trade-offs", pick: .quick(1)),
        DetailPill(label: "a prototype", pick: .quick(2)),
        DetailPill(label: "screenshots", pick: .ask("Show me screenshots", usage: "screenshots")),
        DetailPill(label: "the numbers", pick: .quick(3)),
        DetailPill(label: "an example", pick: .quick(4)),
        DetailPill(label: "a diagram", pick: .format(.diagram)),
    ]

    /// What sent the detail request (WAG-366): a closed word, never the text. `fromRow` marks a pill of
    /// the row (WAG-367), so the report can tell it from a row of the panel.
    @MainActor
    static func report(format: String, pick: String?, fromRow: Bool = false) {
        UsageReporter.current?.record(
            UsageRecord(.detailFormatPicked, variantName: pick, format: format, n: fromRow ? 1 : nil))
    }
}

/// A small outline pill: white, a soft fill on hover, a short press.
struct DetailPillStyle: ButtonStyle {
    /// A quick reply: honey soft instead of white (WAG-411).
    var isQuick = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, isQuick: isQuick)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let isQuick: Bool
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private func fill(active: Bool) -> Color {
            if isQuick { return active ? Theme.Colors.honey300.opacity(0.4) : Theme.Colors.honeySoft }
            return active ? Theme.Colors.hover : Color.white
        }

        var body: some View {
            configuration.label
                .knockTextStyle(Theme.Typography.rowLabel12_5w500)
                .foregroundColor(isQuick ? Theme.Colors.ink : Theme.Colors.ink2)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(fill(active: isHovered || configuration.isPressed)))
                .overlay(Capsule().strokeBorder(isQuick ? Theme.Colors.honey300.opacity(0.6) : Theme.Stroke.card.color, lineWidth: Theme.Stroke.card.width))
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .onHover { isHovered = $0 }
                .pointerCursor()
        }
    }
}

/// The detail request, in place of the options (HAIL-111, prototype #E1 state A): four quick asks
/// that send on one tap or key, three format rows (HAIL-139) that send the same ask in one format,
/// and "Something else…" that turns into an inline field.
struct AskForDetailPanelView: View {
    @ObservedObject var composer: ComposerViewModel
    let onSend: () -> Void
    let onSendFormat: (ReplyFormat) -> Void

    /// `KNOCK_EVIDENCE_DETAIL_ELSE=<text>` opens "Something else…" with that text (evidence only);
    /// `\n` in the value becomes a newline.
    @State private var isTypingElse: Bool
    @State private var isElseFocused = false
    @State private var fieldWidth: CGFloat = 300

    static let maxFieldLines = 6

    init(
        composer: ComposerViewModel, onSend: @escaping () -> Void,
        onSendFormat: @escaping (ReplyFormat) -> Void = { _ in },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.composer = composer
        self.onSend = onSend
        self.onSendFormat = onSendFormat
        _isTypingElse = State(initialValue: environment["KNOCK_EVIDENCE_DETAIL_ELSE"] != nil)
    }

    /// Fills the field once when the evidence hook is set (never from `init`, which runs on every redraw).
    private func applyEvidenceText() {
        guard let text = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_DETAIL_ELSE"] else { return }
        composer.detailQuestionText = text.replacingOccurrences(of: "\\n", with: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(ComposerViewModel.detailChips.enumerated()), id: \.offset) { index, text in
                Rectangle().fill(Theme.Colors.line).frame(height: 1)
                row(position: index + 1, text: text)
            }
            Rectangle().fill(Theme.Colors.line).frame(height: 1)
            formatLabel
            ForEach(Array(ReplyFormat.allCases.enumerated()), id: \.element) { index, format in
                Rectangle().fill(Theme.Colors.line).frame(height: 1)
                formatRow(position: index + ComposerViewModel.detailChips.count + 1, format: format)
            }
            Rectangle().fill(Theme.Colors.line).frame(height: 1)
            elseRow
            Text("One tap asks. The options come back with the agent's answer.")
                .knockTextStyle(Theme.Typography.caption11_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .padding(EdgeInsets(top: 6, leading: 14, bottom: 10, trailing: 14))
        }
        .background(shortcuts)
        .onAppear(perform: applyEvidenceText)
    }

    private var header: some View {
        HStack {
            Text("What would help you decide?")
                .knockTextStyle(Theme.Typography.rowLabel12_5w500)
                .foregroundColor(Theme.Colors.ink)
            Spacer(minLength: 8)
            Button("Back to options", action: composer.cancelAskingForDetail)
                .buttonStyle(.plain).pointerCursor()
                .knockTextStyle(Theme.Typography.caption11_5w400)
                .foregroundColor(Theme.Colors.ink2)
                .underline()
        }
        .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
    }

    /// "Or the same explanation, in another format" (HAIL-139 amendment 2): a
    /// thin label over the three format rows. Its top border is the separator
    /// drawn by the row above, matching the other rows' divider.
    private var formatLabel: some View {
        Text("Or the same explanation, in another format")
            .knockTextStyle(Theme.Typography.statusCaption11w400)
            .foregroundColor(Theme.Colors.ink3)
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 4, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func key(_ label: String) -> some View {
        Text(label)
            .knockTextStyle(Theme.Typography.keyBadge12w600)
            .foregroundColor(Theme.Colors.ink)
            .frame(width: 22, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .stroke(Theme.Stroke.card.color, lineWidth: Theme.Stroke.card.width)
            )
    }

    private func row(position: Int, text: String) -> some View {
        HStack(spacing: 10) {
            key("\(position)")
            Text(text)
                .knockTextStyle(Theme.Typography.optionLabel13w500)
                .foregroundColor(Theme.Colors.ink)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { sendQuick(text) }.pointerCursor()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isButton)
    }

    /// One of the three format rows (keys 5-7, HAIL-139): the same recipe as
    /// the quick-ask rows, plus a small lucide icon between the key and the
    /// label. One tap sends the detail request in that format.
    private func formatRow(position: Int, format: ReplyFormat) -> some View {
        HStack(spacing: 10) {
            key("\(position)")
            Image(systemName: format.icon)
                .font(.system(size: 15))
                .foregroundColor(Theme.Colors.ink2)
                // One width for every icon, so the three labels line up.
                .frame(width: 20)
            Text(format.rowLabel)
                .knockTextStyle(Theme.Typography.optionLabel13w500)
                .foregroundColor(Theme.Colors.ink)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { sendFormat(format) }.pointerCursor()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(format.rowLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var elseRow: some View {
        HStack(alignment: .top, spacing: 10) {
            key("\(ComposerViewModel.detailChips.count + ReplyFormat.allCases.count + 1)").padding(.top, isTypingElse ? 3 : 0)
            if isTypingElse {
                elseField
            } else {
                Text("Something else…")
                    .knockTextStyle(Theme.Typography.optionLabel13w500)
                    .foregroundColor(Theme.Colors.ink2)
                Spacer(minLength: 0)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if !isTypingElse { openElse() } }.pointerCursor()
    }

    /// The row's own field: grows with the text to a few lines, then scrolls. Enter sends,
    /// Shift+Enter starts a new line (the same rule as the reply field).
    private var elseField: some View {
        let lines = PromptBarLogic.lineCount(text: composer.detailQuestionText, textWidth: max(fieldWidth - PromptBarLogic.textInset.width * 2, 1))
        return ZStack(alignment: .topLeading) {
            if composer.detailQuestionText.isEmpty {
                Text("What would help you decide?")
                    .knockTextStyle(Theme.Typography.body13_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .padding(.leading, PromptBarLogic.textInset.width)
                    .padding(.top, PromptBarLogic.textInset.height)
                    .allowsHitTesting(false)
            }
            PromptTextView(
                text: $composer.detailQuestionText, isFocused: $isElseFocused,
                canSend: composer.detailQuestion != nil,
                onSend: {
                    reportPick(format: "none", pick: "something_else")
                    onSend()
                })
        }
        .frame(height: PromptBarLogic.fieldHeight(totalLines: lines, maxLines: Self.maxFieldLines))
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { fieldWidth = $0 }
    }

    private func openElse() {
        composer.detailQuestionText = ""
        isTypingElse = true
        isElseFocused = true
    }

    private func sendQuick(_ text: String) {
        composer.fillDetailChip(text)
        if let index = ComposerViewModel.detailChips.firstIndex(of: text) {
            reportPick(format: "none", pick: ComposerViewModel.detailChipUsageNames[index])
        }
        onSend()
    }

    private func sendFormat(_ format: ReplyFormat) {
        reportPick(format: format.rawValue, pick: nil)
        onSendFormat(format)
    }

    private func reportPick(format: String, pick: String?) {
        DetailPill.report(format: format, pick: pick)
    }

    /// Keys 1 to 8 and Esc, not while the inline field has the caret.
    private var shortcuts: some View {
        HStack {
            ForEach(Array(ComposerViewModel.detailChips.enumerated()), id: \.offset) { index, text in
                Button("Ask \(text)") { if !isElseFocused { sendQuick(text) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
            }
            ForEach(Array(ReplyFormat.allCases.enumerated()), id: \.element) { index, format in
                Button("Ask in \(format.rowLabel)") { if !isElseFocused { sendFormat(format) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + ComposerViewModel.detailChips.count + 1)")), modifiers: [])
            }
            Button("Something else") { if !isElseFocused, !isTypingElse { openElse() } }
                .keyboardShortcut(KeyEquivalent(Character("\(ComposerViewModel.detailChips.count + ReplyFormat.allCases.count + 1)")), modifiers: [])
            Button("Back to options", action: composer.cancelAskingForDetail)
                .keyboardShortcut(.escape, modifiers: [])
            Button("Ask") {
                if composer.detailQuestion != nil { reportPick(format: "none", pick: "something_else") }
                onSend()
            }
                .keyboardShortcut(.return, modifiers: .command)
        }
        .opacity(0)
    }
}
