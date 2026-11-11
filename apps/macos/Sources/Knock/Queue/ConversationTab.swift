import SwiftUI

// The Conversation tab of the decision column (C8, spec section 5). It replaces the 380 pt conversation column
// (HAIL-71, WAG-299). Patterns from AI Elements (Message with actions, Reasoning and Tool folded, built in
// SwiftUI): your answers on the right, the agent's messages on the left, no bubble border, every message in full
// with the agent's question line in semibold, progress notes folded to one "Worked: N steps" line.

/// One row of the Conversation tab: a message, or a run of the agent's progress notes folded to one line.
enum ConversationEntry: Equatable {
    case message(index: Int, step: ThreadStep)
    case worked(firstIndex: Int, notes: [ThreadStep.Updated])

    var id: Int {
        switch self {
        case .message(let index, _): index
        case .worked(let index, _): index
        }
    }
}

/// The rules of the Conversation tab. Pure, so they are unit-tested.
enum ConversationRules {
    /// Steps in order; back-to-back progress notes join one `.worked` row.
    static func entries(_ steps: [ThreadStep]) -> [ConversationEntry] {
        var out: [ConversationEntry] = []
        for (index, step) in steps.enumerated() {
            if case .updated(let update) = step, update.isWorking {
                if case .worked(let first, let notes)? = out.last {
                    out[out.count - 1] = .worked(firstIndex: first, notes: notes + [update])
                } else {
                    out.append(.worked(firstIndex: index, notes: [update]))
                }
            } else {
                out.append(.message(index: index, step: step))
            }
        }
        return out
    }

    /// A question line longer than this stays regular: a long first paragraph in semibold reads as a wall of bold.
    static let questionMaxLength = 200

    /// The question line and the rest of a message. The question is the first paragraph, as in the need box, and only
    /// when it is short and more text follows; else the whole text is regular.
    static func parts(_ text: String, boldsQuestion: Bool) -> NeedText.Parts {
        guard boldsQuestion else { return NeedText.Parts(question: "", details: text) }
        let parts = NeedText.split(text)
        // A message of one paragraph has no question line over details: it stays regular.
        guard parts.details?.isEmpty == false, AgentMarkdown.plainText(parts.question).count <= questionMaxLength else {
            return NeedText.Parts(question: "", details: text)
        }
        return parts
    }

    /// The "round 2 · v2 of the artifact" line (mockup `.round`) on the first row after a reply of yours (the agent's
    /// message, or the progress notes before it): nil for any other row. The version is the next agent message's.
    static func roundDivider(_ entries: [ConversationEntry], at position: Int) -> String? {
        guard position > 0, case .message(_, .replied) = entries[position - 1] else { return nil }
        if case .message(_, .replied) = entries[position] { return nil }
        let round = 1 + entries[..<position].filter { if case .message(_, .replied) = $0 { true } else { false } }.count
        let revision = entries[position...].lazy.compactMap { entry -> Int? in
            if case .message(_, .updated(let update)) = entry { return update.revision?.n ?? 0 }
            return nil
        }.first
        return "round \(round)" + (revision.flatMap { $0 > 0 ? " · v\($0) of the artifact" : nil } ?? "")
    }

    /// The newest agent message after a reply of yours: the one the tab marks as new (mockup `.msg.latestm`).
    static func latestPosition(_ entries: [ConversationEntry]) -> Int? {
        guard let last = entries.indices.last, case .message(_, .updated) = entries[last] else { return nil }
        let replied = entries.contains { if case .message(_, .replied) = $0 { true } else { false } }
        return replied ? last : nil
    }

    /// "Worked: 1 step", "Worked: 3 steps".
    static func workedLabel(_ count: Int) -> String { "Worked: \(count) step\(count == 1 ? "" : "s")" }

    /// The newest agent update with words: the latest-message line above the tabs.
    static func latestAgentMessage(_ model: ThreadModel?) -> ThreadStep.Updated? {
        for step in (model?.steps ?? []).reversed() {
            if case .updated(let update) = step, !update.message.isEmpty { return update }
        }
        return nil
    }

    /// The latest-message line above the tabs: nil on the Conversation tab (it shows the message itself), and nil
    /// on the Decision tab when the page already heads with the same message (a progress note or a message-only
    /// update).
    static func latestLine(_ model: ThreadModel?, tab: ReviewColumnTab, decisionHeadsWithIt: Bool) -> ThreadStep.Updated? {
        if tab == .conversation { return nil }
        if tab == .question && decisionHeadsWithIt { return nil }
        return latestAgentMessage(model)
    }

    /// The message as one line of plain text, for the latest-message line (the view truncates it).
    static func oneLine(_ message: String) -> String {
        AgentMarkdown.plainText(message).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// The dot on the Conversation tab: an agent message came after you last opened the tab. Never while the tab is open.
enum ConversationDot {
    static func shows(latestAgentAt: Date?, seenAt: Date?, tab: ReviewColumnTab) -> Bool {
        guard tab != .conversation, let latestAgentAt else { return false }
        guard let seenAt else { return true }
        return latestAgentAt > seenAt
    }

    /// When the newest agent message arrived, progress notes included.
    static func latestAgentAt(_ model: ThreadModel?) -> Date? {
        for step in (model?.steps ?? []).reversed() {
            if case .updated(let update) = step { return update.at }
        }
        return nil
    }
}

/// The dot on the Comments tab: team comments unread when the case opened, or late comments not yet sent to the
/// agent, until you open the tab.
enum CommentsDot {
    static func shows(unreadAtOpen: Int, lateNew: Int, seen: Bool, tab: ReviewColumnTab) -> Bool {
        tab != .comments && !seen && (unreadAtOpen > 0 || lateNew > 0)
    }
}

/// ⌘] in the case pane: open the Conversation tab, and from it go back to Decision.
enum ConversationTabRouting {
    static func toggled(_ tab: ReviewColumnTab) -> ReviewColumnTab { tab == .conversation ? .question : .conversation }

    /// `KNOCK_PANE_TAB=conversation|comments` (evidence), and the older `KNOCK_CONVERSATION_OPEN=1` (WAG-299).
    static func initialTab(environment: [String: String]) -> ReviewColumnTab {
        if environment["KNOCK_CONVERSATION_OPEN"] == "1" { return .conversation }
        switch environment["KNOCK_PANE_TAB"] {
        case "conversation": return .conversation
        case "comments": return .comments
        default: return .question
        }
    }
}

/// When you last opened each case's Conversation tab, kept across launches, so the dot says "new since you looked".
@MainActor
final class ConversationSeenStore: ObservableObject {
    static let shared = ConversationSeenStore()
    static let key = "conversationSeenAt"

    private let defaults: UserDefaults
    @Published private var seen: [String: Date]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        seen = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func seenAt(caseId: String) -> Date? { seen[caseId] }

    func markSeen(caseId: String, at date: Date) {
        if let old = seen[caseId], old >= date { return }
        seen[caseId] = date
        // Only the newest 500 cases are kept.
        let kept = seen.sorted { $0.value > $1.value }.prefix(500)
        defaults.set(Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value.timeIntervalSince1970) }), forKey: Self.key)
    }
}

/// The words of the Conversation tab. Pure, so they are unit-tested.
enum ConversationCopy {
    /// "CLAUDE CODE · 21:10".
    static func askedHeader(_ asked: ThreadStep.Asked, runtime: String, timeZone: TimeZone = .current) -> String {
        "\(runtime.uppercased()) · \(ThreadCopy.clock(asked.at, timeZone: timeZone))"
    }

    /// "CLAUDE CODE · 21:24 · v2".
    static func updatedHeader(_ updated: ThreadStep.Updated, runtime: String, timeZone: TimeZone = .current) -> String {
        var parts = [runtime.uppercased(), ThreadCopy.clock(updated.at, timeZone: timeZone)]
        if let revision = updated.revision { parts.append("v\(revision.n)") }
        return parts.joined(separator: " · ")
    }

    /// "YOU · 21:23 · 1 comment on v1".
    static func repliedHeader(_ replied: ThreadStep.Replied, timeZone: TimeZone = .current) -> String {
        (["YOU", ThreadCopy.clock(replied.at, timeZone: timeZone)] + [replied.meta].compactMap { $0 }).joined(separator: " · ")
    }

    /// "✓ picked up 21:23 · worked 8s".
    static func pickedUpLine(_ picked: ThreadStep.PickedUp, timeZone: TimeZone = .current) -> String {
        "✓ picked up " + ThreadCopy.clock(picked.at, timeZone: timeZone) + (picked.worked.map { " · " + ThreadCopy.worked($0) } ?? "")
    }

    /// "Your turn": the column is narrow, so the hint after the colon stays in the composer.
    static func turnLabel(_ turn: ThreadTurn) -> String {
        turn.status == .needsYou ? String(turn.label.prefix { $0 != ":" }) : turn.label
    }

    /// "v1 · see in review": the link to the version before the update's own.
    static func priorVersionLink(_ updated: ThreadStep.Updated) -> String? {
        guard let revision = updated.revision, revision.isLatest, let prior = revision.prior else { return nil }
        return "v\(prior) · see in review"
    }
}

extension ThreadModel {
    /// Rounds so far: the first ask, plus one for each reply of yours.
    var roundCount: Int {
        1 + steps.filter { if case .replied = $0 { true } else { false } }.count
    }
}

// MARK: - Views

/// The Conversation tab's content: the earlier requests on top, then the messages and the turn line. It scrolls on
/// its own and starts at the bottom when the thread is taller than the column.
struct ConversationTabView: View {
    let model: ThreadModel
    let turn: ThreadTurn
    var earlier: EarlierAsksModel?
    var onOpenCase: (String) -> Void = { _ in }
    /// Opens the review on the version before an update's own ("v1 · see in review"). Nil hides the link.
    var onSeeInReview: (() -> Void)? = nil
    /// The column's content edges, the same as its other tabs: the earlier-requests row and the messages stay inside them.
    var leadingPadding: CGFloat = Theme.AskDoc.Column.scrollInset.leading
    var trailingPadding: CGFloat = Theme.AskDoc.Column.scrollInset.trailing

    private static let bottomId = "conversation-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let earlier, earlier.linkLabel != nil {
                        EarlierRequestsList(model: earlier, onOpenCase: onOpenCase)
                    }
                    // `.msg`: 8 between messages; `.round`: 10 above and below.
                    VStack(alignment: .leading, spacing: Theme.AskDoc.Column.messageGap) {
                        let entries = ConversationRules.entries(model.steps)
                        let latest = ConversationRules.latestPosition(entries)
                        ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                            if let divider = ConversationRules.roundDivider(entries, at: position) {
                                Text(divider)
                                    .knockTextStyle(Theme.AskDoc.Column.messageHead)
                                    .foregroundColor(Theme.AskDoc.Colors.quiet)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 2)
                            }
                            switch entry {
                            case .message(_, let step): message(step, isLatest: position == latest)
                            case .worked(_, let notes): WorkedStepsRow(notes: notes, runtime: model.runtimeName)
                            }
                        }
                        turnRow
                    }
                    .overlay(alignment: .bottom) { Color.clear.frame(height: 0).id(Self.bottomId) }
                }
                .padding(EdgeInsets(
                    top: Theme.AskDoc.Column.scrollInset.top, leading: leadingPadding,
                    bottom: Theme.AskDoc.Column.scrollInset.bottom + 6, trailing: trailingPadding))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("conversation-tab")
    }

    @ViewBuilder
    private func message(_ step: ThreadStep, isLatest: Bool) -> some View {
        switch step {
        case .asked(let asked):
            ConversationMessageView(
                header: ConversationCopy.askedHeader(asked, runtime: model.runtimeName), text: asked.need, isYours: false)
        case .updated(let updated):
            ConversationMessageView(
                header: ConversationCopy.updatedHeader(updated, runtime: model.runtimeName), text: updated.message,
                isYours: false, isLatest: isLatest,
                link: onSeeInReview == nil ? nil : ConversationCopy.priorVersionLink(updated), onLink: onSeeInReview)
        case .replied(let replied):
            ConversationMessageView(
                header: ConversationCopy.repliedHeader(replied), text: replied.summary, isYours: true,
                footnote: replied.pickedUp.map { ConversationCopy.pickedUpLine($0) })
        }
    }

    private var turnRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AgentStatusLine(
                status: turn.status, cell: 4, label: ConversationCopy.turnLabel(turn), since: nil,
                labelFont: .sans(12.5), spacing: 10)
            if let since = turn.since {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if turn.status == .needsYou {
                        Text("waiting").knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                            .foregroundColor(Theme.Colors.ink3)
                    }
                    ElapsedTimer(since: since)
                }
            }
        }
        .padding(.top, 2)
    }
}

/// One message as the mockup's `.msg`: a bubble with who and when on top (mono 10.5, quiet) and the text in full
/// (12.5/1.5). The agent's bubble is on the side fill; yours is ink with white text and sits 40 pt in from the left,
/// "picked up" at the right of its header. The newest agent message after a reply has the latest fill, with no bar
/// on its left (operator review, 11 Nov).
struct ConversationMessageView: View {
    let header: String
    let text: String
    let isYours: Bool
    var footnote: String? = nil
    var isLatest = false
    /// "v1 · see in review" under an update, and what a click on it does.
    var link: String? = nil
    var onLink: (() -> Void)? = nil

    private typealias Column = Theme.AskDoc.Column

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(header)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if let footnote {
                    Text(footnote.hasPrefix("✓ ") ? String(footnote.dropFirst(2)) : footnote)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .knockTextStyle(Column.messageHead)
            .foregroundColor(isYours ? Column.yourHead : Theme.AskDoc.Colors.quiet)
            ConversationText(
                text: text, boldsQuestion: false, style: Column.message, color: isYours ? Theme.Colors.win : Theme.Colors.ink)
            if let link, let onLink {
                Text(link)
                    .knockTextStyle(Theme.Typography.priorRevisionLink12w500)
                    .foregroundColor(Theme.Colors.ds)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onLink).pointerCursor()
            }
        }
        .textSelection(.enabled)
        .padding(Column.messagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Column.messageRadius))
        // Copy the message as plain text, as before the restyle (spec §5). Yours puts the button in the 40 pt gap.
        .copyOnHover(AgentMarkdown.plainText(text), outsideLeading: isYours)
        .padding(.leading, isYours ? 40 : 0)
    }

    private var background: Color {
        if isYours { return Theme.Colors.ink }
        return isLatest ? Theme.Colors.latestFill : Theme.Colors.side
    }
}

/// A message's text in full. With `boldsQuestion`, the first paragraph (it stops at a list or a table, as
/// `NeedText.split`) is semibold and the rest regular. `.msg p`: 6 between paragraphs.
struct ConversationText: View {
    let text: String
    var boldsQuestion = false
    var style: Theme.TextStyle = Theme.Typography.body13w400
    var color: Color = Theme.Colors.ink

    var body: some View {
        let parts = ConversationRules.parts(text, boldsQuestion: boldsQuestion)
        VStack(alignment: .leading, spacing: 6) {
            if !parts.question.isEmpty {
                AgentMarkdownText(text: parts.question, style: NeedText.questionStyle(style), color: color, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let details = parts.details, !details.isEmpty {
                AgentMarkdownText(text: details, style: style, color: color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "› Worked: 3 steps" (AI Elements "Reasoning" / "Tool"): the agent's progress notes, folded; a click opens them.
struct WorkedStepsRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let notes: [ThreadStep.Updated]
    let runtime: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { ReducedMotion.animate(reduceMotion: reduceMotion, .easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(ConversationRules.workedLabel(notes.count))
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                    if let last = notes.last {
                        Text("· " + ThreadCopy.clock(last.at))
                            .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                    }
                }
                .foregroundColor(Theme.Colors.ink3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .accessibilityLabel(ConversationRules.workedLabel(notes.count))
            .accessibilityValue(open ? "open" : "folded")
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ConversationCopy.updatedHeader(note, runtime: runtime))
                                .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                                .foregroundColor(Theme.Colors.ink3)
                            ConversationText(text: note.message, style: Theme.Typography.body12_5w400)
                        }
                    }
                }
                .padding(.leading, 15)
            }
        }
    }
}

/// "2 earlier requests ▾" at the top of the Conversation tab: opens the list in place; each row opens its request.
struct EarlierRequestsList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: EarlierAsksModel
    var onOpenCase: (String) -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { ReducedMotion.animate(reduceMotion: reduceMotion, .easeOut(duration: 0.15)) { open.toggle() } } label: {
                    Text((model.linkLabel ?? "") + (open ? " ▴" : " ▾"))
                        .knockTextStyle(Theme.AskDoc.Typography.crumbs12_5)
                        .foregroundColor(Theme.Colors.ds)
                        .lineLimit(1)
                }
                .buttonStyle(.plain).pointerCursor()
                Spacer(minLength: 0)
            }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        Button { onOpenCase(row.id) } label: { rowView(row) }
                            .buttonStyle(.plain).pointerCursor()
                    }
                    Text(model.footer)
                        .knockTextStyle(Theme.AskDoc.Typography.crumbs12)
                        .foregroundColor(Theme.Colors.ink3)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.bottom, 4)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
    }

    private func rowView(_ row: EarlierAsksModel.Row) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.isAnswered ? "checkmark" : "circle.dotted")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(row.isAnswered ? Theme.Colors.ok : Theme.AskDoc.Colors.quiet)
                .frame(width: 12)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .knockTextStyle(Theme.Typography.rowLabel12_5w500)
                    .foregroundColor(Theme.Colors.ink)
                    .lineLimit(1).truncationMode(.tail)
                Text(row.time.isEmpty ? row.outcome : "\(row.outcome) · \(row.time)")
                    .knockTextStyle(Theme.AskDoc.Typography.answeredRow12_5)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// The agent's latest message as the mockup's `.latest` box, first in the Decision tab's scroll: "CLAUDE · 15:21"
/// (mono 10.5, link), the message on one line (12, ink2, cut with "…") and "Read" underlined, on the latest fill.
/// A click opens the Conversation tab.
struct LatestAgentMessageLine: View {
    let update: ThreadStep.Updated
    let runtime: String
    var showsDot = false
    let onOpen: () -> Void

    private typealias Column = Theme.AskDoc.Column

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if showsDot {
                    Circle().fill(Theme.Colors.link).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                }
                Text("\(runtime.uppercased()) · \(ThreadCopy.clock(update.at))")
                    .knockTextStyle(Column.latestWho)
                    .foregroundColor(Theme.Colors.link)
                    .lineLimit(1)
                    .fixedSize()
                Text(ConversationRules.oneLine(update.message))
                    .knockTextStyle(Column.latestText)
                    .foregroundColor(Theme.Colors.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Read")
                    .knockTextStyle(Column.latestText)
                    .foregroundColor(Theme.Colors.link)
                    .underline()
                    .fixedSize()
            }
            .frame(minHeight: Column.lineBox(12))
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Colors.latestFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(ConversationRules.oneLine(update.message))
        .accessibilityLabel("Latest from \(runtime): \(ConversationRules.oneLine(update.message))")
        .accessibilityHint("Opens the Conversation tab")
        .accessibilityIdentifier("latest-agent-message")
    }
}

/// The latest-message box at the top of the Decision tab's scroll (mockup `multi`, `.latest`, margin-bottom 12):
/// shown when the tab does not already head with the same message.
struct DecisionLatestMessage: View {
    let thread: ThreadModel?
    let tab: ReviewColumnTab
    var decisionHeadsWithLatest = false
    let onOpen: () -> Void

    var body: some View {
        if let latest = ConversationRules.latestLine(thread, tab: tab, decisionHeadsWithIt: decisionHeadsWithLatest) {
            LatestAgentMessageLine(update: latest, runtime: thread?.runtimeName ?? "Agent", onOpen: onOpen)
                .padding(.bottom, 12)
        }
    }
}

/// The tabs at the top of the decision column (pane and full size), `.tabs`. The latest-message box sits in the
/// Decision tab's scroll (`DecisionLatestMessage`); on the Comments tab it stays under the tabs here.
struct DecisionColumnHeader: View {
    let thread: ThreadModel?
    let caseId: String
    let tab: ReviewColumnTab
    let commentCount: Int
    var decisionHeadsWithLatest = false
    var commentsDot = false
    let onSelect: (ReviewColumnTab) -> Void
    @ObservedObject private var seen = ConversationSeenStore.shared

    var body: some View {
        let latestAt = ConversationDot.latestAgentAt(thread)
        let dot = ConversationDot.shows(latestAgentAt: latestAt, seenAt: seen.seenAt(caseId: caseId), tab: tab)
        VStack(alignment: .leading, spacing: 12) {
            ReviewColumnTabsView(
                tab: tab, commentCount: commentCount, conversationCount: thread?.roundCount, conversationDot: dot,
                commentsDot: commentsDot, onSelect: onSelect)
            if tab == .comments,
               let latest = ConversationRules.latestLine(thread, tab: tab, decisionHeadsWithIt: decisionHeadsWithLatest) {
                LatestAgentMessageLine(update: latest, runtime: thread?.runtimeName ?? "Agent", onOpen: { onSelect(.conversation) })
            }
        }
        // Opening the tab, or a message arriving while it is open, counts as seen.
        .onChange(of: tab, initial: true) { _, now in markSeen(now, latestAt) }
        .onChange(of: latestAt) { _, at in markSeen(tab, at) }
    }

    private func markSeen(_ tab: ReviewColumnTab, _ at: Date?) {
        guard tab == .conversation, let at else { return }
        seen.markSeen(caseId: caseId, at: at)
    }
}
