import AppKit
import Combine
import SwiftUI

/// WAG-359: where a source pill sits in a line of text, and how much room a click on it has. Plain geometry, so a
/// test can check it. No view code here.
enum PillAlignment {
    /// The distance from the baseline up to the middle of the x-height of `font`.
    static func centreAboveBaseline(font: NSFont) -> CGFloat { centreAboveBaseline(xHeight: font.xHeight) }

    static func centreAboveBaseline(xHeight: CGFloat) -> CGFloat { xHeight / 2 }

    /// The top of a pill whose centre is at the middle of the x-height. `baseline` and the result count down from
    /// the same top edge (a flipped view or a layout).
    static func top(baseline: CGFloat, pillHeight: CGFloat, xHeight: CGFloat) -> CGFloat {
        baseline - centreAboveBaseline(xHeight: xHeight) - pillHeight / 2
    }

    /// The x-height of the text face of a style (the bundled sans, else the system face).
    static func xHeight(size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        PromptBarLogic.sansFont(size: size, weight: weight).xHeight
    }

    /// The box that an attachment reserves in the text: inside the line box of the font, cut to whole points
    /// (the text system rounds a line the same way), so a pill never makes its line taller. The pill view is drawn
    /// over it, centred by `top(baseline:pillHeight:xHeight:)`.
    static func attachmentBounds(font: NSFont, width: CGFloat) -> CGRect {
        let ascent = font.ascender.rounded(.down)
        let descent = (-font.descender).rounded(.down)
        return CGRect(x: 0, y: -descent, width: width, height: ascent + descent)
    }
}

enum PillHitArea {
    /// The click room around the visible shape, on each side.
    static let reach: CGFloat = 4
    /// The least height of the click area.
    static let minHeight: CGFloat = 24

    struct Pads: Equatable {
        var leading: CGFloat
        var trailing: CGFloat
        static let full = Pads(leading: reach, trailing: reach)
        static let none = Pads(leading: 0, trailing: 0)
    }

    /// The room on each side. Next to another pill the two share the gap between them, so their areas never
    /// overlap. `nil` means no pill on that side.
    static func pads(gapToPreviousPill: CGFloat?, gapToNextPill: CGFloat?) -> Pads {
        Pads(
            leading: gapToPreviousPill.map { min(reach, max(0, $0) / 2) } ?? reach,
            trailing: gapToNextPill.map { min(reach, max(0, $0) / 2) } ?? reach)
    }

    /// The height of the click area for a pill `visible` high.
    static func height(visible: CGFloat) -> CGFloat { max(visible, minHeight) }

    /// The click area of a visible pill rect.
    static func rect(visible: CGRect, pads: Pads) -> CGRect {
        let h = height(visible: visible.height)
        return CGRect(
            x: visible.minX - pads.leading, y: visible.midY - h / 2,
            width: visible.width + pads.leading + pads.trailing, height: h)
    }
}

/// A pill inside a text view: a picture of `SourcePillView`, drawn again only when its card is pinned or let go. It
/// takes the mouse itself: a click, a double click or a drag that starts on a pill never reaches the text under it.
///
/// Not an `NSHostingView` (waggle-releases#9): a hosting view follows its place in the window, so on every frame of a scroll it
/// asked for a constraint update, and the text's own SwiftUI host then laid out the whole page again.
final class PillImageView: NSView {
    private let hub: SourcesHub
    private let model: SourcePillModel
    private let ids: [String]
    private let key: String
    /// The shape inside this view; the rest of the view is click room around it.
    var shape: CGRect = .zero { didSet { if oldValue != shape { needsDisplay = true } } }
    private var images: [Bool: NSImage] = [:]
    private var selected: Bool
    private var watch: AnyCancellable?
    private var pressed = false

    init(hub: SourcesHub, model: SourcePillModel, ids: [String], key: String) {
        self.hub = hub
        self.model = model
        self.ids = ids
        self.key = key
        selected = hub.isPinned(key: key)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Source: \(model.label)" + (model.extra > 0 ? ", and \(model.extra) more" : ""))
        // `objectWillChange` fires before the change: read the pin after it.
        watch = hub.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.pinChanged() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func pinChanged() {
        let now = hub.isPinned(key: key)
        guard now != selected else { return }
        selected = now
        needsDisplay = true
    }

    private func image() -> NSImage? {
        if let cached = images[selected] { return cached }
        let renderer = ImageRenderer(content: SourcePillView(
            hub: hub, model: model, ids: ids, key: key, reportsRect: false, pads: .none, hasHitArea: false))
        renderer.scale = window?.backingScaleFactor ?? 2
        let made = renderer.nsImage
        images[selected] = made
        return made
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        images = [:]
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        image()?.draw(in: shape, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Evidence only: pin the card of the pill that cites this source.
        guard window != nil, let open = hub.evidenceOpen, open == "pin:" + (ids.first ?? "") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.hub.pinned == nil else { return }
            self.hub.tap(key: self.key, ids: self.ids)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func accessibilityPerformPress() -> Bool {
        hub.tap(key: key, ids: ids)
        return true
    }

    override func mouseEntered(with event: NSEvent) { hub.pointerMoved(onPill: key, ids: ids, inside: true) }
    override func mouseExited(with event: NSEvent) { hub.pointerMoved(onPill: key, ids: ids, inside: false) }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        hub.tap(key: key, ids: ids)
    }
}
