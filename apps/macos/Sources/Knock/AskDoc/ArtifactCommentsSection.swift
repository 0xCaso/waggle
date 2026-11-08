import SwiftUI

/// WAG-307: the comment list directly under the artifact box on the case page. It is the full size
/// list (`CommentListView`) on the case's one store, so the rows, the anchors and "On other views"
/// read the same. It shows only when the case has comments; the box above carries the pins.
struct ArtifactCommentsSection: View {
    @ObservedObject var model: LiveArtifactModel
    @ObservedObject var store: CommentsSessionStore
    /// Full size, for a state the box cannot reach (an older revision of the artifact).
    let onOpenFullSize: () -> Void
    /// A box that fills the page's height keeps the list short and scrolling.
    var maxHeight: CGFloat?

    var body: some View {
        if !store.model.comments.isEmpty, let tab = model.selectedTab {
            Inner(model: model, store: store, controller: model.controller(for: tab), onOpenFullSize: onOpenFullSize, maxHeight: maxHeight)
        }
    }

    private struct Inner: View {
        @ObservedObject var model: LiveArtifactModel
        @ObservedObject var store: CommentsSessionStore
        @ObservedObject var controller: WebViewCaptureController
        let onOpenFullSize: () -> Void
        let maxHeight: CGFloat?

        var body: some View {
            let context = model.commentContext(pageView: controller.pageView)
            let isWeb = model.selectedTab.map { model.content(for: $0).isWeb } ?? false
            VStack(alignment: .leading, spacing: 8) {
                Text(ArtifactCommentsSection.heading(count: store.model.comments.count))
                    .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                    .foregroundColor(Theme.Colors.ink3)
                let list = CommentListView(
                    store: store, context: context,
                    onShow: { model.showComment($0, openFullSize: onOpenFullSize) },
                    showsEmptyState: false)
                if let maxHeight {
                    ScrollView { list }.frame(maxHeight: maxHeight).fixedSize(horizontal: false, vertical: true)
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The list names the page element a pin points at ("On the button ...") on a live page.
            .onChange(of: isWeb, initial: true) { _, live in store.showsPageElements = live }
        }
    }

    /// "COMMENTS · 2".
    static func heading(count: Int) -> String { "COMMENTS · \(count)" }
}
