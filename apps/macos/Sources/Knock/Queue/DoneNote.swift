import SwiftUI

/// The closing note of a done request (waggle_update with done: true), WAG-333. It heads the page in
/// full size, and the decision it closes folds under it.
enum DoneNote {
    /// The agent's closing message, or nil when the case is not done or the note is empty.
    static func message(for item: Case) -> String? {
        guard item.isDone else { return nil }
        let text = (item.latestUpdateMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// A read only fold for the decision a note closes, folded at first (C2): one line, "You chose B · Show". Show opens
/// the decision in place.
struct EarlierDecisionFold<Content: View>: View {
    var title = "Earlier decision"
    @ViewBuilder let content: () -> Content
    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .knockTextStyle(Theme.Typography.recommendLine12w400)
                        .foregroundColor(Theme.Colors.ink2)
                        .lineLimit(1).truncationMode(.tail)
                    Text("·")
                        .knockTextStyle(Theme.Typography.recommendLine12w400)
                        .foregroundColor(Theme.Colors.ink3)
                    Text(isOpen ? "Hide" : "Show")
                        .knockTextStyle(Theme.Typography.recommendLine12w400)
                        .foregroundColor(Theme.Colors.ink)
                        .underline()
                        .fixedSize()
                }
                .help(title)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .accessibilityLabel(title)
            .accessibilityValue(isOpen ? "open" : "folded")
            if isOpen { content() }
        }
    }
}

/// The agent's latest message of a message-only update (WAG-337): same place and size as the done note,
/// with the time above it. Not green and not closing. It reads at body size, like a reply in a thread: it holds
/// the agent's full message, which can be long (WAG-393).
struct LatestMessageNote: View {
    let note: MessageOnlyUpdate
    let width: AskHeaderWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Latest from the agent · \(KnockDateFormat.shortTime(from: note.at))")
                .knockTextStyle(Theme.Typography.recommendLine12w400)
                .foregroundColor(Theme.Colors.ink3)
            AgentMarkdownText(text: note.message, style: Theme.Typography.body13w400, showsSources: true)
        }
    }
}
