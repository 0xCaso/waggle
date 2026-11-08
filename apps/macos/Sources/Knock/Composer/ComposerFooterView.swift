import SwiftUI

/// The composer's footer: Accept-recommendation/Send-recommended-answer
/// (docs/design/mvp-values.md §M7 panels A/B) when there are no comments
/// yet, or the free-text field plus an explicit Send button once there are
/// (§M7 panel C) - shared by `AskColumnView` (Interact mode) and
/// `CommentsColumnView` (Comment mode) so the comment count and the send
/// action stay one truth regardless of which column is on screen.
struct ComposerFooterView: View {
    @ObservedObject var composer: ComposerViewModel
    @ObservedObject var sendFlow: SendFlowController
    /// `sendFlow.deliveryState` itself, observed separately: a nested
    /// `ObservableObject`'s own `@Published` changes do not propagate through
    /// its owner's `objectWillChange` (`SendFlowController` never republishes
    /// it), so this view needs its own subscription to notice a
    /// sending/delivered/offline/failed transition - the same pattern
    /// `CommentsColumnView` already uses for `store`/`composer`/`sendFlow` as
    /// three separate `@ObservedObject`s rather than reaching through one.
    @ObservedObject var deliveryState: DeliveryStateViewModel
    let commentCount: Int
    let placeholder: String
    var inputBackground: Color = Theme.Colors.win
    /// "Open review ↵", shown beside "Ask for more detail" only when set
    /// (HAIL-41): the case pane's own escape hatch to the full review
    /// workspace for a review-kind ask, since the pane never offers pins or
    /// Comment mode (Non-goal). `nil` for every other composer host - the
    /// review workspace's own Interact/Comment columns already show the
    /// full workspace and never need a link back to themselves.
    var onOpenReview: (() -> Void)? = nil
    /// False when the case pane's answer dock sits right above this footer
    /// (the dock draws the one top line for both).
    var showsTopDivider: Bool = true
    /// Focus target for the draft field (docs/stories/HAIL-25.md: `Open
    /// review` from the case pane, or an option that reads as a change
    /// request, should land the friend straight in this field).
    @State private var isDraftFocused = false
    /// Tallest the reply field grows, in lines, before it scrolls inside
    /// (HAIL-77): 6 in the case pane, 4 in the review workspace's column.
    var maxReplyLines: Int = PromptBarLogic.paneMaxLines
    /// False in the case pane: its top banner owns a failed outcome (WAG-258).
    var showsFailure: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if deliveryState.state == .idle {
                if composer.isAskingForDetail {
                    AskForDetailPanelView(
                        composer: composer,
                        onSend: { sendFlow.askForMoreDetail() },
                        onSendFormat: { sendFlow.askForMoreDetail(format: $0) }
                    )
                } else {
                    if let suggestion { suggestedReplyCard(suggestion) }
                    if showsAskRow {
                        // The same last row the options list has (WAG-336), not a text button in the field.
                        AskForDetailRowView(
                            composer: composer, onSend: { sendFlow.askForMoreDetail() },
                            onSendFormat: { sendFlow.askForMoreDetail(format: $0) },
                            onQuickReply: { sendFlow.quickReply($0) }, hasComments: sendFlow.pinnedCommentCount > 0)
                    }
                    // One prompt bar (HAIL-77): attach, the growing reply
                    // field, Ask for more detail, Open review and Send.
                    PromptBarView(
                        composer: composer,
                        draft: composer.draft,
                        sendFlow: sendFlow,
                        files: composer.files,
                        commentCount: commentCount,
                        placeholder: placeholder,
                        maxLines: maxReplyLines,
                        showsDetailButton: !showsAskRow,
                        onOpenReview: onOpenReview,
                        isFocused: $isDraftFocused
                    )
                }
            } else {
                DeliveryBannerView(
                    state: deliveryState.state,
                    replySummary: sendFlow.deliveryReplySummary,
                    onRetry: { Task { await sendFlow.retryDelivery() } },
                    showsFailure: showsFailure
                )
                .padding(14)
            }
        }
        // The same dock as the options card: full width, a top line and a soft shadow up (WAG-305).
        .boundedIdealWidth()
        .background(inputBackground.shadow(Theme.Shadow.dockUp))
        .overlay(
            Rectangle().fill(showsTopDivider ? Theme.Colors.line2 : .clear).frame(height: 1),
            alignment: .top
        )
        .background(
            Group {
                if commentCount == 0, !composer.isAskingForDetail {
                    Button("Accept recommendation") { sendFlow.acceptRecommendation(via: .shortcut) }
                        .keyboardShortcut("d", modifiers: .command)
                }
                // The detail panel wires its own ⌘↵ while it is open.
                if !composer.isAskingForDetail {
                    Button("Send", action: sendFlow.send)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .opacity(0)
        )
        .onAppear(perform: consumeFocusRequestIfNeeded)
        .onChange(of: composer.focusDraftOnOpen) { _, requested in
            if requested { consumeFocusRequestIfNeeded() }
        }
    }

    /// A reply-only ask has no options, so "Ask for more detail" is a row here, like the last row of an options list.
    private var showsAskRow: Bool { !composer.isOptionsCase }

    /// The agent's suggested reply (WAG-336): shown while the field is empty and only on a reply-only ask.
    private var suggestion: ComposerFooterView.Suggestion? {
        Self.suggestion(for: composer.knockCase, draftIsEmpty: composer.currentMessage == nil)
    }

    struct Suggestion: Equatable {
        let text: String
        let why: String?
    }

    static func suggestion(for item: Case, draftIsEmpty: Bool) -> Suggestion? {
        guard item.options.isEmpty, draftIsEmpty else { return nil }
        let text = item.recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let why = AgentMarkdown.singleLine(item.recommendationWhy)
        return Suggestion(text: text, why: why.isEmpty ? nil : why)
    }

    static let suggestedReplyLabel = "SUGGESTED REPLY"
    static let useSuggestedReply = "Use this reply"

    /// Filling the field is the person's act; nothing sends until they press the button (WAG-328).
    private func suggestedReplyCard(_ suggestion: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.suggestedReplyLabel)
                .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                .foregroundColor(Theme.Colors.honey600)
            AgentMarkdownText(text: suggestion.text, style: Theme.Typography.body13w400)
                .foregroundColor(Theme.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let why = suggestion.why { CalmNoteView(title: "Why I recommend it", text: why) }
            Button(Self.useSuggestedReply) { composer.draftText = suggestion.text; isDraftFocused = true }
                .buttonStyle(.plain).pointerCursor()
                .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                .foregroundColor(Theme.Colors.ink)
                .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .background(Theme.Colors.honeySoft)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall).stroke(Theme.Colors.honey500.opacity(0.6), lineWidth: 1))
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
    }

    private func consumeFocusRequestIfNeeded() {
        guard composer.focusDraftOnOpen else { return }
        composer.focusDraftOnOpen = false
        isDraftFocused = true
    }
}

/// An outlined secondary button (docs/design/mvp-values.md §2.8), the same
/// visual recipe "Ask for more detail" above uses. Shared with "Change
/// answer" in the pane's queued footer and the review workspace's queued
/// banner (docs/stories/HAIL-36.md amendment 1, operator: "change answer not
/// clickable here right?") - it read as grey text with a tap gesture, not a
/// button, there.
struct SecondaryOutlineButtonView: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Text(label)
            .knockTextStyle(Theme.Typography.buttonSm12_5w500)
            .foregroundColor(Theme.Colors.ink)
            .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
            .background(Theme.Colors.win)
            .cornerRadius(Theme.Radius.buttonSmall)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall)
                    .stroke(Theme.Colors.line2, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action).pointerCursor()
    }
}
