import SwiftUI
import AppKit

/// HAIL-127: zoom state of the live prototype's web view (trackpad pinch,
/// two-finger double-tap, the header's readout and Fit).
///
/// One model per review (`ReviewViewModel.prototypeZoom`), so zoom starts at
/// 100% for every ask and again for every new revision (`reset()`).
///
/// Comment mode zooms and pans like Interact, and both modes draw pins at
/// every zoom (operator, 4 Oct): the layer maps pins and new regions through
/// the page's zoom (`CommentPageMapping`, `PageViewport.zoom`).
@MainActor
final class PrototypeZoomModel: ObservableObject {
    static let minScale: CGFloat = 0.25
    static let maxScale: CGFloat = 4
    static let zoomStep: CGFloat = 1.25
    /// Two-finger double-tap from 100% goes to this scale.
    static let smartScale: CGFloat = 2

    /// The zoom the person chose; the web view shows it in both modes.
    @Published private(set) var storedScale: CGFloat = 1

    /// Where the next change keeps its page point (the pointer, in the web
    /// view's own coordinates). Read once by the web view. Nil means centre.
    private(set) var pendingAnchor: CGPoint?
    /// Like `pendingAnchor`, as 0...1 fractions of the view (evidence hook only).
    var pendingAnchorFraction: CGPoint?

    static func clamp(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(max(scale, minScale), maxScale)
    }

    var isActualSize: Bool { abs(storedScale - 1) < 0.001 }
    var percentText: String { "\(Int((storedScale * 100).rounded()))%" }

    func setScale(_ scale: CGFloat, anchor: CGPoint? = nil) {
        let target = Self.clamp(scale)
        guard abs(target - storedScale) > 0.0001 else { return }
        pendingAnchor = anchor
        storedScale = target
    }

    /// A trackpad pinch: `factor` is 1 + the event's magnification.
    func pinch(by factor: CGFloat, anchor: CGPoint) { setScale(storedScale * factor, anchor: anchor) }

    /// Two-finger double-tap: 100% goes to `smartScale`, anything else to 100%.
    func smartZoom(anchor: CGPoint) {
        setScale(abs(storedScale - 1) < 0.001 ? Self.smartScale : 1, anchor: anchor)
    }

    func zoomIn() { setScale(snapped(storedScale * Self.zoomStep)) }
    func zoomOut() { setScale(snapped(storedScale / Self.zoomStep)) }
    func actualSize() { setScale(1) }

    /// Reads the page's width and the view's width (set by the web view). Fit
    /// frames the whole page width; without a reader it means 100%.
    var pageWidthReader: (@MainActor () async -> (page: CGFloat, viewport: CGFloat)?)?

    /// A diagram's Fit grows a diagram that is narrower than the view to fill
    /// it (HAIL-141); a prototype's Fit only ever shrinks. Set by the review
    /// for a diagram stage.
    var fitUpscales = false

    /// Reloads the prototype from its first screen with its state cleared (HAIL-233).
    /// Set by the web view; nil while no prototype is on screen.
    var reloadAction: (@MainActor () async -> Void)?

    func reload() {
        guard let reloadAction else { return }
        Task { @MainActor in await reloadAction() }
    }

    func fit() {
        guard let reader = pageWidthReader else { return setScale(1) }
        Task { @MainActor in
            guard let widths = await reader() else { return setScale(1) }
            let scale = fitUpscales
                ? PrototypeCanvas.fitScaleUpscaling(
                    viewportWidth: widths.viewport, pageWidth: widths.page, minimum: Self.minScale, maximum: Self.maxScale
                )
                : PrototypeCanvas.fitScale(
                    viewportWidth: widths.viewport, pageWidth: widths.page, minimum: Self.minScale, maximum: Self.maxScale
                )
            setScale(scale)
        }
    }

    /// A step that lands next to 100% lands on it, so the readout never shows 99%.
    private func snapped(_ scale: CGFloat) -> CGFloat { abs(scale - 1) < 0.05 ? 1 : scale }

    /// A new ask or a new revision: back to 100%.
    func reset() {
        pendingAnchor = nil
        storedScale = 1
    }

    func takePendingAnchor() -> CGPoint? {
        defer { pendingAnchor = nil }
        return pendingAnchor
    }
}

/// Catches the trackpad's pinch and two-finger double-tap over the prototype's
/// web view. A local monitor reads them (as `PinchZoomMonitor` does for the
/// screenshot stage) and the model keeps the one zoom state; the web view then
/// applies it with `setMagnification`. Events that land outside the web view
/// pass on untouched.
struct PrototypePinchMonitor {
    final class Token {
        fileprivate var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    /// Where the one-line pinch log goes (the queue log); a test swaps it.
    @MainActor static var log: (String) -> Void = { QueueLog.write($0) }

    @MainActor
    static func install(on webView: NSView, model: PrototypeZoomModel) -> Token {
        let token = Token()
        log("prototype pinch monitor installed")
        PinchEvidence.scheduleIfRequested(view: webView) { [weak webView, weak model] input in
            guard let webView, let model else { return }
            route(input, in: webView, model: model)
        }
        token.monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify]) { [weak webView, weak model] event in
            let input = PinchInput(event: event)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let webView, let model else { return false }
                let route = route(input, in: webView, model: model)
                return route == .handled
            }
            return consumed ? nil : event
        }
        return token
    }

    /// One path for a real event, a unit test and the evidence hook. Logs each early return.
    @MainActor
    @discardableResult
    static func route(_ input: PinchInput, in webView: NSView?, model: PrototypeZoomModel) -> PinchRoute {
        let kind = input.kind == .smart ? "smart" : "pinch"
        let at = "x=\(Int(input.windowPoint.x)) y=\(Int(input.windowPoint.y))"
        guard let webView, let window = webView.window else {
            log("prototype \(kind) ignored: web view is not in a window")
            return .noViewport
        }
        guard input.window === window else {
            log("prototype \(kind) ignored: event window is not the web view window")
            return .otherWindow
        }
        let local = webView.convert(input.windowPoint, from: nil)
        guard webView.bounds.contains(local) else {
            log("prototype \(kind) ignored: pointer outside the web view \(at)")
            return .outsideStage
        }
        log("prototype \(kind) received factor=\(String(format: "%.3f", Double(input.factor))) \(at) scale=\(String(format: "%.3f", Double(model.storedScale)))")
        // `WKWebView` is flipped, so `local` is already top-left based.
        let anchor = webView.isFlipped ? local : CGPoint(x: local.x, y: webView.bounds.maxY - local.y)
        switch input.kind {
        case .smart: model.smartZoom(anchor: anchor)
        case .pinch: model.pinch(by: input.factor, anchor: anchor)
        }
        return .handled
    }
}

/// HAIL-131: Space+drag pans the zoomed page (open hand, closed hand while
/// dragging), like Pen and Figma. Holding Space over the page takes the key,
/// unless the page has a text field focused (`editableFocused`, refreshed
/// after each click), so typing a space into a form still works.
final class PrototypePanMonitor {
    private var monitors: [Any] = []
    private var spaceHeld = false
    private var dragging = false
    private var cursorPushed = false
    private var lastPoint = CGPoint.zero
    var editableFocused = false

    deinit { for monitor in monitors { NSEvent.removeMonitor(monitor) } }

    /// Where keyboard focus sits, as far as the Space decision cares.
    enum Focus: Equatable {
        case page        // the web view or a view inside it
        case textInput   // a native field, a field editor or any text view outside the page
        case other       // nothing that takes text
    }

    /// HAIL-149: Space is the pan key only when no text input wants it. A native
    /// text field with focus always gets its spaces, wherever the pointer rests.
    static func shouldTakeSpace(pointerInside: Bool, focus: Focus, pageEditableFocused: Bool) -> Bool {
        guard pointerInside else { return false }
        switch focus {
        case .textInput: return false
        case .page: return !pageEditableFocused
        case .other: return true
        }
    }

    /// Comment mode's layer is drawn by the SwiftUI host that holds the web
    /// view, so a scroll over the page lands on that host and never reached
    /// the page. A scroll whose hit view is an ancestor of the web view (the
    /// layer, a pin, a region box) goes to the page instead, so the person can
    /// pan while commenting. A scroll on the page itself, or on a native view
    /// of its own (a note's text field), is left alone.
    @MainActor
    static func shouldForwardScroll(hit: NSView?, webView: NSView) -> Bool {
        guard let hit, hit !== webView, !hit.isDescendant(of: webView) else { return false }
        return webView.isDescendant(of: hit)
    }

    @MainActor
    static func focus(of responder: NSResponder?, webView: NSView) -> Focus {
        guard let responder else { return .other }
        if let view = responder as? NSView, view === webView || view.isDescendant(of: webView) { return .page }
        if responder is NSText || responder is NSTextField || responder is NSTextInputClient { return .textInput }
        return .other
    }

    @MainActor
    static func install(
        on webView: NSView,
        pan: @escaping @MainActor (CGSize) -> Void,
        refreshEditable: @escaping @MainActor () -> Void
    ) -> PrototypePanMonitor {
        let state = PrototypePanMonitor()
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        let monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak webView, weak state] event in
            let type = event.type
            // `keyCode` and `isARepeat` raise on a mouse event, and an exception here drops the click (HAIL-133).
            let isKey = type == .keyDown || type == .keyUp
            let keyCode: UInt16 = isKey ? event.keyCode : 0
            let isRepeat = isKey ? event.isARepeat : false
            let window = event.window
            let location = event.locationInWindow
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let webView, let state, window != nil, window === webView.window else { return false }
                let local = webView.convert(location, from: nil)
                let inside = webView.bounds.contains(local)
                switch type {
                case .keyDown where keyCode == 49:
                    // Space; the pointer must be over the page and no native text input may hold focus.
                    let mouse = webView.convert(webView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
                    let focus = PrototypePanMonitor.focus(of: webView.window?.firstResponder, webView: webView)
                    guard PrototypePanMonitor.shouldTakeSpace(
                        pointerInside: webView.bounds.contains(mouse),
                        focus: focus, pageEditableFocused: state.editableFocused
                    ) else { return false }
                    if !isRepeat { state.spaceHeld = true; state.showCursor(.openHand) }
                    return true
                case .keyUp where keyCode == 49:
                    guard state.spaceHeld else { return false }
                    state.spaceHeld = false
                    state.dragging = false
                    state.restoreCursor()
                    return true
                case .leftMouseDown:
                    if state.spaceHeld, inside {
                        state.dragging = true
                        state.lastPoint = local
                        state.showCursor(.closedHand)
                        return true
                    }
                    if inside { refreshEditable() }
                    return false
                case .leftMouseDragged:
                    guard state.dragging else { return false }
                    pan(CGSize(width: local.x - state.lastPoint.x, height: local.y - state.lastPoint.y))
                    state.lastPoint = local
                    return true
                case .leftMouseUp:
                    guard state.dragging else { return false }
                    state.dragging = false
                    state.showCursor(.openHand)
                    return true
                case .scrollWheel:
                    guard inside, PrototypePanMonitor.shouldForwardScroll(
                        hit: webView.window?.contentView?.hitTest(location), webView: webView
                    ) else { return false }
                    webView.scrollWheel(with: event)
                    return true
                default:
                    return false
                }
            }
            return consumed ? nil : event
        }
        if let monitor { state.monitors.append(monitor) }
        return state
    }

    @MainActor
    private func showCursor(_ cursor: NSCursor) {
        if cursorPushed { NSCursor.pop() }
        cursor.push()
        cursorPushed = true
    }

    @MainActor
    private func restoreCursor() {
        if cursorPushed { NSCursor.pop() }
        cursorPushed = false
    }
}
