import AppKit
import SwiftUI

/// WAG-357: one piece of request text (the title, the need, a pro, a source note) as a selectable, commentable text.
///
/// It is the text-system twin of `MarkdownCommentTextView`: a selection shows the Comment button (drawn by
/// `AskCommentsHost`), a saved range keeps a soft accent tint and a numbered pin, a click on it opens its note.
/// Source markers are pill attachments with a real pill view over each one, so the pills sit in the running text
/// and wrap with it (WAG-356 behaviour: hover card, pin on click, grouped pill).
final class AskCommentTextView: NSTextView, NSTextViewDelegate {
    static let inset = NSSize(width: 10, height: 8)
    private static let tint = NSColor(Theme.Colors.accent)
    static let pillGap: CGFloat = 4
    /// The narrowest wrap width a measure typesets at (WAG-373). SwiftUI asks every text for its minimum size with a
    /// proposed width of 0, which is 1 pt of wrap width here: one character per line, a height of thousands of points
    /// and a large typeset. No real column is this narrow, so a narrower ask gets the height at this width.
    static let minWrapWidth: CGFloat = 80

    weak var hub: AskCommentsHub?
    var sourcesHub: SourcesHub?
    /// Where this view sits in the sources host, so a pill can report its place there.
    /// Moves on every frame of a scroll. The pills' places in the text stay the same, so only their
    /// reported rects move: no layout pass (a layout here re-laid the whole window per frame, waggle-releases#9).
    var sourcesOrigin: CGPoint = .zero { didSet { if oldValue != sourcesOrigin { reportPills() } } }
    /// Each pill's key, shape and hit area in this view, from the last layout.
    private var placedPills: [(key: String, shape: NSRect, hit: NSRect)] = []
    private(set) var target = AskCommentTarget(.title)
    private(set) var content: AskTextContent?
    private var comments: [Comment] = []
    private var ranges: [String: Range<Int>] = [:]
    private var selectedId: String?
    private var hoveredId: String?
    private var canComment = true
    private var pillViews: [PillImageView] = []
    /// Per pill: the padding of its host around the shape, and the shape's own size.
    private var pillPads: [PillHitArea.Pads] = []
    private var pillSizes: [CGSize] = []
    private let pinLayer = AskPinLayer()
    private var evidenceRan = false
    private var pillKeys: [String] = []
    /// How many layout passes and measures this view had, for the tests that pin "the layout settles" (WAG-363).
    private(set) var layoutPasses = 0
    private(set) var measures = 0
    /// A second text system over a copy of the text, only for `fittingHeight`. The view's own container follows the
    /// view's frame (AppKit puts it back to that width), so a measure at a proposed width could not use it.
    let measurer = TextMeasurer()

    static func make() -> AskCommentTextView {
        let storage = NSTextStorage()
        // Draws the code and path chips behind their text (task 11c).
        let layout = ChipLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = AskCommentTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40), textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = inset
        view.delegate = view
        view.selectedTextAttributes = ([.backgroundColor: tint.withAlphaComponent(0.25)] as [NSAttributedString.Key: Any])
        view.addSubview(view.pinLayer)
        return view
    }

    // MARK: Content

    func configure(
        content: AskTextContent, target: AskCommentTarget, comments: [Comment], selectedId: String?, canComment: Bool,
        hub: AskCommentsHub?, sourcesHub: SourcesHub?
    ) {
        self.hub = hub
        hub?.register(self)
        self.sourcesHub = sourcesHub
        self.canComment = canComment
        let contentChanged = self.content != content || self.target != target
        EvidenceLayoutLog.bump(contentChanged ? "configure.changed" : "configure.same")
        if contentChanged {
            self.content = content
            self.target = target
            setAttributedText(content)
            evidenceRan = false
        }
        let commentsChanged = self.comments != comments || self.selectedId != selectedId || contentChanged
        self.comments = comments
        self.selectedId = selectedId
        if commentsChanged {
            ranges = [:]
            for comment in comments {
                guard let anchor = comment.askAnchor,
                      let range = content.renderedRange(forPlain: (anchor.start - target.baseOffset)..<(anchor.end - target.baseOffset))
                else { continue }
                ranges[comment.id] = range
            }
            applyHighlights()
        }
        if !canComment { selectionChangedInternal() }
        runEvidenceHooksOnce()
    }

    private func setAttributedText(_ content: AskTextContent) {
        for view in pillViews { view.removeFromSuperview() }
        pillViews = []
        pillKeys = []
        pillPads = []
        pillSizes = []
        placedPills = []
        let attributed = NSMutableAttributedString(attributedString: content.attributed)
        // A pill view over each attachment; the attachment keeps the room for it.
        for (number, pill) in content.pills.enumerated() {
            guard let hub = sourcesHub, let model = hub.book.pill(ids: pill.ids) else { continue }
            let key = "\(self.target.key)#\(number)"
            // Pills that touch share the gap between them, so two click areas never overlap (WAG-359).
            let previous = number > 0 && content.pills[number - 1].index == pill.index - 1
            let next = number + 1 < content.pills.count && content.pills[number + 1].index == pill.index + 1
            let pads = PillHitArea.pads(
                gapToPreviousPill: previous ? Self.pillGap : nil, gapToNextPill: next ? Self.pillGap : nil)
            let visible = NSHostingView(rootView: SourcePillView(hub: hub, model: model, ids: pill.ids, key: key, reportsRect: false, pads: .none, hasHitArea: false)).fittingSize
            let host = PillImageView(hub: hub, model: model, ids: pill.ids, key: key)
            if let attachment = attributed.attribute(.attachment, at: pill.index, effectiveRange: nil) as? AskPillAttachment {
                let font = (attributed.attribute(.font, at: pill.index, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 13)
                attachment.image = NSImage(size: NSSize(width: visible.width + Self.pillGap, height: font.ascender - font.descender))
                attachment.bounds = PillAlignment.attachmentBounds(font: font, width: visible.width + Self.pillGap)
            }
            addSubview(host)
            pillViews.append(host)
            pillKeys.append(key)
            pillPads.append(pads)
            pillSizes.append(visible)
        }
        textStorage?.setAttributedString(attributed)
        measurer.set(attributed)
        if pinLayer.superview !== self || subviews.last !== pinLayer { addSubview(pinLayer) }
        needsLayout = true
    }

    /// The height of the text at this width, for SwiftUI's sizing. A pure measure (WAG-363): it reads a private copy
    /// of the text, so it changes no frame, no container and no layout of this view.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        measures += 1
        return measurer.height(forWrapWidth: max(Self.minWrapWidth, width - 2 * Self.inset.width)) + 2 * Self.inset.height
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let container = textContainer {
            let wrap = max(1, newSize.width - 2 * Self.inset.width)
            if abs(container.size.width - wrap) > 0.5 { container.size = NSSize(width: wrap, height: CGFloat.greatestFiniteMagnitude) }
        }
    }

    // MARK: Highlights and pins

    private func applyHighlights() {
        guard let layout = layoutManager, let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        guard storage.length > 0 else { layoutPins(); return }
        var depth = [Int](repeating: 0, count: storage.length)
        for range in ranges.values { for i in range where i < depth.count { depth[i] += 1 } }
        let draftRange: Range<Int>? = {
            guard let draft = hub?.ui.draft, draft.key == target.key, let content else { return nil }
            return content.renderedRange(forPlain: (draft.anchor.start - target.baseOffset)..<(draft.anchor.end - target.baseOffset))
        }()
        func level(_ i: Int) -> Int {
            if let range = draftRange, range.contains(i) { return 4 }
            if let id = selectedId ?? hoveredId, let range = ranges[id], range.contains(i) { return 3 }
            return min(depth[i], 2)
        }
        let alphas: [CGFloat] = [0, 0.16, 0.30, 0.40, 0.40]
        var i = 0
        while i < depth.count {
            let l = level(i)
            var j = i + 1
            while j < depth.count, level(j) == l { j += 1 }
            if l > 0 {
                layout.addTemporaryAttribute(
                    .backgroundColor, value: Self.tint.withAlphaComponent(alphas[l]), forCharacterRange: NSRange(location: i, length: j - i))
            }
            i = j
        }
        layoutPins()
    }

    /// Re-applies the tint (a draft opened or closed).
    func refreshHighlights() { applyHighlights() }

    private func glyphBox(forCharacter index: Int) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, index < storage.length else { return nil }
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: index)
        let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return box.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private func layoutPins() {
        pinLayer.frame = bounds
        var items: [AskPinLayer.Item] = []
        let size = Theme.Spacing.pinSmall
        var usedAtLine: [CGFloat: Int] = [:]
        for comment in comments {
            guard let range = ranges[comment.id], let last = glyphBox(forCharacter: range.upperBound - 1) else { continue }
            let line = last.minY.rounded()
            let k = usedAtLine[line, default: 0]
            usedAtLine[line] = k + 1
            let x = min(last.maxX - 4 + CGFloat(k) * (size + 2), bounds.width - size)
            items.append(AskPinLayer.Item(id: comment.id, number: comment.n, rect: NSRect(x: x, y: last.minY - 12, width: size, height: size), selected: comment.id == selectedId))
        }
        pinLayer.items = items
        pinLayer.needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutPasses += 1
        EvidenceLayoutLog.bump("viewlayout")
        layoutPills()
        layoutPins()
    }

    private func layoutPills() {
        guard let content, let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
        layout.ensureLayout(for: container)
        placedPills = []
        var hostIndex = 0
        for pill in content.pills {
            guard hostIndex < pillViews.count else { break }
            defer { hostIndex += 1 }
            guard pill.index < storage.length else { continue }
            let glyph = layout.glyphIndexForCharacter(at: pill.index)
            let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            // The baseline of the pill's line, then the middle of the x-height of the text beside it. The location of
            // an attachment glyph is the bottom of its cell, so the cell's own offset below the baseline comes off.
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let cell = (storage.attribute(.attachment, at: pill.index, effectiveRange: nil) as? NSTextAttachment)?.bounds.minY ?? 0
            let baseline = line.minY + layout.location(forGlyphAt: glyph).y + cell + textContainerOrigin.y
            let font = (storage.attribute(.font, at: pill.index, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 13)
            let visible = pillSizes[hostIndex]
            let pads = pillPads[hostIndex]
            let top = PillAlignment.top(baseline: baseline, pillHeight: visible.height, xHeight: font.xHeight)
            let shape = NSRect(x: box.minX + textContainerOrigin.x + Self.pillGap, y: top, width: visible.width, height: visible.height)
            let hit = PillHitArea.rect(visible: shape, pads: pads)
            let host = pillViews[hostIndex]
            if host.frame != hit { host.frame = hit }
            host.shape = shape.offsetBy(dx: -hit.minX, dy: -hit.minY)
            placedPills.append((pillKeys[hostIndex], shape, hit))
        }
        reportPills()
    }

    private func reportPills() {
        let origin = sourcesOrigin
        for pill in placedPills {
            sourcesHub?.report(
                key: pill.key, rect: pill.shape.offsetBy(dx: origin.x, dy: origin.y), hit: pill.hit.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    func forgetPills() {
        for key in pillKeys { sourcesHub?.forget(key: key) }
    }

    // MARK: Mouse and keys

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// Clicks in the padding around the text go to the views under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let inside = bounds.insetBy(dx: Self.inset.width - 2, dy: Self.inset.height - 2)
        if inside.contains(local) || pillViews.contains(where: { $0.frame.contains(local) }) || pinLayer.items.contains(where: { $0.rect.contains(local) }) { return super.hitTest(point) }
        return nil
    }

    private func commentId(at point: NSPoint) -> String? {
        if let pin = pinLayer.items.last(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) { return pin.id }
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
        let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard box.insetBy(dx: -1, dy: 0).contains(local) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        return comments.last(where: { ranges[$0.id]?.contains(index) == true })?.id
    }

    private func rect(ofComment id: String) -> NSRect {
        guard let range = ranges[id], let box = glyphBox(forCharacter: range.upperBound - 1) else { return .zero }
        return NSRect(x: box.maxX, y: box.minY, width: 0, height: box.height)
    }

    /// The pointing hand over every pill, whatever the text view does with the cursor (WAG-359).
    override func resetCursorRects() {
        super.resetCursorRects()
        for view in pillViews { addCursorRect(view.frame, cursor: .pointingHand) }
    }

    private func isOnPill(_ point: NSPoint) -> Bool { pillViews.contains { $0.frame.contains(point) } }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isOnPill(point) {
            NSCursor.pointingHand.set()
            if hoveredId != nil {
                hoveredId = nil
                applyHighlights()
                hub?.hoverChanged(id: nil, key: target.key, rect: .zero)
            }
            return
        }
        super.mouseMoved(with: event)
        let id = commentId(at: convert(event.locationInWindow, from: nil))
        guard id != hoveredId else { return }
        hoveredId = id
        applyHighlights()
        hub?.hoverChanged(id: id, key: target.key, rect: id.map { rect(ofComment: $0) } ?? .zero)
        if id != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hoveredId != nil {
            hoveredId = nil
            applyHighlights()
            hub?.hoverChanged(id: nil, key: target.key, rect: .zero)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A pill takes its own click. If one reaches the text, it still never selects.
        if isOnPill(point) { return }
        sourcesHub?.clickedOutside(at: CGPoint(x: point.x + sourcesOrigin.x, y: point.y + sourcesOrigin.y))
        hub?.pointerDown()
        if let pin = pinLayer.items.last(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) {
            hub?.openNote(id: pin.id, key: target.key, rect: rect(ofComment: pin.id))
            return
        }
        hub?.willSelect(in: self)
        super.mouseDown(with: event)
        // A plain click (no drag, so no selection) on a highlight opens its note.
        if selectedRange().length == 0, event.clickCount == 1, let id = commentId(at: point) {
            hub?.openNote(id: id, key: target.key, rect: rect(ofComment: id))
        }
    }

    override func keyDown(with event: NSEvent) {
        let blocked: NSEvent.ModifierFlags = [.command, .control, .option]
        if event.charactersIgnoringModifiers?.lowercased() == "c", event.modifierFlags.intersection(blocked).isEmpty,
           hub?.ui.selection?.key == target.key {
            hub?.beginDraft()
            return
        }
        if event.charactersIgnoringModifiers?.lowercased() == "e", event.modifierFlags.intersection(blocked).isEmpty,
           hub?.onExplain != nil, hub?.ui.selection?.key == target.key {
            hub?.explainSelection()
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        // The selection stays while the Comment button or the note is used.
        super.resignFirstResponder()
    }

    // MARK: Selection

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionChangedInternal()
    }

    private func selectionChangedInternal() {
        guard let content else { return }
        let sel = selectedRange()
        guard sel.length > 0, canComment,
              let range = content.plainRange(forRendered: sel.location..<(sel.location + sel.length)) else {
            hub?.selectionCleared(key: target.key)
            return
        }
        let anchor = target.anchor(quote: content.quote(forPlain: range), start: range.lowerBound, end: range.upperBound)
        let end = endRect(of: sel)
        // A card that shows this text stays open while the person comments.
        sourcesHub?.holdShownCard()
        hub?.selectionChanged(key: target.key, target: target, anchor: anchor, rect: end)
    }

    /// The rect of the line the selection ends on (view coordinates), zero width at the end of the selection.
    private func endRect(of range: NSRange) -> CGRect {
        guard let box = glyphBox(forCharacter: max(0, range.location + range.length - 1)) else { return .zero }
        return CGRect(x: box.maxX, y: box.minY, width: 0, height: box.height)
    }

    // MARK: Evidence

    /// Evidence hooks, read once per view. `KNOCK_EVIDENCE_ASK_COMMENTS="part::phrase::note;;part::phrase::note"`
    /// saves comments, `KNOCK_EVIDENCE_ASK_SELECT="part::phrase"` selects a phrase (the Comment button shows),
    /// `KNOCK_EVIDENCE_ASK_DRAFT="note"` also opens the note popover with that text. Only in an evidence process.
    func runEvidenceHooksOnce() {
        guard !evidenceRan, let content, window != nil || superview != nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["KNOCK_BUNDLE_ID"]?.hasPrefix("dev.limone.knock.evidence") == true,
              env["KNOCK_EVIDENCE_ASK_COMMENTS"] != nil || env["KNOCK_EVIDENCE_ASK_SELECT"] != nil else { return }
        evidenceRan = true
        let part = target.part.rawValue
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if let spec = env["KNOCK_EVIDENCE_ASK_COMMENTS"] {
                for item in spec.components(separatedBy: ";;") {
                    let pieces = item.components(separatedBy: "::")
                    guard pieces.count == 3, pieces[0] == part,
                          let r = self.plainRange(of: pieces[1], in: content) else { continue }
                    let anchor = self.target.anchor(quote: content.quote(forPlain: r), start: r.lowerBound, end: r.upperBound)
                    self.hub?.store?.addAskComment(anchor: anchor, text: pieces[2])
                }
            }
            if let spec = env["KNOCK_EVIDENCE_ASK_SELECT"] {
                let pieces = spec.components(separatedBy: "::")
                if pieces.count == 2, pieces[0] == part, let r = self.plainRange(of: pieces[1], in: content),
                   let rendered = content.renderedRange(forPlain: r) {
                    self.window?.makeFirstResponder(self)
                    self.hub?.willSelect(in: self)
                    self.setSelectedRange(NSRange(location: rendered.lowerBound, length: rendered.count))
                    if let note = env["KNOCK_EVIDENCE_ASK_DRAFT"] { self.hub?.beginDraft(initialText: note) }
                }
            }
        }
    }

    private func plainRange(of phrase: String, in content: AskTextContent) -> Range<Int>? {
        let found = (content.plain as NSString).range(of: phrase)
        return found.location == NSNotFound ? nil : found.location..<(found.location + found.length)
    }
}

/// Measures wrapped text without a view. Keeps the height of the last few widths (WAG-365): SwiftUI asks one text with
/// two or more widths in turn, and a typeset of a long text costs more than all the rest of a layout pass.
@MainActor
final class TextMeasurer {
    /// How many widths it keeps. The oldest goes first. One layout pass asks one text with a dozen widths (the minimum, the
    /// ideal and the real size of each stack above it, WAG-375). Eight was the edge: a ninth width, asked in the same
    /// order each pass, evicted the oldest just before its turn, so every ask typeset again.
    static let capacity = 32
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
    private var heights: [Int: CGFloat] = [:]
    private var order: [Int] = []
    /// Real typesets, for tests.
    private(set) var typesets = 0

    init() {
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
    }

    func set(_ text: NSAttributedString) {
        storage.setAttributedString(text)
        heights = [:]
        order = []
    }

    /// A 64th of a point: finer than any wrap can tell apart, coarse enough to take a float error as the same width.
    private static func key(_ width: CGFloat) -> Int { Int((width * 64).rounded()) }

    func height(forWrapWidth width: CGFloat) -> CGFloat {
        let key = Self.key(width)
        if let known = heights[key] { return known }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        EvidenceLayoutLog.event("typeset", "w=\(width) h=\(height)")
        typesets += 1
        if order.count >= Self.capacity { heights[order.removeFirst()] = nil }
        heights[key] = height
        order.append(key)
        return height
    }
}

/// The numbers over the saved ranges. Draws only; clicks go to the text view, which hit-tests the same rects.
final class AskPinLayer: NSView {
    struct Item: Equatable {
        let id: String
        let number: Int
        let rect: NSRect
        let selected: Bool
    }

    var items: [Item] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        for item in items {
            if item.selected {
                NSColor(Theme.Colors.accent).withAlphaComponent(0.3).setStroke()
                let ring = NSBezierPath(ovalIn: item.rect.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 2
                ring.stroke()
            }
            NSColor(Theme.Colors.accent).setFill()
            NSBezierPath(ovalIn: item.rect).fill()
            let label = NSAttributedString(string: "\(item.number)", attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: NSColor(Theme.Colors.onFill),
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: item.rect.midX - size.width / 2, y: item.rect.midY - size.height / 2))
        }
    }
}
