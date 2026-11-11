import SwiftUI

/// The review workspace's right column once the ask already has a reply for
/// this round (docs/stories/HAIL-34.md operator report 21:37: "the review
/// workspace ignores the delivery state ... 'Open review' still opens a live
/// composer"). Replaces `ReviewBeforeSendColumnView`/`CommentsColumnView`/
/// `AskColumnView` entirely while `Case.replyLockState != .editable` and the
/// operator has not pressed "Change answer" (`SendFlowController.
/// isEditingLockedAnswer`) - Comment mode is unreachable this way, matching
/// "Comment mode is off (Interact only)".
struct AnsweredAskColumnView: View {
    let detail: CaseDetail
    @ObservedObject var sendFlow: SendFlowController
    let onRetryDelivery: () -> Void
    /// The late-comments bar of a decided shared case (WAG-401).
    var lateBar: AnyView? = nil

    @Environment(\.nudge) private var nudge

    private var knockCase: Case { detail.case }
    private var lockState: ReplyLockState { knockCase.replyLockState }

    /// The full reply record behind `latestReplyId`, for its comment list -
    /// the denormalized `Case` fields only carry the choice/message, not the
    /// pinned annotation comments.
    private var reply: Reply? {
        detail.replies.first { $0.id == knockCase.latestReplyId }
    }

    /// The chosen option's own label, `nil` when the reply carried no choice
    /// (docs/stories/HAIL-36.md) - a free-text case (no options) always
    /// reads `nil` here too, same as before this story.
    private var chosenOptionLabel: String? {
        if !knockCase.latestReplyChoices.isEmpty {
            let options = knockCase.repliedOptions
            return knockCase.latestReplyChoices
                .map { id in options.first(where: { $0.id == id })?.label ?? id }
                .joined(separator: "\n")
        }
        guard let choice = knockCase.latestReplyChoice else { return nil }
        return knockCase.repliedOptions.first(where: { $0.id == choice })?.label ?? choice
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // A done note shows its message at the head, in the column title size (WAG-333).
                    if let note = DoneNote.message(for: knockCase) {
                        AskTitleView(heading: nil, title: note, width: .narrow)
                    }
                    banner
                    lateBar
                    // A "more detail" reply carries no choice, and its
                    // message is the question asked, not an answer - the
                    // banner above already says what happened, so the
                    // read-only "YOUR ANSWER" block would just repeat the
                    // question under a misleading label (HAIL-33).
                    if lockState != .failed, knockCase.latestReplyIntent == .discuss {
                        // A discuss reply has no pick (WAG-303): no empty YOUR ANSWER block, the leans, rule-outs and message instead.
                        discussBlock
                    } else if lockState != .failed, knockCase.latestReplyIntent != .moreDetail,
                              !knockCase.isDone || knockCase.latestReplyId != nil {
                        answerBlock
                        if lockState == .delivered, let reply, !reply.comments.isEmpty {
                            commentsRecap(reply.comments)
                        }
                    }
                }
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: AskLayout.fullSizeMinColumnWidth, idealWidth: AskLayout.columnWidth, maxWidth: AskLayout.columnWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.Colors.win)
    }

    @ViewBuilder
    private var banner: some View {
        switch lockState {
        case .queued:
            queuedBanner
        case .delivered:
            deliveredBanner
        case .failed:
            if let line = RequestStatus.line(RequestStatus.Input(item: knockCase)) {
                RequestStatusLineView(line: line.keeping(only: [.retry, .copyAnswer]), item: knockCase) { action in
                    switch action {
                    case .retry: onRetryDelivery()
                    case .copyAnswer: ClaudeCheck.copyReply(for: knockCase)
                    default: break
                    }
                }
            }
        case .editable:
            EmptyView()
        }
    }

    /// "Sent · waiting for the agent to pick it up" plus "Change answer"
    /// (docs/stories/HAIL-34.md): the workspace's own copy of the case
    /// pane's `changeAnswerBar`, since the two never render into the same
    /// view tree. "Change answer" is an outlined secondary button, the same
    /// style "Ask for more detail" uses (docs/stories/HAIL-36.md amendment 1,
    /// operator: "change answer not clickable here right?") - it used to
    /// read as plain grey text.
    private var queuedBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            SentWaitingBanner(item: knockCase)

            PickupFallbackView(item: knockCase)

            SecondaryOutlineButtonView(label: "Change answer", action: sendFlow.beginChangingAnswer)
        }
    }

    private var deliveredBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(Theme.Colors.ok)
            Text(
                knockCase.isDone ? "Done · the agent finished and needs no answer" :
                "\(Nudge.wokeUp(item: knockCase, record: nudge.records[knockCase.id]) ? Nudge.deliveredLine : "Delivered · the agent has your answer") · \(KnockDateFormat.dateTime(from: knockCase.latestReplyAtDate ?? knockCase.updatedAtDate ?? Date()))"
            )
            .knockTextStyle(Theme.Typography.buttonSm12_5w600)
            .foregroundColor(Theme.Colors.ok)
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.okSoft)
        .cornerRadius(Theme.Radius.deliveryBanner)
    }

    /// The leans, rule-outs and message of a discuss reply, read-only.
    private var discussBlock: some View {
        let answer = SentAnswerCopy.answer(for: knockCase, reply: reply)
        return VStack(alignment: .leading, spacing: 4) {
            Text(answer.label)
                .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                .foregroundColor(Theme.Colors.ink3)
            Text(answer.title)
                .knockTextStyle(Theme.Typography.value13_5w600)
                .foregroundColor(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let note = answer.note {
                AgentMarkdownText(text: note, style: Theme.Typography.replyNote13w400, color: Theme.Colors.ink2)
            }
            SentAttachmentsView(files: reply?.attachments ?? [])
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.recommendedBlock)
    }

    /// "Your answer" read-only recap - the same visual recipe as
    /// `ReviewBeforeSendColumnView.replyBlock`, reused here since both show
    /// one reply's choice and note.
    private var answerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !knockCase.options.isEmpty, chosenOptionLabel == nil {
                // A message-only reply to an options ask (docs/stories/
                // HAIL-36.md: no choice was sent) - stacked so the full
                // message wraps under its own label instead of being
                // squeezed inline next to it, the way a short option label
                // is below.
                Text("YOUR ANSWER")
                    .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                    .foregroundColor(Theme.Colors.ink3)
                Text(knockCase.latestReplyMessage ?? "")
                    .knockTextStyle(Theme.Typography.value13_5w600)
                    .foregroundColor(Theme.Colors.ink)
            } else {
                HStack(spacing: 6) {
                    Text("YOUR ANSWER")
                        .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                        .foregroundColor(Theme.Colors.ink3)
                    Text(knockCase.latestReplyWithChangesWords ?? chosenOptionLabel ?? knockCase.latestReplyMessage ?? "")
                        .knockTextStyle(Theme.Typography.value13_5w600)
                        .foregroundColor(Theme.Colors.ink)
                        .textSelection(.enabled)
                }
                // "With a choice AND a message, show both" (docs/stories/
                // HAIL-36.md) - only once there is a choice; the free-text
                // (no options) branch above already put the message in the
                // value itself.
                if chosenOptionLabel != nil, let message = knockCase.latestReplyMessage, !message.isEmpty {
                    AgentMarkdownText(text: message, style: Theme.Typography.replyNote13w400, color: Theme.Colors.ink2)
                }
            }
            SentAttachmentsView(files: reply?.attachments ?? []).padding(.top, 4)
            if lockState == .queued, let reply, !reply.comments.isEmpty {
                Text("\(reply.comments.count) comment\(reply.comments.count == 1 ? "" : "s")")
                    .knockTextStyle(Theme.Typography.commentsSectionLabel11w600)
                    .foregroundColor(Theme.Colors.ink3)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.recommendedBlock)
    }

    /// Delivered-only: the pinned annotation comments themselves, listed
    /// read-only (docs/stories/HAIL-34.md: "comments listed read-only") -
    /// text only, no thumbnail, since re-rendering the annotated capture
    /// image this reply was sent against needs the artifact revision it was
    /// taken from, not just the comment text this reply already carries.
    private func commentsRecap(_ comments: [Comment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(comments.count) comment\(comments.count == 1 ? "" : "s")")
                .knockTextStyle(Theme.Typography.commentsSectionLabel11w600)
                .foregroundColor(Theme.Colors.ink3)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(comments) { comment in
                    HStack(alignment: .top, spacing: 8) {
                        PinView(number: comment.n, size: Theme.Spacing.pinSmall)
                        VStack(alignment: .leading, spacing: 2) {
                            // WAG-357: a comment on the request says which part and which words.
                            if let ask = comment.askAnchor {
                                Text("\(ask.part.onWords) · \"\(ask.quote)\"")
                                    .knockTextStyle(Theme.Typography.monoMeta11w400)
                                    .foregroundColor(Theme.Colors.ink3)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                            Text(comment.text)
                                .knockTextStyle(Theme.Typography.reviewNoteText12w400)
                                .foregroundColor(Theme.Colors.ink2)
                        }
                    }
                }
            }
        }
    }
}
