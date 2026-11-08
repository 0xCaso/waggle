import SwiftUI

/// WAG-307: a screenshot or one screen of a set in the artifact box, with the numbered pins of the
/// comments already made on it. The pins and regions are the full size ones (`PinView`,
/// `RegionBoxView`), placed by the same normalised rect. A click on a pin selects its comment in the list.
/// WAG-323: a set's "2 / 4 screens" badge is gone; `ScreenSetBoxView` carries the arrows, dots and caption.
struct PinnedStillView: View {
    @ObservedObject var store: CommentsSessionStore
    let capture: CaptureRecord
    var fillsHeight = false

    var body: some View {
        if let image = store.imagesByCaptureId[capture.id] {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { pins }
                    .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : ArtifactPreviewPlan.cardHeight)
            }
            .frame(maxWidth: .infinity)
            .background(Theme.Colors.list)
        }
    }

    private var pins: some View {
        GeometryReader { proxy in
            let frame = CGRect(origin: .zero, size: proxy.size)
            ForEach(store.model.comments(on: capture.id)) { comment in
                let rect = CommentCaptureStageView.pointRect(for: comment.rect, in: frame)
                let isSelected = store.selectedCommentId == comment.id
                if store.showsRegion(of: comment.id) {
                    RegionBoxView(style: .committed, isSelected: isSelected)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
                PinView(number: comment.n, isSelected: isSelected)
                    .contentShape(Circle())
                    .onHover { store.pinHoverChanged(comment.id, inside: $0) }
                    .onTapGesture { store.selectComment(id: comment.id, origin: .artifact) }.pointerCursor()
                    .position(x: rect.minX, y: rect.minY)
            }
        }
    }
}
