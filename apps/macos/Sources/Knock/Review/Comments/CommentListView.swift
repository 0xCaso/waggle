import SwiftUI

/// WAG-307: the one comment list. Full size (the Comments tab, the window's popover) and the case
/// page, under the artifact box, all draw it: same rows (number, text, anchor, state), same empty
/// state. Comments with a pin on screen come first; a comment whose page state is gone is listed
/// under "On other views" with a Show button.
struct CommentListView: View {
    @ObservedObject var store: CommentsSessionStore
    let context: CommentViewContext
    /// Show on a row of "On other views".
    var onShow: (Comment) -> Void = { _ in }
    var onSelect: (Comment) -> Void = { _ in }
    /// The case page shows the list only when there is something to list; full size shows the empty state.
    var showsEmptyState = true
    /// WAG-397: the shared case, so the team thread joins the list. Nil: only your notes, as before.
    var sharing: SharingModel? = nil

    var body: some View {
        let list = CommentListModel.make(model: store.model, context: context, isScreenshotsCase: store.isScreenshotsCase)
        let threads = sharing?.threads ?? []
        let shared = sharing?.isShared ?? false
        VStack(alignment: .leading, spacing: 12) {
            if list.isEmpty && threads.isEmpty && store.draftPin == nil {
                if showsEmptyState {
                    Text(shared ? MergedComments.sharedEmptyLine : CommentListModel.emptyLine)
                        .knockTextStyle(Theme.Typography.body13w400)
                        .foregroundColor(Theme.Colors.ink2)
                }
            }
            if let sharing, MergedComments.showsLabels(isShared: shared, threads: threads) {
                mergedList(list: list, threads: threads, sharing: sharing)
            } else {
                notesOnly(list)
            }
        }
    }

    /// WAG-397: the team's threads and your notes in one list, each with its label.
    @ViewBuilder
    private func mergedList(list: CommentListModel, threads: [CommentThread], sharing: SharingModel) -> some View {
        ForEach(MergedComments.entries(local: list.rows, threads: threads)) { entry in
            switch entry {
            case .thread(let thread):
                CommentThreadView(model: sharing, thread: thread, showsLabels: true).transition(.opacity)
            case .local(let row):
                VStack(alignment: .leading, spacing: 6) {
                    CommentLabelChip(text: MergedComments.youLabel)
                    card(row)
                }
            }
        }
        if let draft = store.draftPin {
            DraftingCommentCardView(number: store.nextPinNumber, text: draft.text)
        }
    }

    @ViewBuilder
    private func notesOnly(_ list: CommentListModel) -> some View {
        Group {
            ForEach(list.onView) { row in card(row) }
            if let draft = store.draftPin {
                DraftingCommentCardView(number: store.nextPinNumber, text: draft.text)
            }
            if !list.otherViews.isEmpty {
                Text(CommentListModel.otherViewsTitle.uppercased())
                    .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                    .foregroundColor(Theme.Colors.ink3)
                    .padding(.top, list.onView.isEmpty ? 0 : 6)
                ForEach(list.otherViews) { row in card(row) }
            }
        }
    }

    private func card(_ row: CommentRow) -> some View {
        let comment = row.comment
        return CommentCardView(
            comment: comment,
            isSelected: store.selectedCommentId == comment.id,
            elementLabel: store.elementLabel(for: comment),
            anchorLabel: row.anchorLabel,
            onShow: row.isOffView ? { onShow(comment) } : nil,
            notice: store.showNotice?.commentId == comment.id ? store.showNotice?.text : nil,
            onSelect: {
                if row.isOffView { onShow(comment) } else { store.selectComment(id: comment.id, origin: .list) }
                onSelect(comment)
            },
            onEditingChanged: { store.editingCommentId = $0 ? comment.id : nil },
            onEditText: { store.updateComment(id: comment.id, text: $0) },
            onDelete: { store.deleteComment(id: comment.id) }
        )
        .id(comment.id)
    }
}
