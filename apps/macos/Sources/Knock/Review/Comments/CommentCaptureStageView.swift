import SwiftUI
import AppKit

/// The frozen capture's stage in Comment mode (docs/design/mvp-values.md
/// §M5 `ukdYT`): the capture image, a dim overlay, every saved pin's region
/// and number, and — while one is being drafted — the drafting region (with
/// drag handles) and its note popover.
///
/// The capture is a full page (HAIL-35 contract), almost always taller than
/// the stage, so it renders fit-to-width inside a vertical `ScrollView`
/// rather than letterboxed to fit both dimensions - the same "wide as the
/// column, scroll for the rest" shape `ScreenshotStageView`'s zoom starts
/// from. Renders as a plain, non-interactive image: Comment mode does not
/// click through the artifact (that is Interact mode's job), it drags or
/// clicks to place a pin, so this view owns its own gesture, not the
/// original `html_bundle` webview or the screenshot's zoom controller.
struct CommentCaptureStageView: View {
    let image: NSImage
    @ObservedObject var store: CommentsSessionStore
    /// Identifies which capture is on screen, so switching captures (a tap
    /// on a different group header) re-triggers the initial-scroll jump even
    /// though this view's own identity does not change.
    let captureId: String
    /// 0...1: where to scroll to as soon as this capture appears (Contract:
    /// "first scrolled to where the operator was in Interact mode").
    let initialScrollFraction: Double
    /// HAIL-73: `nil` keeps the fit-to-width page (a prototype's capture).
    /// A value shows a screenshot: the whole image at Fit, or at that zoom,
    /// centred, in a two-axis `ScrollView`.
    var zoom: StageZoom?
    /// Reports the stage size and the image size, so the zoom keys can step
    /// from the scale on screen.
    var onViewport: (CGSize, CGSize) -> Void = { _, _ in }
    /// HAIL-93: the zoom state a trackpad pinch and smart zoom drive. Nil (a
    /// prototype's capture) leaves them off.
    var stageModel: ScreenshotStageModel?
    /// WAG-280: finds the live page element behind a pin dropped on this still (the rect is 0...1 of
    /// the image, the string is the capture). `nil` for a screenshot, which has no page behind it.
    var elementReader: ((Rect, String) -> Task<PageElementContext?, Never>?)?
    /// WAG-413: set when this stage is one side of Compare. It keeps the draft to its own capture, mirrors
    /// the pan to the other side and draws the "what changed" boxes. Nil everywhere else.
    var compareSide: CompareSideOptions?

    @State private var scrollHandle = ScrollViewHandle()
    @State private var isPanning = false
    @State private var panLast: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var draggingRect: CGRect?
    /// Cursor position over the stage (HAIL-58 "Drag to flag" tag).
    @State private var hoverPoint: CGPoint?
    @State private var crosshairPushed = false
    @State private var hasPlacedComment = CommentCursorTag.hasPlacedComment()

    private static let initialScrollAnchorId = "comment-stage-initial-scroll"
    private static let revealAnchorId = "comment-stage-reveal"

    /// How far down the selected comment's pin sits, less a quarter of the
    /// visible height so it lands in view rather than on the edge.
    /// Horizontally only when the stage scrolls that way (a zoomed screenshot).
    static func revealOffset(comment: Comment?, frame: CGRect, viewport: CGSize, horizontal: Bool) -> CGSize {
        guard let comment else { return .zero }
        let pin = pointRect(for: comment.rect, in: frame)
        return CGSize(
            width: horizontal ? max(0, pin.minX - viewport.width / 4) : 0,
            height: max(0, pin.minY - viewport.height / 4)
        )
    }

    /// The pins of the capture on this stage (not of whichever capture is current: Compare shows two).
    private var comments: [Comment] { store.model.comments(on: captureId) }

    /// The draft on this stage. A Compare side shows only a draft made on its own capture.
    private var draft: DraftPin? {
        guard let draft = store.draftPin else { return nil }
        return compareSide == nil || draft.captureId == captureId ? draft : nil
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = zoom.map { ScreenshotViewport.frame(container: proxy.size, image: image.size, zoom: $0) }
                ?? Self.fitWidthFrame(containerWidth: proxy.size.width, image: image.size)
            let contentSize = zoom == nil
                ? CGSize(width: frame.width, height: frame.height)
                : CGSize(width: max(proxy.size.width, frame.width), height: max(proxy.size.height, frame.height))
            let overlaySize = CGSize(width: contentSize.width, height: contentSize.height)
            let reveal = Self.revealOffset(
                comment: store.selectedCommentId.flatMap { id in comments.first { $0.id == id } },
                frame: frame, viewport: proxy.size, horizontal: zoom != nil
            )
            ScrollViewReader { scrollProxy in
                ScrollView(zoom == nil ? [.vertical] : [.horizontal, .vertical], showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        imageLayer(frame)
                        dimOverlay(frame)
                        if let boxes = compareSide?.boxes {
                            ForEach(boxes.indices, id: \.self) { index in
                                ChangeBoxView()
                                    .frame(width: Self.pointRect(for: boxes[index], in: frame).width, height: Self.pointRect(for: boxes[index], in: frame).height)
                                    .position(x: Self.pointRect(for: boxes[index], in: frame).midX, y: Self.pointRect(for: boxes[index], in: frame).midY)
                                    .allowsHitTesting(false)
                            }
                        }
                        ForEach(comments) { comment in
                            commentOverlay(comment, frame: frame)
                        }
                        if let draggingRect {
                            RegionBoxView(style: .drafting, showsHandles: true)
                                .frame(width: draggingRect.width, height: draggingRect.height)
                                .position(x: draggingRect.midX, y: draggingRect.midY)
                        }
                        if let draft {
                            draftOverlay(draft, frame: frame, containerSize: overlaySize)
                        } else {
                            cardOverlay(frame: frame, containerSize: overlaySize)
                        }
                        // The scroll-to anchor, laid out through real VStack
                        // flow (a spacer sized to the target offset, then a
                        // zero-size marker) rather than `.position()`.
                        //
                        // Found live (fold, HAIL-35 attempt 2): a
                        // `.position()`-placed anchor reported the right
                        // geometry to `.onAppear` (logged and correct) but
                        // `ScrollViewReader.scrollTo` still left the stage at
                        // the top every time, regardless of retry delay -
                        // `.position()` is a post-layout offset transform,
                        // not real box layout, and `scrollTo`'s own geometry
                        // probe does not follow it. A view actually laid out
                        // top-to-bottom does not have this problem.
                        if zoom == nil {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: max(0, frame.height * initialScrollFraction))
                                Color.clear.frame(width: 1, height: 1).id(Self.initialScrollAnchorId)
                                Spacer(minLength: 0)
                            }
                            .allowsHitTesting(false)
                        }
                        // Same shape, for a click on a list card (HAIL-75): a
                        // spacer down and across to a little above and left
                        // of the pin, so it works on the two-axis stage too.
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: reveal.height)
                            HStack(spacing: 0) {
                                Color.clear.frame(width: reveal.width)
                                Color.clear.frame(width: 1, height: 1).id(Self.revealAnchorId)
                            }
                            Spacer(minLength: 0)
                        }
                        .allowsHitTesting(false)
                    }
                    .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .background(ScrollViewFinder(handle: scrollHandle))
                    .background { if let compareSide { PanMirror(sync: compareSide.sync, side: compareSide.side, handle: scrollHandle) } }
                    .gesture(dragGesture(frame: frame))
                }
                .onAppear {
                    if zoom == nil { Self.scrollToInitialAnchor(scrollProxy) }
                    onViewport(proxy.size, image.size)
                }
                .onChange(of: captureId) { _, _ in
                    if zoom == nil { Self.scrollToInitialAnchor(scrollProxy) }
                    onViewport(proxy.size, image.size)
                }
                .onChange(of: proxy.size) { _, size in onViewport(size, image.size) }
                .onChange(of: zoom) { _, new in
                    guard new != nil else { return }
                    // The Before side of Compare leaves the pinch anchor to the After side.
                    let anchor = compareSide?.takesAnchor == false ? nil : stageModel?.takePendingAnchor()
                    DispatchQueue.main.async {
                        if let anchor {
                            let target = new!
                            let frame = ScreenshotViewport.frame(container: proxy.size, image: image.size, zoom: target)
                            scrollHandle.scroll(
                                to: ScreenshotViewport.scrollOrigin(for: anchor, container: proxy.size, image: image.size, zoom: target),
                                whenContentIs: CGSize(width: max(proxy.size.width, frame.width), height: max(proxy.size.height, frame.height))
                            )
                        } else {
                            scrollHandle.centerContent()
                        }
                        // Evidence hook (HAIL-73): show the low pin at 2x.
                        if ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_STAGE"] == "fit2x" { scrollHandle.scrollToBottom() }
                    }
                }
                .onChange(of: store.revealRequest) { _, request in
                    guard let request, request.origin == .list else { return }
                    DispatchQueue.main.async { scrollProxy.scrollTo(Self.revealAnchorId, anchor: .topLeading) }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background {
                if let stageModel, let zoom {
                    PinchZoomMonitor(
                        handle: scrollHandle,
                        onPinch: { factor, point, ended in
                            stageModel.pinch(by: factor, anchor: pinchAnchor(point, zoom: zoom, proxy.size))
                            if ended { stageModel.userPinchEnded() }
                        },
                        onSmartZoom: { point in
                            stageModel.userSmartZoom(anchor: pinchAnchor(point, zoom: zoom, proxy.size))
                        }
                    )
                }
            }
            .overlay(alignment: .topLeading) { cursorTag }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    if !crosshairPushed { NSCursor.crosshair.push(); crosshairPushed = true }
                case .ended:
                    hoverPoint = nil
                    popCrosshair()
                }
            }
            .onDisappear { popCrosshair() }
        }
        .imageContextMenu(image)
    }

    private func pinchAnchor(_ point: CGPoint, zoom: StageZoom, _ container: CGSize) -> ScreenshotViewport.Anchor {
        ScreenshotViewport.anchor(pointer: point, scrollOrigin: scrollHandle.scrollOrigin, container: container, image: image.size, zoom: zoom)
    }

    private func popCrosshair() {
        if crosshairPushed { NSCursor.pop(); crosshairPushed = false }
    }

    /// The "Drag to flag" tag, offset below-right of the cursor. Hidden while
    /// dragging a selection or writing a note.
    @ViewBuilder
    private var cursorTag: some View {
        let point = CanvasToolHintEvidence.pinsCursorTag() ? CanvasToolHintEvidence.cursorPoint : hoverPoint
        if let point, draggingRect == nil, store.draftPin == nil,
           CommentCursorTag.isVisible(mode: .comment, hasPlacedComment: hasPlacedComment) {
            CommentCursorTagView()
                .offset(x: point.x + 14, y: point.y + 16)
        }
    }

    // MARK: - Layers

    private func imageLayer(_ frame: CGRect) -> some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
    }

    private func dimOverlay(_ frame: CGRect) -> some View {
        Rectangle()
            .fill(Theme.Colors.ink.opacity(Theme.Alpha.dimOverlay))
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
    }

    private func commentOverlay(_ comment: Comment, frame: CGRect) -> some View {
        let rect = Self.pointRect(for: comment.rect, in: frame)
        let isSelected = store.selectedCommentId == comment.id
        return Group {
            if store.showsRegion(of: comment.id) {
                RegionBoxView(style: .committed, isSelected: isSelected)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
            PinView(number: comment.n, isSelected: isSelected)
                .contentShape(Circle())
                .onHover { store.pinHoverChanged(comment.id, inside: $0) }
                .onTapGesture { if store.draftPin == nil { store.selectComment(id: comment.id, origin: .artifact) } }.pointerCursor()
                .position(x: rect.minX, y: rect.minY)
        }
    }

    /// The open comment's inline card, or the hovered comment's preview,
    /// anchored beside its pin (HAIL-75).
    @ViewBuilder
    private func cardOverlay(frame: CGRect, containerSize: CGSize) -> some View {
        if let id = store.openCommentId, let comment = comments.first(where: { $0.id == id }) {
            InlineCommentCardView(
                number: comment.n, text: comment.text,
                onSave: { store.saveComment(id: id, text: $0) },
                onDelete: { store.deleteComment(id: id) },
                onClose: { store.closeComment() }
            )
            .id(id)
            .position(Self.popoverPosition(for: Self.pinFrame(comment, in: frame), in: containerSize, height: Self.editCardHeight))
        } else if let id = store.previewCommentId, let comment = comments.first(where: { $0.id == id }) {
            CommentHoverPreviewView(text: comment.text)
                .frame(width: Theme.Spacing.notePopoverWidth)
                .position(Self.popoverPosition(for: Self.pinFrame(comment, in: frame), in: containerSize, height: Self.previewHeight))
        }
    }

    private static func pinFrame(_ comment: Comment, in frame: CGRect) -> CGRect {
        let origin = pointRect(for: comment.rect, in: frame).origin
        let d = Theme.Spacing.pinLarge
        return CGRect(x: origin.x - d / 2, y: origin.y - d / 2, width: d, height: d)
    }

    private func draftOverlay(_ draft: DraftPin, frame: CGRect, containerSize: CGSize) -> some View {
        let rect = Self.pointRect(for: draft.rect, in: frame)
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
                    if store.commitDraft() != nil {
                        CommentCursorTag.markPlaced()
                        hasPlacedComment = true
                    }
                },
                onCancel: { store.cancelDraft() }
            )
            .position(Self.popoverPosition(for: rect, in: containerSize, height: NoteFieldLogic.popoverHeight(text: store.draftPin?.text ?? "")))
        }
    }

    // MARK: - Gesture

    private func dragGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                // HAIL-73: Option-drag pans a zoomed screenshot. A plain drag
                // still places a pin, exactly as before.
                if zoom != nil, isPanning || (dragStart == nil && NSEvent.modifierFlags.contains(.option)) {
                    let mouse = NSEvent.mouseLocation
                    if let last = panLast { scrollHandle.pan(by: CGSize(width: last.x - mouse.x, height: mouse.y - last.y)) }
                    panLast = mouse
                    isPanning = true
                    return
                }
                guard store.draftPin == nil else { return }
                if dragStart == nil { dragStart = value.startLocation }
                guard let start = dragStart else { return }
                let raw = CGRect(
                    x: min(start.x, value.location.x), y: min(start.y, value.location.y),
                    width: abs(value.location.x - start.x), height: abs(value.location.y - start.y)
                )
                draggingRect = raw.intersection(frame)
            }
            .onEnded { value in
                defer { dragStart = nil; draggingRect = nil }
                if isPanning { isPanning = false; panLast = nil; return }
                guard store.draftPin == nil, let start = dragStart else { return }
                let distance = hypot(value.location.x - start.x, value.location.y - start.y)
                let pointRect: CGRect
                if distance < 4 {
                    let rects = Dictionary(uniqueKeysWithValues: comments.map { ($0.id, Self.pointRect(for: $0.rect, in: frame)) })
                    if let hit = CommentPageMapping.pinHit(at: value.location, comments: comments, layerRects: rects, size: frame.size) {
                        store.selectComment(id: hit.id, origin: .artifact)
                        return
                    }
                    // A click outside an open card only closes it (HAIL-75).
                    if store.openCommentId != nil {
                        store.clearCommentSelection()
                        return
                    }
                    let half = Theme.Spacing.defaultRegionSize / 2
                    let clicked = CGRect(
                        x: value.location.x - half, y: value.location.y - half,
                        width: Theme.Spacing.defaultRegionSize, height: Theme.Spacing.defaultRegionSize
                    )
                    pointRect = Self.clamp(clicked, to: frame)
                } else {
                    let raw = CGRect(
                        x: min(start.x, value.location.x), y: min(start.y, value.location.y),
                        width: abs(value.location.x - start.x), height: abs(value.location.y - start.y)
                    )
                    pointRect = raw.intersection(frame)
                }
                store.clearCommentSelection()
                guard frame.width > 0, frame.height > 0, pointRect.width > 2, pointRect.height > 2 else { return }
                let normalized = Rect(
                    x: (pointRect.minX - frame.minX) / frame.width,
                    y: (pointRect.minY - frame.minY) / frame.height,
                    w: pointRect.width / frame.width,
                    h: pointRect.height / frame.height
                )
                store.beginDraft(rect: normalized, on: captureId, variant: distance < 4 ? .point : .region, element: elementReader?(normalized, captureId))
            }
    }

    /// Scrolls to the "where the operator was in Interact mode" anchor.
    ///
    /// Found live (fold, HAIL-35 attempt 2): the anchor used to be a
    /// `.position()`-placed `Color.clear` inside the pins' `ZStack`.
    /// `.onAppear` reported its geometry correctly (logged and verified live:
    /// the right `frame.height` and offset), yet `scrollTo` still left the
    /// stage at the top every time - `.position()` is a post-layout offset
    /// transform, not real box layout, and `ScrollViewReader`'s own geometry
    /// probe does not follow it. The anchor is now laid out through a real
    /// `VStack` (a spacer sized to the target offset, then a zero-size
    /// marker), which fixed it: a capture with a pin placed low on a
    /// 3-screen page now opens scrolled to the bottom, pin visible, every
    /// time. Deferred one main-queue turn since this still runs from
    /// `.onAppear`, before the surrounding `GeometryReader` has necessarily
    /// finished its first layout pass.
    private static func scrollToInitialAnchor(_ scrollProxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            scrollProxy.scrollTo(Self.initialScrollAnchorId, anchor: .top)
        }
    }

    // MARK: - Geometry helpers (unit-tested: `CommentsModelTests`)

    /// The capture image's displayed frame: fit to the container's width,
    /// origin at the top - unlike a letterboxed fit, its height can (and for
    /// most full-page captures, does) run past the container's own height,
    /// which is exactly what makes the enclosing `ScrollView` scroll.
    static func fitWidthFrame(containerWidth: CGFloat, image: NSSize) -> CGRect {
        guard image.width > 0, containerWidth > 0 else {
            return CGRect(x: 0, y: 0, width: containerWidth, height: image.height)
        }
        let scale = containerWidth / image.width
        return CGRect(x: 0, y: 0, width: containerWidth, height: image.height * scale)
    }

    /// A normalized `Rect` (0..1 of the capture) resolved to point-space
    /// inside `frame` — the capture's displayed frame from `fitWidthFrame`.
    static func pointRect(for rect: Rect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + rect.x * frame.width,
            y: frame.minY + rect.y * frame.height,
            width: rect.w * frame.width,
            height: rect.h * frame.height
        )
    }

    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = max(bounds.minX, min(result.origin.x, bounds.maxX - result.width))
        result.origin.y = max(bounds.minY, min(result.origin.y, bounds.maxY - result.height))
        return result
    }

    /// Places the note popover beside the drafted region: to its right when
    /// there is room, otherwise its left, clamped to stay inside the stage.
    static let editCardHeight: CGFloat = 132
    static let previewHeight: CGFloat = 52

    static func popoverPosition(for rect: CGRect, in container: CGSize, height estimatedHeight: CGFloat = 110) -> CGPoint {
        let width = Theme.Spacing.notePopoverWidth
        var x = rect.maxX + 14 + width / 2
        if x + width / 2 > container.width {
            x = rect.minX - 14 - width / 2
        }
        x = max(width / 2, min(x, container.width - width / 2))
        let y = max(estimatedHeight / 2, min(rect.minY + estimatedHeight / 2, container.height - estimatedHeight / 2))
        return CGPoint(x: x, y: y)
    }
}
