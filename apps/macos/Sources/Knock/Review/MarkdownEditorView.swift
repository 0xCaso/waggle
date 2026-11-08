import AppKit
import SwiftUI

/// HAIL-168: the document while the person edits it in place. It keeps the formatted look of the
/// reading view (headings, bold, italics, lists, code), and shows what the person changed: removed
/// text struck through in the accent colour on accent-soft, added text in the ok colour on ok-soft.
/// The person edits the text, not the markdown.
@MainActor
final class MarkdownEditSession: ObservableObject {
    /// The revision the person started from.
    let baseRevision: Int
    private(set) var model: MarkdownEditModel
    /// Counts the edits, so the text view knows when to draw again.
    @Published private(set) var version = 0

    /// True for "Compare with v1": the marks show, nothing can be typed.
    let isReadOnly: Bool

    init(markdown: String, baseRevision: Int) {
        self.baseRevision = baseRevision
        self.model = MarkdownEditModel(markdown: markdown)
        self.isReadOnly = false
    }

    init(comparing old: String, to new: String, baseRevision: Int) {
        self.baseRevision = baseRevision
        self.model = MarkdownEditModel.comparison(from: old, to: new)
        self.isReadOnly = true
    }

    var hasChanges: Bool { model.hasChanges }
    var markdown: String { model.markdown() }

    func replace(_ range: Range<Int>, with text: String) -> Int? {
        guard let caret = model.replace(range, with: text) else { return nil }
        version += 1
        return caret
    }

    func undo() -> Bool {
        guard model.undo() else { return false }
        version += 1
        return true
    }

    func redo() -> Bool {
        guard model.redo() else { return false }
        version += 1
        return true
    }
}

extension MarkdownEditModel {
    /// The displayed text in the app's own typography, with the edit marks on top.
    func attributedString() -> NSAttributedString {
        var rendered = RenderedMarkdown()
        rendered.text = units.map(\.u)
        rendered.source = [Int](repeating: -1, count: units.count)
        rendered.styles = units.map(\.style)
        rendered.linkIndex = units.map(\.link)
        rendered.links = base.links
        var i = 0
        while i < units.count {
            var j = i + 1
            while j < units.count, units[j].block == units[i].block { j += 1 }
            rendered.blocks.append(RenderedMarkdown.Block(range: i..<j, kind: base.blocks[units[i].block].kind))
            i = j
        }
        let out = NSMutableAttributedString(attributedString: rendered.attributedString())
        let accent = NSColor(Theme.Colors.accent)
        let accentSoft = NSColor(Theme.Colors.accentSoft)
        let ok = NSColor(Theme.Colors.ok)
        let okSoft = NSColor(Theme.Colors.okSoft)
        var k = 0
        while k < units.count {
            let state = units[k].state
            var end = k + 1
            while end < units.count, units[end].state == state { end += 1 }
            let range = NSRange(location: k, length: end - k)
            switch state {
            case .deleted:
                out.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: accent,
                    .foregroundColor: accent,
                    .backgroundColor: accentSoft,
                ], range: range)
            case .added:
                out.addAttributes([.foregroundColor: ok, .backgroundColor: okSoft], range: range)
                // The bullet of a new list item keeps the quiet marker colour.
                for m in k..<end where units[m].role == .marker {
                    out.addAttribute(.foregroundColor, value: NSColor(Theme.Colors.ink3), range: NSRange(location: m, length: 1))
                    out.removeAttribute(.backgroundColor, range: NSRange(location: m, length: 1))
                }
            case .kept:
                break
            }
            k = end
        }
        return out
    }
}

struct MarkdownEditorView: NSViewRepresentable {
    @ObservedObject var session: MarkdownEditSession
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MarkdownStageScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = MarkdownEditTextView.make()
        scroll.documentView = textView
        textView.autoresizingMask = [.width]
        textView.session = session
        textView.onCancel = onCancel
        textView.isEditable = !session.isReadOnly
        textView.reload(selecting: NSRange(location: 0, length: 0))
        context.coordinator.textView = textView
        if !session.isReadOnly {
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.onCancel = onCancel
        textView.session = session
        if textView.shownVersion != session.version {
            textView.reload(selecting: textView.selectedRange())
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var textView: MarkdownEditTextView?
    }
}

final class MarkdownEditTextView: NSTextView, NSTextViewDelegate {
    var session: MarkdownEditSession?
    var onCancel: () -> Void = {}
    private(set) var shownVersion = -1

    private static let inset = NSSize(width: 44, height: 28)

    static func make() -> MarkdownEditTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = MarkdownEditTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.isEditable = true
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.allowsUndo = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = inset
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.delegate = view
        view.linkTextAttributes = ([
            .foregroundColor: NSColor(Theme.Colors.accent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ] as [NSAttributedString.Key: Any])
        view.selectedTextAttributes = ([.backgroundColor: NSColor(Theme.Colors.ds).withAlphaComponent(0.22)] as [NSAttributedString.Key: Any])
        view.insertionPointColor = NSColor(Theme.Colors.ds)
        return view
    }

    /// Draws the session's text again and puts the caret back.
    func reload(selecting selection: NSRange) {
        guard let session else { return }
        textStorage?.setAttributedString(session.model.attributedString())
        shownVersion = session.version
        let length = textStorage?.length ?? 0
        let location = min(selection.location, length)
        setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(Theme.Colors.ink)]
    }

    // MARK: Editing

    /// Every change goes through the session: it marks removed text instead of deleting it, and
    /// types new text as added text. The text view is then drawn again from the session.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard let session, let replacementString else { return true }
        // A dead key or an input method is composing: the system owns the text until it commits.
        if hasMarkedText() { return true }
        let r = range.location..<(range.location + range.length)
        if let caret = session.replace(r, with: replacementString) {
            // A removal puts the caret at the start of what it struck, like a word processor does.
            let location = replacementString.isEmpty ? range.location : caret
            reload(selecting: NSRange(location: location, length: 0))
        } else if replacementString.isEmpty, range.length > 0 {
            // Backspace over text that is already struck, or over a bullet: the caret just steps back.
            setSelectedRange(NSRange(location: range.location, length: 0))
        } else {
            NSSound.beep()
        }
        return false
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { true }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func cancelOperation(_ sender: Any?) { onCancel() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "z", let session else {
            return super.performKeyEquivalent(with: event)
        }
        let changed = event.modifierFlags.contains(.shift) ? session.redo() : session.undo()
        if changed { reload(selecting: selectedRange()) }
        return true
    }
}
