import SwiftUI

/// The split pane's right column (HAIL-71, Pen `r01vFQ`, bubbles `n42ZJ`): the
/// thread as a chat. Agent cards sit left, your replies right in ink bubbles,
/// the current turn at the bottom. It scrolls on its own and starts at the bottom.
struct ConversationColumnView: View {
    let model: ThreadModel
    let turn: ThreadTurn
    /// Opens the review window on the version before the latest; nil with no artifact.
    var onSeeInReview: (() -> Void)?
    /// Index in `model.steps` to scroll to on appearing (HAIL-95, "See conversation"); nil starts at the bottom.
    var scrollToStep: Int?

    private static let bottomId = "conversation-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(ConversationCopy.title(model))
                    .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                    .foregroundColor(Theme.Colors.ink3)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 10, trailing: 12))
            // Starts at the bottom when the thread is taller than the column; a short
            // thread sits at the top, as in the design.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.steps.enumerated()), id: \.offset) { index, step in
                            message(step).id(index)
                        }
                        turnRow
                        Color.clear.frame(height: 0).id(Self.bottomId)
                    }
                    .padding(EdgeInsets(top: 0, leading: 18, bottom: 16, trailing: 18))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    if let scrollToStep {
                        proxy.scrollTo(scrollToStep, anchor: .top)
                    } else {
                        proxy.scrollTo(Self.bottomId, anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: ConversationSplit.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.conversationSide)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(width: 1), alignment: .leading)
    }

    @ViewBuilder
    private func message(_ step: ThreadStep) -> some View {
        switch step {
        case .asked(let asked): askedCard(asked)
        case .replied(let replied): repliedBubble(replied)
        case .updated(let updated): updatedCard(updated)
        }
    }

    private func header(_ text: String, color: Color = Theme.Colors.ink3) -> some View {
        Text(text)
            .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
            .foregroundColor(color)
            .textSelection(.enabled)
    }

    private func askedCard(_ asked: ThreadStep.Asked) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            header(ConversationCopy.askedHeader(asked, runtime: model.runtimeName))
            AgentMarkdownText(text: asked.need)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.conversationBubble)
        .copyOnHover(AgentMarkdown.plainText(asked.need))
    }

    private func updatedCard(_ updated: ThreadStep.Updated) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(ConversationCopy.updatedHeader(updated, runtime: model.runtimeName), color: Theme.Colors.ds)
            if !updated.message.isEmpty { AgentMarkdownText(text: updated.message) }
            if let link = ConversationCopy.priorVersionLink(updated), let onSeeInReview {
                Text(link)
                    .knockTextStyle(Theme.Typography.priorRevisionLink12w500)
                    .foregroundColor(Theme.Colors.ds)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSeeInReview).pointerCursor()
            }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.dsUpdateFill)
        .cornerRadius(Theme.Radius.conversationBubble)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.conversationBubble)
                .stroke(Theme.Colors.dsUpdateStroke, lineWidth: 1))
        .copyOnHover(AgentMarkdown.plainText(updated.message))
    }

    private func repliedBubble(_ replied: ThreadStep.Replied) -> some View {
        let bubble = VStack(alignment: .leading, spacing: 5) {
            header(ConversationCopy.repliedHeader(replied), color: Theme.Colors.win.opacity(0.65))
            AgentMarkdownText(text: replied.summary, color: Theme.Colors.win)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
        .background(Theme.Colors.ink)
        .cornerRadius(Theme.Radius.conversationBubble)
        .copyOnHover(AgentMarkdown.plainText(replied.summary), outsideLeading: true)
        return VStack(alignment: .trailing, spacing: 5) {
            // Short text hugs its bubble; long text wraps at the column's width.
            ViewThatFits(in: .horizontal) {
                bubble.fixedSize(horizontal: true, vertical: false)
                bubble
            }
            if let picked = replied.pickedUp {
                header(ConversationCopy.pickedUpLine(picked))
            }
        }
        .padding(.leading, 48)
        .frame(maxWidth: .infinity, alignment: .trailing)
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

/// The page header's conversation icon (WAG-299): an outline speech bubble, 24 pt like the full
/// screen icon beside it, with the round count in small mono ink3. Pressed while the column is open.
struct ConversationIconButton: View {
    let roundCount: Int
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                Text(ConversationCopy.roundBadge(roundCount))
                    .knockTextStyle(Theme.Typography.monoMeta11_5w400)
            }
            .foregroundColor(isOpen ? Theme.Colors.ink : Theme.Colors.ink3)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(isOpen ? Theme.Colors.side : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(ConversationCopy.iconHelp)
        .accessibilityLabel(ConversationCopy.iconHelp)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}
