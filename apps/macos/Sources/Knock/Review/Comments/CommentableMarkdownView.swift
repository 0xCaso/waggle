import AppKit
import SwiftUI

/// HAIL-150: a markdown explanation the operator can select text in and comment on.
///
/// The text shows in one `NSTextView` (a SwiftUI `Text` cannot report a selection, and a selection
/// across paragraphs needs one text system). `RenderedMarkdown` gives the text and the map from each
/// rendered character back to the markdown source, so a selection becomes a source range
/// (`TextAnchor`) and a saved range becomes a highlight again.
///
/// - Select text: a "Comment" button appears near it. `C` does the same.
/// - The note popover is the pin note popover. Enter saves, Escape cancels.
/// - A saved range keeps a soft hail tint and its number in the left margin. Hover shows the note;
///   a click selects the comment in the Comments tab.
/// - Overlapping ranges: each tint stacks (a character under two or more comments is darker), and
///   every number shows. Numbers on one line sit side by side.
struct CommentableMarkdownView: View {
    let markdown: String
    let revision: Int
    @ObservedObject var store: CommentsSessionStore
    /// Comments to draw that are not in `store` (a sent reply's, or an older revision's).
    var extraComments: [Comment] = []
    /// False when the answer is locked or the revision is an older one: highlights only.
    var canComment: Bool = true
    var onSelectComment: (String) -> Void = { _ in }
    /// WAG-322: the changes since an older version, marked in place. Text comments anchor to `markdown` (the new version).
    var changes: WriteUpDiff.Result? = nil
    var scrollRequest: WriteUpBlockRequest? = nil
    var flashRequest: WriteUpBlockRequest? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.explainSelection) private var explainSelection
    @StateObject private var linkGate = MarkdownLinkGate()

    private var comments: [Comment] {
        let own = store.model.textComments(onRevision: revision)
        let ids = Set(own.map(\.id))
        return (own + extraComments.filter { !ids.contains($0.id) && $0.anchor?.revision == revision }).sorted { $0.n < $1.n }
    }

    var body: some View {
        MarkdownCommentTextRepresentable(
            markdown: markdown,
            revision: revision,
            changes: changes,
            scrollRequest: scrollRequest,
            flashRequest: flashRequest,
            animates: !reduceMotion,
            comments: comments,
            selectedId: store.selectedCommentId,
            previewId: store.previewCommentId,
            reveal: store.revealRequest,
            canComment: canComment,
            nextNumber: store.nextPinNumber,
            onExplain: explainSelection,
            onSave: { anchor, text in
                if let comment = store.addTextComment(anchor: anchor, text: text) {
                    store.selectComment(id: comment.id, origin: .artifact)
                }
            },
            onSelect: { id in
                store.selectComment(id: id, origin: .artifact)
                onSelectComment(id)
            },
            onHover: { id, inside in store.pinHoverChanged(id, inside: inside) },
            onOpenLink: { url in
                switch LinkOpenPolicy.decide(confirmEnabled: LinkConfirmSettings.isEnabled()) {
                case .confirm: linkGate.requestOpen(url)
                case .openDirectly: NSWorkspace.shared.open(url)
                }
            }
        )
        .alert(
            "Open this link?",
            isPresented: Binding(get: { linkGate.pendingURL != nil }, set: { if !$0 { linkGate.cancel() } })
        ) {
            Button("Cancel", role: .cancel) { linkGate.cancel() }
            Button("Open") { linkGate.confirm(open: { NSWorkspace.shared.open($0) }) }
        } message: {
            Text(linkGate.pendingURL?.absoluteString ?? "")
        }
    }
}

private struct MarkdownCommentTextRepresentable: NSViewRepresentable {
    let markdown: String
    let revision: Int
    let changes: WriteUpDiff.Result?
    let scrollRequest: WriteUpBlockRequest?
    let flashRequest: WriteUpBlockRequest?
    let animates: Bool
    let comments: [Comment]
    let selectedId: String?
    let previewId: String?
    let reveal: CommentRevealRequest?
    let canComment: Bool
    let nextNumber: Int
    let onExplain: ((String) -> Void)?
    let onSave: (TextAnchor, String) -> Void
    let onSelect: (String) -> Void
    let onHover: (String, Bool) -> Void
    let onOpenLink: (URL) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MarkdownStageScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = MarkdownCommentTextView.make()
        scroll.documentView = textView
        textView.autoresizingMask = [.width]
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.onSave = onSave
        textView.onSelect = onSelect
        textView.onHover = onHover
        textView.onOpenLink = onOpenLink
        textView.onExplain = onExplain
        textView.canComment = canComment
        textView.nextNumber = nextNumber
        textView.setContent(markdown: markdown, revision: revision, changes: changes)
        textView.setComments(comments, selectedId: selectedId, previewId: previewId)
        if let reveal, reveal.origin == .list, reveal.token != context.coordinator.lastRevealToken {
            context.coordinator.lastRevealToken = reveal.token
            textView.reveal(commentId: reveal.commentId)
        }
        if let scrollRequest, scrollRequest != context.coordinator.lastScroll {
            context.coordinator.lastScroll = scrollRequest
            textView.scroll(toEntry: scrollRequest.entry, animated: animates)
        }
        if let flashRequest, flashRequest != context.coordinator.lastFlash {
            context.coordinator.lastFlash = flashRequest
            if animates { textView.flash(entry: flashRequest.entry) }
        }
        textView.runEvidenceHooksOnce()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var textView: MarkdownCommentTextView?
        var lastRevealToken = 0
        var lastScroll: WriteUpBlockRequest?
        var lastFlash: WriteUpBlockRequest?
    }
}

/// The width rules for the markdown stage. Pure, so a test can check them.
enum MarkdownStageWidth {
    /// The width of the text view: always the width the scroll view offers, never the last
    /// width the text view had (a fixed frame made long lines run past the stage edge).
    static func documentWidth(offered: CGFloat) -> CGFloat { max(1, offered.rounded(.down)) }

    /// The width the text wraps at: the document width minus the side insets.
    static func wrapWidth(documentWidth: CGFloat, inset: CGFloat) -> CGFloat { max(1, documentWidth - 2 * inset) }
}

/// A scroll view that sizes its text view to its own width on every layout pass, so markdown
/// wraps to the stage at every window size, after a resize, and in an older revision.
final class MarkdownStageScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView, let container = textView.textContainer else { return }
        let width = MarkdownStageWidth.documentWidth(offered: contentSize.width)
        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        }
        let wrap = MarkdownStageWidth.wrapWidth(documentWidth: width, inset: textView.textContainerInset.width)
        if abs(container.size.width - wrap) > 0.5 {
            container.size = NSSize(width: wrap, height: container.size.height)
        }
    }
}

// MARK: - The text view

final class MarkdownCommentTextView: NSTextView, NSTextViewDelegate {
    var onSave: (TextAnchor, String) -> Void = { _, _ in }
    var onSelect: (String) -> Void = { _ in }
    var onHover: (String, Bool) -> Void = { _, _ in }
    var onOpenLink: (URL) -> Void = { _ in }
    var canComment = true { didSet { if oldValue != canComment { selectionChanged() } } }
    var nextNumber = 1

    private(set) var rendered = RenderedMarkdown()
    private var revision = 0
    private var loadedMarkdown: String?
    private var loadedChanges: WriteUpDiff.Result?
    private var flashRange: Range<Int>?
    private var comments: [Comment] = []
    private var ranges: [String: Range<Int>] = [:]
    private var selectedId: String?
    private var hoveredId: String?
    private var flashId: String?
    private var previewId: String?
    private var badges: [(id: String, rect: NSRect)] = []
    private var draftRange: Range<Int>?
    private var draftView: NSView?
    private var buttonView: NSView?
    /// WAG-384: sends the "Explain" request for the selected text; `nil` hides the Explain button.
    var onExplain: ((String) -> Void)?
    private var previewView: NSView?
    private var evidenceHooksRan = false
    private var badgeView: MarginBadgeView?

    private static let inset = NSSize(width: 44, height: 28)
    private static let tint = NSColor(Theme.Colors.accent)

    static func make() -> MarkdownCommentTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = MarkdownCommentTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = inset
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = view
        view.linkTextAttributes = ([
            .foregroundColor: NSColor(Theme.Colors.accent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ] as [NSAttributedString.Key: Any])
        view.selectedTextAttributes = ([.backgroundColor: NSColor(Theme.Colors.accent).withAlphaComponent(0.25)] as [NSAttributedString.Key: Any])
        return view
    }

    // MARK: Content

    func setContent(markdown: String, revision: Int, changes: WriteUpDiff.Result? = nil) {
        guard loadedMarkdown != markdown || self.revision != revision || loadedChanges != changes else { return }
        loadedMarkdown = markdown
        loadedChanges = changes
        self.revision = revision
        rendered = RenderedMarkdown.parse(markdown)
        if let changes { rendered = rendered.markingChanges(changes) }
        flashRange = nil
        needsDisplay = true
        textStorage?.setAttributedString(rendered.attributedString())
        closeDraft()
        hideButton()
        ranges = [:]
        comments = []
    }

    func setComments(_ comments: [Comment], selectedId: String?, previewId: String?) {
        let changed = self.comments != comments || self.selectedId != selectedId
        self.comments = comments
        self.selectedId = selectedId
        ranges = [:]
        for comment in comments {
            guard let anchor = comment.anchor, anchor.start >= 0, anchor.end <= rendered.sourceText.count,
                  let range = rendered.renderedRange(forSource: anchor.start..<anchor.end) else { continue }
            ranges[comment.id] = range
        }
        if changed || self.previewId != previewId { applyHighlights() }
        if self.previewId != previewId {
            self.previewId = previewId
            showPreview()
        }
    }

    // MARK: Highlights

    private func applyHighlights() {
        guard let layout = layoutManager, let storage = textStorage, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        if let flash = flashRange, flash.upperBound <= storage.length {
            layout.addTemporaryAttribute(
                .backgroundColor, value: NSColor(Theme.Colors.honeySoft), forCharacterRange: NSRange(location: flash.lowerBound, length: flash.count))
        }
        var depth = [Int](repeating: 0, count: storage.length)
        for range in ranges.values { for i in range where i < depth.count { depth[i] += 1 } }
        func level(_ i: Int) -> Int {
            if let range = draftRange, range.contains(i) { return 4 }
            if let id = flashId ?? selectedId ?? hoveredId, let range = ranges[id], range.contains(i) { return 3 }
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
                    .backgroundColor, value: Self.tint.withAlphaComponent(alphas[l]),
                    forCharacterRange: NSRange(location: i, length: j - i)
                )
            }
            i = j
        }
        layoutBadges()
    }

    /// Scrolls to a comment's range and flashes it (a click on its card in the Comments tab).
    func reveal(commentId: String) {
        guard let range = ranges[commentId] else { return }
        scrollRangeToVisible(NSRange(location: range.lowerBound, length: range.count))
        flashId = commentId
        applyHighlights()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.flashId == commentId else { return }
            self.flashId = nil
            self.applyHighlights()
        }
    }

    // MARK: Changes since an older version (WAG-322)

    /// The rendered characters of the blocks that belong to one entry of the diff.
    private func characters(ofEntry entry: Int) -> Range<Int>? {
        let owned = rendered.blocks.filter { $0.entry == entry }
        guard let first = owned.first, let last = owned.last else { return nil }
        return first.range.lowerBound..<last.range.upperBound
    }

    private func rect(ofCharacters range: Range<Int>) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer, range.count > 0 else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.lowerBound, length: range.count), actualCharacterRange: nil)
        let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let origin = textContainerOrigin
        return box.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Scrolls so the block of a diff entry sits near the top of the stage.
    func scroll(toEntry entry: Int, animated: Bool) {
        guard let range = characters(ofEntry: entry), let box = rect(ofCharacters: range), let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let y = min(max(0, box.minY - 12), max(0, bounds.height - clip.bounds.height))
        let target = NSPoint(x: 0, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                clip.animator().setBoundsOrigin(target)
            }, completionHandler: { scroll.reflectScrolledClipView(clip) })
        } else {
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// A soft honey flash on a block, 600 ms, as in the read-only inline view.
    func flash(entry: Int) {
        guard let range = characters(ofEntry: entry) else { return }
        flashRange = range
        applyHighlights()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, self.flashRange == range else { return }
            self.flashRange = nil
            self.applyHighlights()
        }
    }

    /// The honey bar beside every changed, added or removed block, one per diff entry.
    private func changeBars() -> [NSRect] {
        var seen = Set<Int>()
        var bars: [NSRect] = []
        for block in rendered.blocks where block.marked {
            guard let entry = block.entry, seen.insert(entry).inserted,
                  let range = characters(ofEntry: entry), let box = rect(ofCharacters: range) else { continue }
            bars.append(NSRect(x: textContainerOrigin.x - 6, y: box.minY, width: 3, height: box.height))
        }
        return bars
    }

    // MARK: Margin numbers

    /// Places the margin numbers: one per comment, at its first line, side by side when several
    /// start on the same line. They are drawn by `MarginBadgeView`, a subview over the gutter.
    private func layoutBadges() {
        guard let layout = layoutManager, let storage = textStorage else { return }
        badges = []
        let origin = textContainerOrigin
        var usedPerLine: [CGFloat: Int] = [:]
        let size = Theme.Spacing.pinSmall
        for comment in comments {
            guard let range = ranges[comment.id], range.lowerBound < storage.length else { continue }
            let glyph = layout.glyphIndexForCharacter(at: range.lowerBound)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = (line.minY + origin.y + (line.height - size) / 2).rounded()
            let k = usedPerLine[y, default: 0]
            usedPerLine[y] = k + 1
            let x = origin.x - 8 - size - CGFloat(k) * (size + 3)
            badges.append((comment.id, NSRect(x: x, y: y, width: size, height: size)))
        }
        let view: MarginBadgeView
        if let existing = badgeView {
            view = existing
        } else {
            view = MarginBadgeView()
            addSubview(view)
            badgeView = view
        }
        view.frame = NSRect(x: 0, y: 0, width: origin.x, height: bounds.height)
        view.items = badges.compactMap { badge in
            comments.first { $0.id == badge.id }.map { (number: $0.n, rect: badge.rect, selected: $0.id == selectedId) }
        }
        view.bars = changeBars()
        view.needsDisplay = true
    }

    // MARK: Mouse and keys

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func commentId(at point: NSPoint) -> String? {
        if let badge = badges.last(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) { return badge.id }
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
        let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard box.insetBy(dx: -1, dy: 0).contains(local) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        // The later comment wins where ranges overlap.
        return comments.last(where: { ranges[$0.id]?.contains(index) == true })?.id
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let id = commentId(at: convert(event.locationInWindow, from: nil))
        guard id != hoveredId else { return }
        if let old = hoveredId { onHover(old, false) }
        hoveredId = id
        if let id { onHover(id, true) }
        NSCursor.pointingHand.set()
        if id == nil { NSCursor.iBeam.set() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if let old = hoveredId { onHover(old, false) }
        hoveredId = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let badge = badges.last(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) {
            onSelect(badge.id)
            return
        }
        closeDraft()
        super.mouseDown(with: event)
        // A plain click (no drag, so no selection) on a highlight selects its comment.
        if selectedRange().length == 0, event.clickCount == 1, let id = commentId(at: point) { onSelect(id) }
    }

    override func keyDown(with event: NSEvent) {
        let blocked: NSEvent.ModifierFlags = [.command, .control, .option]
        if event.charactersIgnoringModifiers?.lowercased() == "c", event.modifierFlags.intersection(blocked).isEmpty,
           beginDraft() { return }
        if event.charactersIgnoringModifiers?.lowercased() == "e", event.modifierFlags.intersection(blocked).isEmpty,
           explainSelection() { return }
        if event.keyCode == 53, draftView != nil { closeDraft(); return }
        super.keyDown(with: event)
    }

    // MARK: Selection and the Comment button

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionChanged()
    }

    private func selectionChanged() {
        guard draftView == nil else { return }
        if currentAnchor() != nil, canComment { showButton() } else { hideButton() }
    }

    /// The anchor for the current selection, or `nil` with nothing commentable selected.
    func currentAnchor() -> TextAnchor? {
        let sel = selectedRange()
        guard sel.length > 0, let range = rendered.sourceRange(forRendered: sel.location..<(sel.location + sel.length)) else { return nil }
        return TextAnchor(revision: revision, quote: rendered.quote(forSource: range), start: range.lowerBound, end: range.upperBound)
    }

    /// The rect (view coordinates) of the line the selection ends on.
    private func endRect(of range: NSRange) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer, range.length > 0 else { return nil }
        let lastGlyph = layout.glyphIndexForCharacter(at: range.location + range.length - 1)
        let line = layout.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        let box = layout.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: container)
        let origin = textContainerOrigin
        return NSRect(x: origin.x + box.maxX, y: origin.y + line.minY, width: 0, height: line.height)
    }

    private func place(_ view: NSView, at anchor: NSRect, width: CGFloat? = nil) {
        let size = view.fittingSize
        let w = width ?? size.width
        var x = anchor.minX - 4
        x = min(x, bounds.width - w - 4)
        x = max(x, 4)
        view.frame = NSRect(x: x, y: anchor.maxY - 2, width: w, height: size.height)
    }

    private func showButton() {
        guard let end = endRect(of: selectedRange()) else { return hideButton() }
        let button = MarkdownCommentButton(
            onTap: { [weak self] in self?.beginDraft() },
            onExplain: onExplain == nil ? nil : { [weak self] in self?.explainSelection() })
        let host = (buttonView as? NSHostingView<MarkdownCommentButton>) ?? NSHostingView(rootView: button)
        host.rootView = button
        if buttonView == nil { addSubview(host); buttonView = host }
        place(host, at: end)
    }

    /// The Explain button or the E key (WAG-384): sends the request for the selected text.
    @discardableResult
    func explainSelection() -> Bool {
        guard canComment, draftView == nil, let onExplain, currentAnchor() != nil else { return false }
        let selection = (string as NSString).substring(with: selectedRange())
        setSelectedRange(NSRange(location: selectedRange().upperBound, length: 0))
        hideButton()
        onExplain(selection)
        return true
    }

    private func hideButton() {
        buttonView?.removeFromSuperview()
        buttonView = nil
    }

    // MARK: The note popover

    @discardableResult
    func beginDraft(initialText: String = "") -> Bool {
        guard canComment, draftView == nil, let anchor = currentAnchor(), let range = rendered.renderedRange(forSource: anchor.start..<anchor.end) else { return false }
        let end = endRect(of: selectedRange())
        hideButton()
        draftRange = range
        setSelectedRange(NSRange(location: range.upperBound, length: 0))
        applyHighlights()
        let view = NSHostingView(rootView: MarkdownDraftNoteView(
            number: nextNumber,
            text: initialText,
            onSave: { [weak self] text in
                guard let self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.closeDraft()
                if !trimmed.isEmpty { self.onSave(anchor, trimmed) }
            },
            onCancel: { [weak self] in self?.closeDraft() },
            onResize: { [weak self] in self?.refitDraft(at: end ?? .zero) }
        ))
        addSubview(view)
        draftView = view
        place(view, at: end ?? .zero, width: Theme.Spacing.notePopoverWidth + 22)
        scrollToVisible(view.frame.insetBy(dx: 0, dy: -12))
        DispatchQueue.main.async { [weak self, weak view] in
            guard let view, let window = self?.window else { return }
            // The note field takes focus itself; only fall back to the host when it did not.
            if let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) { return }
            window.makeFirstResponder(view)
        }
        return true
    }

    /// The note grows as the person types: fit the popover to its new height once SwiftUI has laid it out.
    private func refitDraft(at anchor: NSRect) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.draftView else { return }
            self.place(view, at: anchor, width: Theme.Spacing.notePopoverWidth + 22)
            self.scrollToVisible(view.frame.insetBy(dx: 0, dy: -12))
        }
    }

    func closeDraft() {
        guard draftView != nil || draftRange != nil else { return }
        draftView?.removeFromSuperview()
        draftView = nil
        draftRange = nil
        applyHighlights()
        window?.makeFirstResponder(self)
    }

    // MARK: Hover note

    private func showPreview() {
        previewView?.removeFromSuperview()
        previewView = nil
        guard let id = previewId, draftView == nil, let range = ranges[id],
              let comment = comments.first(where: { $0.id == id }),
              let rect = endRect(of: NSRange(location: range.lowerBound, length: 1)) else { return }
        let host = NSHostingView(rootView: MarkdownHoverNoteView(text: comment.text))
        host.frame.size = NSSize(width: Theme.Spacing.notePopoverWidth + 22, height: host.fittingSize.height)
        addSubview(host)
        previewView = host
        place(host, at: NSRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height), width: Theme.Spacing.notePopoverWidth + 22)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutBadges()
        if let button = buttonView { place(button, at: endRect(of: selectedRange()) ?? .zero) }
    }

    // MARK: Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { onOpenLink(url) } else if let text = link as? String, let url = URL(string: text) { onOpenLink(url) }
        return true
    }

    // MARK: Evidence

    /// Evidence hooks (HAIL-150), read once per view:
    /// `KNOCK_EVIDENCE_MD_COMMENTS="rendered phrase::note;;phrase::note"` saves comments,
    /// `KNOCK_EVIDENCE_MD_SELECT="phrase"` selects a phrase (the Comment button shows),
    /// `KNOCK_EVIDENCE_MD_DRAFT="note"` also opens the note popover with that text.
    func runEvidenceHooksOnce() {
        guard !evidenceHooksRan, loadedMarkdown != nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["KNOCK_EVIDENCE_MD_COMMENTS"] != nil || env["KNOCK_EVIDENCE_MD_SELECT"] != nil else { return }
        evidenceHooksRan = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if let spec = env["KNOCK_EVIDENCE_MD_COMMENTS"] {
                for item in spec.components(separatedBy: ";;") {
                    let parts = item.components(separatedBy: "::")
                    guard parts.count == 2, let anchor = self.anchor(forPhrase: parts[0]) else { continue }
                    self.onSave(anchor, parts[1])
                }
            }
            if let pick = env["KNOCK_EVIDENCE_MD_PICK"].flatMap(Int.init) {
                // Selects that comment as a click on its number would: the Comments tab opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, pick >= 1, pick <= self.comments.count else { return }
                    self.onSelect(self.comments[pick - 1].id)
                }
            }
            if let phrase = env["KNOCK_EVIDENCE_MD_SELECT"], let range = self.renderedNSRange(of: phrase) {
                self.window?.makeFirstResponder(self)
                self.setSelectedRange(range)
                if let note = env["KNOCK_EVIDENCE_MD_DRAFT"] {
                    self.beginDraft(initialText: note)
                }
            }
        }
    }

    private func renderedNSRange(of phrase: String) -> NSRange? {
        let found = (rendered.string as NSString).range(of: phrase)
        return found.location == NSNotFound ? nil : found
    }

    private func anchor(forPhrase phrase: String) -> TextAnchor? {
        guard let r = renderedNSRange(of: phrase),
              let src = rendered.sourceRange(forRendered: r.location..<(r.location + r.length)) else { return nil }
        return TextAnchor(revision: revision, quote: rendered.quote(forSource: src), start: src.lowerBound, end: src.upperBound)
    }
}

/// The numbers in the left margin of a markdown explanation (HAIL-150). Draws only; clicks pass
/// through to the text view, which hit-tests the same rects.
private final class MarginBadgeView: NSView {
    var items: [(number: Int, rect: NSRect, selected: Bool)] = []
    /// WAG-322: the honey bars of the inline changes view.
    var bars: [NSRect] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.Colors.honey500).setFill()
        for bar in bars { NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill() }
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

