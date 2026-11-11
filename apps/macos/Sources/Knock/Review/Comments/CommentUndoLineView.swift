import SwiftUI

/// "Comment deleted · Undo": a quiet line for 5 s after a comment is deleted. `CommentsSessionStore` owns the
/// timer (`commentUndo` clears itself); this view only shows it.
struct CommentUndoLineView: View {
    @ObservedObject var store: CommentsSessionStore

    var body: some View {
        Group {
            if store.commentUndo != nil {
                HStack(spacing: 6) {
                    Text("Comment deleted ·")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                        .foregroundColor(Theme.Colors.ink2)
                    Button(action: store.undoDeleteComment) {
                        Text("Undo")
                            .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                            .foregroundColor(Theme.Colors.ink)
                            .underline()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
                .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                .background(Theme.Colors.win)
                .cornerRadius(Theme.Radius.buttonSmall)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall).stroke(Theme.Colors.line2, lineWidth: 1))
                .padding(.bottom, 16)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.commentUndo != nil)
    }
}
