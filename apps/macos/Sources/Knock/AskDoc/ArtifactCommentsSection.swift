import SwiftUI

/// The Comments tab of the case pane (C8, task 8; WAG-307 before it sat under the artifact box): the full size list
/// (`CommentListView`) on the case's one store, so the rows, the anchors and "On other views" read the same, with the
/// team's threads when the case is shared. Show on a card highlights its pin in the artifact box.
struct ArtifactCommentsSection: View {
    @ObservedObject var model: LiveArtifactModel
    @ObservedObject var store: CommentsSessionStore
    var sharing: SharingModel? = nil
    /// Full size, for a state the box cannot reach (an older revision of the artifact).
    let onOpenFullSize: () -> Void

    var body: some View {
        if let tab = model.selectedTab {
            Inner(model: model, store: store, controller: model.controller(for: tab), sharing: sharing, onOpenFullSize: onOpenFullSize)
        } else {
            // No artifact box (a text ask): comments on the request's text, with no page to point at.
            CommentListView(store: store, context: .unknown, sharing: sharing, emptyLine: CommentListModel.textAskEmptyLine)
        }
    }

    private struct Inner: View {
        @ObservedObject var model: LiveArtifactModel
        @ObservedObject var store: CommentsSessionStore
        @ObservedObject var controller: WebViewCaptureController
        let sharing: SharingModel?
        let onOpenFullSize: () -> Void

        var body: some View {
            let context = model.commentContext(pageView: controller.pageView)
            let isWeb = model.selectedTab.map { model.content(for: $0).isWeb } ?? false
            CommentListView(
                store: store, context: context,
                onShow: { model.showComment($0, openFullSize: onOpenFullSize) },
                sharing: sharing)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The list names the page element a pin points at ("On the button ...") on a live page.
                .onChange(of: isWeb, initial: true) { _, live in store.showsPageElements = live }
        }
    }
}

/// "2 comments on v1 · view v1" (docs/design/mvp-values.md §M9 `E0OSB`): the comments you left on the revision
/// before this one, and a link that shows that revision read-only.
struct PriorRevisionCommentsLink: View {
    let arrival: RevisionArrival
    let action: () -> Void
    var leadingPadding: CGFloat = 0

    static func text(_ arrival: RevisionArrival) -> String {
        let n = arrival.priorCommentCount
        return "\(n) comment\(n == 1 ? "" : "s") on v\(arrival.priorRevision) · view v\(arrival.priorRevision)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 12))
                .foregroundColor(Theme.Colors.ink3)
            Text(Self.text(arrival))
                .knockTextStyle(Theme.Typography.priorRevisionLink12w500)
                .foregroundColor(Theme.Colors.ink2)
        }
        .padding(.leading, leadingPadding)
        .contentShape(Rectangle())
        .onTapGesture(perform: action).pointerCursor()
        .accessibilityAddTraits(.isButton)
    }
}
