import SwiftUI

/// WAG-280: the case's comments as the same numbered list the review's Comments column shows, for the
/// surfaces that have no right column (the panel beside the questions, the full Waggle page, the own
/// window). It reads the one store of the case, so a comment made on any surface shows here. WAG-307:
/// it is the one `CommentListView`, in a scroll box.
struct CaseCommentsListView: View {
    @ObservedObject var store: CommentsSessionStore
    var context = CommentViewContext.unknown
    var onShow: (Comment) -> Void = { _ in }
    var onSelect: (Comment) -> Void = { _ in }

    var body: some View {
        ScrollView {
            CommentListView(store: store, context: context, onShow: onShow, onSelect: onSelect)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 360)
        .frame(maxHeight: 420)
        .background(Theme.Colors.win)
    }
}
