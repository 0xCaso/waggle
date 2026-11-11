import SwiftUI

/// The quick replies (WAG-411), at the top of the "Ask for…" panel (C5): one click sends the words as the reply.
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

    /// The quick replies the send row shows after "+", wherever the bar has "Ask for…" (request page, 2026-11-10).
    static let inSendRow: [QuickReply] = [.letsDiscuss, .showMeMore]

    /// The chips of the panel's "Reply" row: the visible ones the send row does not already show, so none shows
    /// twice while the panel is open (PR #1 review).
    static func inPanel(hasComments: Bool) -> [QuickReply] {
        visible(hasComments: hasComments).filter { !inSendRow.contains($0) }
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

/// What the "Ask for…" panel lists (C5), with the key of each row. The chip row it replaces is gone; every chip
/// of it is a row here: the five quick asks, "Show me screenshots", the three formats ("a diagram" is one) and
/// "Something else". The quick replies sit above the rows, with no key, as in the old row.
@MainActor
enum AskForPanel {
    enum Entry: Equatable {
        /// A request sent as it is: its text and its word in the usage log.
        case ask(text: String, usage: String)
        case format(ReplyFormat)
        case somethingElse
    }

    static var entries: [Entry] {
        let quick = zip(ComposerViewModel.detailChips, ComposerViewModel.detailChipUsageNames).map { Entry.ask(text: $0, usage: $1) }
        // The asks only the old row had (today "Show me screenshots").
        let rowOnly = DetailPill.all.compactMap { pill -> Entry? in
            if case .ask(let text, let usage) = pill.pick { return .ask(text: text, usage: usage) }
            return nil
        }
        return quick + rowOnly + ReplyFormat.allCases.map(Entry.format) + [.somethingElse]
    }

    /// The key of the row at `index`: 1 to 9, then 0. Past ten rows, none.
    static func key(at index: Int) -> String? {
        switch index {
        case 0..<9: return "\(index + 1)"
        case 9: return "0"
        default: return nil
        }
    }

    /// Whether the old row's pill is a row of the panel: nothing of the row is lost.
    static func lists(_ pill: DetailPill) -> Bool {
        switch pill.pick {
        case .quick(let index): return entries.contains(.ask(text: ComposerViewModel.detailChips[index], usage: ComposerViewModel.detailChipUsageNames[index]))
        case .ask(let text, let usage): return entries.contains(.ask(text: text, usage: usage))
        case .format(let format): return entries.contains(.format(format))
        }
    }
}

/// The panel in the decision column (C5): a card of its own, as the options it replaces sit in the page.
struct AskForPanelCard: ViewModifier {
    let isCard: Bool

    func body(content: Content) -> some View {
        if isCard {
            content
                .background(Theme.Colors.win)
                .clipShape(RoundedRectangle(cornerRadius: CalmOption.rowRadius))
                .overlay(RoundedRectangle(cornerRadius: CalmOption.rowRadius).stroke(Theme.Colors.line, lineWidth: 1))
                .background(ScrollIntoViewOnAppear())
        } else {
            content
        }
    }
}

/// Scrolls the view it backs into sight once it appears: the panel opens from the send row, and may sit
/// below the fold of the column.
private struct ScrollIntoViewOnAppear: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {}

    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.window != nil else { return }
                self.scrollToVisible(self.bounds)
            }
        }
    }
}

/// One pill of the old "Ask for" row (WAG-367): the words name what comes back. The row is gone (C5); each pill
/// is a row of the "Ask for…" panel (`AskForPanel.lists`).
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

/// The detail request, in place of the options (HAIL-111, prototype #E1 state A), opened by "Ask for…" in the send
/// row or "?" (C5): the quick replies (where the host offers them), the quick asks that send on one tap or key,
/// the three format rows (HAIL-139) that send the same ask in one format, and "Something else…" that turns into
/// an inline field. Keys 1 to 9 and 0 (`AskForPanel.key`), Esc back to the options, Cmd-Return asks.
struct AskForDetailPanelView: View {
    @ObservedObject var composer: ComposerViewModel
    let onSend: () -> Void
    let onSendFormat: (ReplyFormat) -> Void
    /// Nil where a plain reply makes no sense (a step of several questions): then the panel has no quick replies.
    var onQuickReply: ((QuickReply) -> Void)? = nil
    /// True when comments are pinned: then "Look at my comments" shows.
    var hasComments = false

    /// `KNOCK_EVIDENCE_DETAIL_ELSE=<text>` opens "Something else…" with that text (evidence only);
    /// `\n` in the value becomes a newline.
    @State private var isTypingElse: Bool
    @State private var isElseFocused = false
    /// Height of the column or pane: the field grows to 40 % of it, as the answer box does (C6).
    @Environment(\.answerBoxAvailableHeight) private var availableHeight

    init(
        composer: ComposerViewModel, onSend: @escaping () -> Void,
        onSendFormat: @escaping (ReplyFormat) -> Void = { _ in },
        onQuickReply: ((QuickReply) -> Void)? = nil, hasComments: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.composer = composer
        self.onSend = onSend
        self.onSendFormat = onSendFormat
        self.onQuickReply = onQuickReply
        self.hasComments = hasComments
        _isTypingElse = State(initialValue: environment["KNOCK_EVIDENCE_DETAIL_ELSE"] != nil)
    }

    /// Fills the field once when the evidence hook is set (never from `init`, which runs on every redraw).
    private func applyEvidenceText() {
        guard let text = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_DETAIL_ELSE"] else { return }
        composer.detailQuestionText = text.replacingOccurrences(of: "\\n", with: "\n")
    }

    private var entries: [AskForPanel.Entry] { AskForPanel.entries }
    private var firstFormat: Int { entries.firstIndex { if case .format = $0 { return true } else { return false } } ?? entries.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let onQuickReply, !panelReplies.isEmpty { quickReplies(onQuickReply) }
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index == firstFormat {
                    Rectangle().fill(Theme.Colors.line).frame(height: 1)
                    formatLabel
                }
                Rectangle().fill(Theme.Colors.line).frame(height: 1)
                switch entry {
                case .ask(let text, let usage): row(key: AskForPanel.key(at: index), text: text, usage: usage)
                case .format(let format): formatRow(key: AskForPanel.key(at: index), format: format)
                case .somethingElse: elseRow(key: AskForPanel.key(at: index))
                }
            }
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
                .help("Back to options (Esc)")
        }
        .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
    }

    /// The quick replies (WAG-411): one click sends the words as the reply. They wrap, never cut.
    private var panelReplies: [QuickReply] {
        QuickReply.inPanel(hasComments: hasComments || ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_QUICK_COMMENTS"] == "1")
    }

    private func quickReplies(_ send: @escaping (QuickReply) -> Void) -> some View {
        let visible = panelReplies
        return HStack(spacing: 6) {
            Text("Reply")
                .knockTextStyle(Theme.Typography.statusCaption11w400)
                .foregroundColor(Theme.Colors.ink3)
                .fixedSize()
            ForEach(visible) { reply in
                Button(reply.label) { send(reply) }
                    .buttonStyle(DetailPillStyle(isQuick: true))
                    .fixedSize()
                    .accessibilityLabel(reply.label)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 10, trailing: 14))
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

    @ViewBuilder
    private func key(_ label: String?) -> some View {
        Text(label ?? "")
            .knockTextStyle(Theme.Typography.keyBadge12w600)
            .foregroundColor(Theme.Colors.ink)
            .frame(width: 22, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .stroke(Theme.Stroke.card.color, lineWidth: Theme.Stroke.card.width)
                    .opacity(label == nil ? 0 : 1)
            )
    }

    private func row(key label: String?, text: String, usage: String) -> some View {
        HStack(spacing: 10) {
            key(label)
            Text(text)
                .knockTextStyle(Theme.Typography.optionLabel13w500)
                .foregroundColor(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { sendAsk(text, usage: usage) }.pointerCursor()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isButton)
    }

    /// One of the three format rows (HAIL-139): the same recipe as the quick-ask rows, plus a small lucide icon
    /// between the key and the label. One tap sends the detail request in that format.
    private func formatRow(key label: String?, format: ReplyFormat) -> some View {
        HStack(spacing: 10) {
            key(label)
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

    private func elseRow(key label: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            key(label).padding(.top, isTypingElse ? 3 : 0)
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

    /// The row's own field, sized by the answer box's rule (C6): its own text view's layout at the width
    /// it is given, up to 40 % of the column (at least six lines), then it scrolls with a visible scroller.
    /// Enter sends, Shift+Enter starts a new line (the same rule as the reply field).
    private var elseField: some View {
        ZStack(alignment: .topLeading) {
            if composer.detailQuestionText.isEmpty {
                Text("What would help you decide?")
                    .font(Theme.Typography.body13_5w400.font)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(EdgeInsets(
                        top: PromptBarLogic.textInset.height, leading: PromptBarLogic.textInset.width,
                        bottom: PromptBarLogic.textInset.height, trailing: PromptBarLogic.textInset.width))
                    .allowsHitTesting(false)
            }
            PromptTextView(
                text: $composer.detailQuestionText, isFocused: $isElseFocused,
                canSend: composer.detailQuestion != nil,
                onSend: {
                    reportPick(format: "none", pick: "something_else")
                    onSend()
                },
                maxHeight: PromptBarLogic.maxFieldHeight(availableHeight: availableHeight))
        }
        .frame(maxWidth: .infinity)
    }

    private func openElse() {
        composer.detailQuestionText = ""
        isTypingElse = true
        isElseFocused = true
    }

    private func sendAsk(_ text: String, usage: String) {
        composer.fillDetailChip(text)
        reportPick(format: "none", pick: usage)
        onSend()
    }

    private func sendFormat(_ format: ReplyFormat) {
        reportPick(format: format.rawValue, pick: nil)
        onSendFormat(format)
    }

    private func reportPick(format: String, pick: String?) {
        DetailPill.report(format: format, pick: pick)
    }

    /// The row keys (1 to 9, then 0) and Esc, not while the inline field has the caret; Cmd-Return asks.
    private var shortcuts: some View {
        HStack {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if let key = AskForPanel.key(at: index) {
                    Button(Self.shortcutTitle(entry)) {
                        guard !isElseFocused else { return }
                        switch entry {
                        case .ask(let text, let usage): sendAsk(text, usage: usage)
                        case .format(let format): sendFormat(format)
                        case .somethingElse: if !isTypingElse { openElse() }
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(key)), modifiers: [])
                }
            }
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

    private static func shortcutTitle(_ entry: AskForPanel.Entry) -> String {
        switch entry {
        case .ask(let text, _): "Ask \(text)"
        case .format(let format): "Ask in \(format.rowLabel)"
        case .somethingElse: "Something else"
        }
    }
}
