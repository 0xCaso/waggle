import SwiftUI
import AppKit

/// Comment mode's region and pin layer over the live prototype (HAIL-65).
///
/// The prototype's `WKWebView` stays mounted underneath and is never touched:
/// this layer only catches a drag or click (to place a region), and draws the
/// saved regions, the region being drafted and its note popover. It draws no
/// dim and no image, so with no pins to show, switching tools changes nothing
/// on screen. Rects are 0...1 of this layer's own frame, which is the
/// prototype's frame (same padding), so they match the viewport snapshot that
/// `ReviewViewModel.beginLiveDraft` takes in the background.
///
/// HAIL-75: pins and boxes of EVERY capture of this revision are drawn, each
/// mapped from its capture's viewport to page coordinates
/// (`CommentPageMapping`) and back to where the page is scrolled and zoomed
/// now, so they follow the page. A click on a pin highlights that comment.
struct LiveCommentLayerView: View {
    @ObservedObject var store: CommentsSessionStore
    @ObservedObject var controller: WebViewCaptureController
    /// Only captures of this revision are drawn.
    let revision: Int
    /// Interact mode (HAIL-87): the pins stay drawn, but the layer catches
    /// nothing outside a pin, so clicks and scrolls reach the page.
    var isInteractive = false
    /// A region was dragged; the second value is the page position at that moment.
    let onBeginDraft: (Rect, PageViewport?, UsageVariant) -> Void
    let onSave: () -> Void
    /// HAIL-103: bring the page to the view a comment was made on.
    var onJump: (Comment) -> Void = { _ in }

    @State private var dragStart: CGPoint?
    @State private var draggingRect: CGRect?
    @State private var hoverPoint: CGPoint?
    @State private var crosshairPushed = false
    @State private var hasPlacedComment = CommentCursorTag.hasPlacedComment()

    /// Comments on this revision's captures, in number order.
    private var allComments: [Comment] { store.model.comments(onRevision: revision) }

    /// HAIL-103: only the comments made on the view the page shows now.
    private var comments: [Comment] {
        allComments.filter { PageView.shows(comment: store.model.view(of: $0), current: controller.pageView) }
    }

    /// Each comment's rect in the layer right now (page-mapped, scroll- and zoom-aware).
    private func layerRects(size: CGSize) -> [String: CGRect] {
        let current = controller.pageViewport
        var result: [String: CGRect] = [:]
        for comment in comments {
            let capture = store.model.captures.first { $0.id == comment.captureId }
            result[comment.id] = CommentPageMapping.layerRect(for: comment.rect, capture: capture?.page, current: current, layerSize: size)
        }
        return result
    }

    /// The draft's rect in the layer: it follows the page like a saved pin
    /// once its capture's viewport is known, so a scroll or a zoom while the
    /// note is open keeps it on the spot it marks.
    private func draftLayerRect(_ draft: DraftPin, frame: CGRect) -> CGRect {
        let capture = store.pending?.id == draft.captureId
            ? store.pending?.page
            : store.model.captures.first { $0.id == draft.captureId }?.page
        guard let capture, let current = controller.pageViewport else {
            return CommentCaptureStageView.pointRect(for: draft.rect, in: frame)
        }
        return CommentPageMapping.layerRect(for: draft.rect, capture: capture, current: current, layerSize: frame.size)
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .topLeading) {
                if !isInteractive {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragGesture(frame: frame))
                }
                let rects = layerRects(size: proxy.size)
                ForEach(comments) { comment in
                    if let rect = rects[comment.id], CommentPageMapping.regionIsVisible(rect, in: proxy.size) {
                        let isSelected = store.selectedCommentId == comment.id
                        if store.showsRegion(of: comment.id) {
                            RegionBoxView(style: .committed, isSelected: isSelected)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                        }
                        if CommentPageMapping.pinIsVisible(rect, in: proxy.size) {
                            PinView(number: comment.n, isSelected: isSelected)
                                .contentShape(Circle())
                                .onHover { store.pinHoverChanged(comment.id, inside: $0) }
                                .onTapGesture { if store.draftPin == nil { store.selectComment(id: comment.id, origin: .artifact) } }.pointerCursor()
                                .position(x: rect.minX, y: rect.minY)
                        }
                    }
                }
                if store.draftPin == nil {
                    cardOverlay(rects: rects, size: proxy.size)
                }
                if let draggingRect {
                    RegionBoxView(style: .drafting, showsHandles: true)
                        .frame(width: draggingRect.width, height: draggingRect.height)
                        .position(x: draggingRect.midX, y: draggingRect.midY)
                        .allowsHitTesting(false)
                }
                if let draft = store.draftPin {
                    draftOverlay(draft, frame: frame)
                }
                if !isInteractive { cursorTag }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .task { await controller.trackPageViewport() }
            .task { await controller.trackPageView() }
            .onChange(of: store.revealRequest) { _, request in
                guard let request, request.origin == .list else { return }
                if let target = allComments.first(where: { $0.id == request.commentId }),
                   !PageView.shows(comment: store.model.view(of: target), current: controller.pageView) {
                    onJump(target)
                }
                reveal(request.commentId, size: proxy.size)
            }
            // Comment mode only: a hover region covers the whole layer, and in
            // Interact mode that made the layer catch every click and scroll
            // meant for the page at 100% (operator, 4 Oct: a prototype only
            // responded after a zoom change removed this layer).
            .onContinuousHover(isEnabled: !isInteractive) { phase in
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    if !crosshairPushed { NSCursor.crosshair.push(); crosshairPushed = true }
                case .ended:
                    hoverPoint = nil
                    popCrosshair()
                }
            }
            .onChange(of: isInteractive) { _, interactive in
                if interactive { hoverPoint = nil; popCrosshair() }
            }
            .onDisappear { popCrosshair() }
        }
    }

    /// The open comment's inline card, or the hovered comment's preview,
    /// anchored beside its pin.
    @ViewBuilder
    private func cardOverlay(rects: [String: CGRect], size: CGSize) -> some View {
        if let id = store.openCommentId, let comment = comments.first(where: { $0.id == id }),
           let rect = rects[id], CommentPageMapping.pinIsVisible(rect, in: size) {
            InlineCommentCardView(
                number: comment.n, text: comment.text,
                onSave: { store.saveComment(id: id, text: $0) },
                onDelete: { store.deleteCommentWithUndo(id: id) },
                onClose: { store.closeComment() }
            )
            .id(id)
            .position(CommentCaptureStageView.popoverPosition(for: Self.pinFrame(rect), in: size, height: CommentCaptureStageView.editCardHeight))
        } else if let id = store.previewCommentId, let comment = comments.first(where: { $0.id == id }),
                  let rect = rects[id], CommentPageMapping.pinIsVisible(rect, in: size) {
            CommentHoverPreviewView(text: comment.text)
                .frame(width: Theme.Spacing.notePopoverWidth)
                .position(CommentCaptureStageView.popoverPosition(for: Self.pinFrame(rect), in: size, height: CommentCaptureStageView.previewHeight))
        }
    }

    private static func pinFrame(_ rect: CGRect) -> CGRect {
        let d = Theme.Spacing.pinLarge
        return CGRect(x: rect.minX - d / 2, y: rect.minY - d / 2, width: d, height: d)
    }

    /// A click on a list card: scroll the page so that comment's pin is in view.
    private func reveal(_ commentId: String, size: CGSize) {
        guard let comment = allComments.first(where: { $0.id == commentId }),
              let capture = store.model.captures.first(where: { $0.id == comment.captureId }) else { return }
        // Page space is CSS px, so the viewport is the page's own (the layer
        // size divided by the zoom), not the layer's points.
        let current = controller.pageViewport
        let page = CommentPageMapping.currentPageRect(for: comment.rect, capture: capture.page, current: current, layerSize: size)
        let scroll = current?.scroll ?? .zero
        guard let target = CommentPageMapping.scrollTarget(forPageRect: page, scroll: scroll, viewport: current?.size ?? size) else { return }
        Task { await controller.scrollPage(to: target) }
    }

    private func popCrosshair() {
        if crosshairPushed { NSCursor.pop(); crosshairPushed = false }
    }

    @ViewBuilder
    private var cursorTag: some View {
        let point = CanvasToolHintEvidence.pinsCursorTag() ? CanvasToolHintEvidence.cursorPoint : hoverPoint
        if let point, draggingRect == nil, store.draftPin == nil,
           CommentCursorTag.isVisible(mode: .comment, hasPlacedComment: hasPlacedComment) {
            CommentCursorTagView()
                .offset(x: point.x + 14, y: point.y + 16)
                .allowsHitTesting(false)
        }
    }

    private func draftOverlay(_ draft: DraftPin, frame: CGRect) -> some View {
        let rect = draftLayerRect(draft, frame: frame)
        let number = store.nextPinNumber
        return Group {
            RegionBoxView(style: .drafting, showsHandles: true)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
            PinView(number: number)
                .position(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
            NotePopoverView(
                pinNumber: number,
                targetLabel: "region",
                text: Binding(
                    get: { store.draftPin?.text ?? "" },
                    set: { store.updateDraftText($0) }
                ),
                onSave: {
                    onSave()
                    CommentCursorTag.markPlaced()
                    hasPlacedComment = true
                },
                onCancel: { store.cancelDraft() }
            )
            .position(CommentCaptureStageView.popoverPosition(for: rect, in: frame.size, height: NoteFieldLogic.popoverHeight(text: store.draftPin?.text ?? "")))
        }
    }

    private func dragGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard store.draftPin == nil else { return }
                if dragStart == nil { dragStart = value.startLocation }
                guard let start = dragStart else { return }
                draggingRect = Self.rect(from: start, to: value.location).intersection(frame)
            }
            .onEnded { value in
                defer { dragStart = nil; draggingRect = nil }
                guard store.draftPin == nil, let start = dragStart else { return }
                let pointRect: CGRect
                let isClick = hypot(value.location.x - start.x, value.location.y - start.y) < 4
                if isClick {
                    // A click on a saved pin highlights it instead of placing a new one.
                    if let hit = CommentPageMapping.pinHit(
                        at: value.location, comments: comments, layerRects: layerRects(size: frame.size), size: frame.size
                    ) {
                        store.selectComment(id: hit.id, origin: .artifact)
                        return
                    }
                    // A click outside an open card only closes it (HAIL-75).
                    if store.openCommentId != nil {
                        store.clearCommentSelection()
                        return
                    }
                    let size = Theme.Spacing.defaultRegionSize
                    let clicked = CGRect(x: value.location.x - size / 2, y: value.location.y - size / 2, width: size, height: size)
                    pointRect = CommentCaptureStageView.clamp(clicked, to: frame)
                } else {
                    pointRect = Self.rect(from: start, to: value.location).intersection(frame)
                }
                store.clearCommentSelection()
                guard frame.width > 0, frame.height > 0, pointRect.width > 2, pointRect.height > 2 else { return }
                onBeginDraft(Rect(
                    x: pointRect.minX / frame.width, y: pointRect.minY / frame.height,
                    w: pointRect.width / frame.width, h: pointRect.height / frame.height
                ), controller.pageViewport, isClick ? .point : .region)
            }
    }

    private static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

/// What sits over the live page. The zoom plays no part: pins are drawn in
/// both modes at every zoom (operator, 4 Oct), mapped through the page zoom.
enum LiveStageLayer: Equatable {
    /// Interact mode: pins only; the layer catches nothing outside a pin.
    case pins
    /// Comment mode: the region layer, with its pins.
    case commentLayer
    /// Comment mode with an older capture picked: that capture's still.
    case still

    static func make(mode: ReviewMode, showsStillOverLive: Bool) -> LiveStageLayer {
        switch mode {
        case .interact: return .pins
        case .comment: return showsStillOverLive ? .still : .commentLayer
        }
    }
}

private extension View {
    /// `onContinuousHover` only while `isEnabled`. A disabled one is not
    /// attached at all, since even an early-returning handler makes the view
    /// a hit target.
    @ViewBuilder
    func onContinuousHover(isEnabled: Bool, perform action: @escaping (HoverPhase) -> Void) -> some View {
        if isEnabled { onContinuousHover(perform: action) } else { self }
    }
}
