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
    /// False in the case pane: its context line holds the status line (C10), so the footer draws none.
    var showsStatus: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if deliveryState.state == .idle {
                if composer.isAskingForDetail {
                    // The "Ask for…" panel scrolls inside its cap, so the send row under it stays on screen (C5).
                    ScrollView {
                        AskForDetailPanelView(
                            composer: composer,
                            onSend: { sendFlow.askForMoreDetail() },
                            onSendFormat: { sendFlow.askForMoreDetail(format: $0) },
                            onQuickReply: { sendFlow.quickReply($0) },
                            hasComments: sendFlow.pinnedCommentCount > 0
                        )
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { panelHeight = $0 }
                    }
                    .frame(height: min(max(panelHeight, 1), Self.panelCap(availableHeight: availableHeight)))
                    .scrollBounceBehavior(.basedOnSize)
                    Rectangle().fill(Theme.Colors.line).frame(height: 1)
                } else if let suggestion {
                    suggestedReplyCard(suggestion)
                }
                // One prompt bar (HAIL-77): attach, "Ask for…", the growing reply field, Open review and Send.
                PromptBarView(
                    composer: composer,
                    draft: composer.draft,
                    sendFlow: sendFlow,
                    files: composer.files,
                    commentCount: commentCount,
                    placeholder: placeholder,
                    onOpenReview: onOpenReview,
                    suggestedReply: composer.isAskingForDetail ? nil : suggestion?.text,
                    isFocused: $isDraftFocused
                )
            } else {
                if showsStatus, let line = RequestStatus.localLine(deliveryState.state, item: composer.knockCase) {
                    RequestStatusLineView(line: line, onAction: { if $0 == .retry { Task { await sendFlow.retryDelivery() } } })
                        .padding(14)
                }
            }
        }
        // The same answer area as the options card (mockup `.ans`): full width, one plain 1 pt `line` on top, no shadow.
        .boundedIdealWidth()
        .background(inputBackground)
        .overlay(
            Rectangle().fill(showsTopDivider ? Theme.Colors.line : .clear).frame(height: 1),
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

    @State private var panelHeight: CGFloat = 0
    /// Height of the column or pane the footer sits in.
    @Environment(\.answerBoxAvailableHeight) private var availableHeight

    /// The tallest the "Ask for…" panel gets in a footer before it scrolls: 45 % of the column, at least 160 pt.
    static func panelCap(availableHeight: CGFloat?) -> CGFloat {
        guard let availableHeight, availableHeight > 0, availableHeight.isFinite else { return 360 }
        return max((availableHeight * 0.45).rounded(.down), 160)
    }

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

    /// The suggestion and why the agent gives it. "Use this reply" is in the send row (spec section 9).
    private func suggestedReplyCard(_ suggestion: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.suggestedReplyLabel)
                .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                .foregroundColor(Theme.Colors.honey600)
            AgentMarkdownText(text: suggestion.text, style: Theme.Typography.body13w400)
                .foregroundColor(Theme.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let why = suggestion.why { CalmNoteView(title: "Why I recommend it", text: why) }
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
        Button(action: action) {
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
        }
        .buttonStyle(.pressable).pointerCursor()
    }
}
