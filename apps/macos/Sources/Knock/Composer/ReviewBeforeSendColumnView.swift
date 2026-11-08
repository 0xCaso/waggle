import SwiftUI

/// The review-before-send column (docs/design/mvp-values.md §M6 `Ea8Gs` →
/// `sjkjg`): "You're sending", the REPLY block, the annotated capture
/// thumbnail with its numbered notes, the destination row, and the final
/// Send / Keep editing actions. Replaces `AskColumnView`/`CommentsColumnView`
/// while `SendFlowController.isReviewingBeforeSend` is true.
struct ReviewBeforeSendColumnView: View {
    @ObservedObject var sendFlow: SendFlowController
    /// `sendFlow.deliveryState` itself, observed separately - see the same
    /// note on `ComposerFooterView.deliveryState`: a nested `ObservableObject`
    /// does not propagate its own `@Published` changes through its owner's
    /// `objectWillChange`.
    @ObservedObject var deliveryState: DeliveryStateViewModel
    let task: KnockTask

    init(sendFlow: SendFlowController, task: KnockTask) {
        self.sendFlow = sendFlow
        self.deliveryState = sendFlow.deliveryState
        self.task = task
    }

    private var captures: [SendFlowController.CaptureReviewSummary] { sendFlow.capturesForReview }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("You're sending")
                        .knockTextStyle(Theme.Typography.sendHeading17w650)
                        .foregroundColor(Theme.Colors.ink)

                    replyBlock

                    // HAIL-35 fold: every capture that will be sent gets its
                    // own section - the payload already sends one annotated
                    // image per capture that has comments, so this must show
                    // all of them, not only the one currently on the stage.
                    ForEach(captures) { capture in
                        commentsSection(for: capture)
                    }

                    destinationRow
                }
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer
        }
        .frame(minWidth: 340, idealWidth: 430, maxWidth: 430)
        .frame(maxHeight: .infinity)
        .background(Theme.Colors.win)
    }

    private var replyBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("REPLY")
                    .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                    .foregroundColor(Theme.Colors.ink3)
                Text(sendFlow.pendingReplyValue)
                    .knockTextStyle(Theme.Typography.value13_5w600)
                    .foregroundColor(Theme.Colors.ink)
            }
            if let note = sendFlow.pendingReplyNote, !note.isEmpty {
                Text(note)
                    .knockTextStyle(Theme.Typography.replyNote13w400)
                    .foregroundColor(Theme.Colors.ink2)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.recommendedBlock)
    }

    private func commentsSection(for capture: SendFlowController.CaptureReviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(capture.comments.count) comment\(capture.comments.count == 1 ? "" : "s") on \(sendFlow.captureLabel(for: capture.capture))")
                .knockTextStyle(Theme.Typography.commentsSectionLabel11w600)
                .foregroundColor(Theme.Colors.ink3)
            HStack(alignment: .top, spacing: 12) {
                thumbnail(for: capture)
                notesList(for: capture)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for capture: SendFlowController.CaptureReviewSummary) -> some View {
        if let image = capture.thumbnail {
            let aspect = image.size.height / max(image.size.width, 1)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Theme.Spacing.reviewThumbnailWidth, height: Theme.Spacing.reviewThumbnailWidth * aspect)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.reviewThumbnail))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.reviewThumbnail)
                        .stroke(Theme.Stroke.card.color, lineWidth: Theme.Stroke.card.width)
                )
        }
    }

    private func notesList(for capture: SendFlowController.CaptureReviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(capture.comments) { comment in
                HStack(alignment: .top, spacing: 8) {
                    PinView(number: comment.n, size: Theme.Spacing.pinSmall)
                    Text(comment.text)
                        .knockTextStyle(Theme.Typography.reviewNoteText12w400)
                        .foregroundColor(Theme.Colors.ink2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var destinationRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right")
                .font(.system(size: 14))
                .foregroundColor(Theme.Colors.ink2)
            Text("Goes to: \(task.name) · \(sendFlow.knockCase.runtimeLabel) in ~/\(task.project)")
                .knockTextStyle(Theme.Typography.destinationRow12w500)
                .foregroundColor(Theme.Colors.ink2)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.recommendedBlock)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if deliveryState.state == .idle {
                // Both actions on one row, left aligned (docs/stories/
                // HAIL-34.md operator report 21:35): "Keep editing" used to
                // sit centred under the full-width Send button.
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Text(sendLabel)
                            .knockTextStyle(Theme.Typography.button13_5w600)
                            .foregroundColor(Theme.Colors.win)
                        Text("⌘↵")
                            .knockTextStyle(Theme.Typography.keyHint11_5w400)
                            .foregroundColor(Theme.Colors.win.opacity(0.7))
                    }
                    .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                    .background(Theme.Colors.ink)
                    .cornerRadius(Theme.Radius.buttonPrimary)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await sendFlow.confirmSend() } }.pointerCursor()

                    Text("Keep editing")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                        .foregroundColor(Theme.Colors.ink2)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: sendFlow.keepEditing).pointerCursor()

                    Spacer(minLength: 0)
                }
            } else {
                DeliveryBannerView(
                    state: deliveryState.state,
                    replySummary: sendFlow.deliveryReplySummary,
                    onRetry: { Task { await sendFlow.retryDelivery() } }
                )
            }
        }
        .padding(EdgeInsets(top: 14, leading: 24, bottom: 18, trailing: 24))
        .overlay(
            Rectangle().fill(Theme.Colors.line).frame(height: 1),
            alignment: .top
        )
        .background(
            Button("Send", action: { Task { await sendFlow.confirmSend() } })
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
        )
    }

    private var sendLabel: String {
        let count = sendFlow.totalCommentCountForReview
        return count == 0 ? "Send reply" : "Send reply + \(count) comment\(count == 1 ? "" : "s")"
    }
}
