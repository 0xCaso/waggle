import AppKit
import SwiftUI

/// The pure rules of the new-note field (HAIL-233): one line while the text is
/// short, wrapping and growing up to `maxLines`, then scrolling inside. The
/// popover takes its height from `popoverHeight`, so it grows with the field
/// and the placement code can keep it on screen.
enum NoteFieldLogic {
    static let maxLines = 4
    /// `body12_5w400`: 12.5 pt on a 1.4 line height.
    static let lineHeight: CGFloat = 17.5
    /// Width the text wraps in: the popover less its 12 pt padding on each side.
    static let textWidth: CGFloat = Theme.Spacing.notePopoverWidth - 24

    static var font: NSFont { PromptBarLogic.sansFont(size: 12.5) }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    static func lineCount(text: String, textWidth: CGFloat = NoteFieldLogic.textWidth) -> Int {
        PromptBarLogic.lineCount(text: text, textWidth: textWidth, font: font, paragraphStyle: paragraphStyle)
    }

    static func visibleLines(totalLines: Int) -> Int {
        PromptBarLogic.visibleLines(totalLines: totalLines, maxLines: maxLines)
    }

    static func scrolls(totalLines: Int) -> Bool {
        PromptBarLogic.scrolls(totalLines: totalLines, maxLines: maxLines)
    }

    static func fieldHeight(totalLines: Int) -> CGFloat {
        CGFloat(visibleLines(totalLines: totalLines)) * lineHeight
    }

    static func fieldHeight(text: String) -> CGFloat {
        fieldHeight(totalLines: lineCount(text: text))
    }

    /// Padding (12 + 12), header (about 14), the hint (about 13) and two 8 pt gaps around the field.
    static let chromeHeight: CGFloat = 24 + 14 + 13 + 16

    static func popoverHeight(text: String) -> CGFloat {
        chromeHeight + fieldHeight(text: text)
    }
}

/// Which way an arrow key goes (HAIL-233). While a text field or text view has
/// focus the arrows belong to its cursor, so they never flip the screenshot
/// and never lose the pending comment and its region pointer.
enum ReviewArrowKeys {
    enum Route: Equatable {
        case previous
        case next
        /// Not ours: the key goes on to the focused view.
        case passThrough
    }

    static let leftArrowKeyCode: UInt16 = 123
    static let rightArrowKeyCode: UInt16 = 124

    /// True while the focused responder edits text (a text view, a field editor or a text field).
    static func isTextEditing(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextField
    }

    /// The decision for one key press. Only a bare Left or Right arrow can flip screens, and only
    /// while no text is being edited.
    static func route(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, firstResponder: NSResponder?) -> Route {
        guard !isTextEditing(firstResponder) else { return .passThrough }
        let held = modifiers.intersection([.command, .option, .control, .shift])
        guard held.isEmpty else { return .passThrough }
        switch keyCode {
        case leftArrowKeyCode: return .previous
        case rightArrowKeyCode: return .next
        default: return .passThrough
        }
    }
}

/// Listens for the Left and Right arrows in its window and steps the screens
/// through `ReviewArrowKeys.route`. A local monitor, not a `keyboardShortcut`:
/// a shortcut takes the key before the focused text field sees it.
struct ScreenArrowKeys: NSViewRepresentable {
    let isActive: Bool
    let onStep: (Int) -> Void

    final class Coordinator {
        var monitor: Any?
        var onStep: (Int) -> Void = { _ in }
        var isActive = false
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            guard let view, let coordinator, coordinator.isActive, event.window != nil, event.window === view.window else { return event }
            let route = ReviewArrowKeys.route(
                keyCode: event.keyCode, modifiers: event.modifierFlags, firstResponder: event.window?.firstResponder)
            switch route {
            case .previous: coordinator.onStep(-1)
            case .next: coordinator.onStep(1)
            case .passThrough: return event
            }
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onStep = onStep
    }
}

/// The note popover's text field: an `NSTextView` in a scroll view. The host
/// sets its height (`NoteFieldLogic.fieldHeight`); Return adds the note,
/// Shift+Return inserts a new line and Esc cancels.
struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false

        let view = NoteNSTextView()
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.font = NoteFieldLogic.font
        view.textColor = NSColor(Theme.Colors.ink)
        view.insertionPointColor = NSColor(Theme.Colors.ink)
        view.defaultParagraphStyle = NoteFieldLogic.paragraphStyle
        view.typingAttributes = [
            .font: NoteFieldLogic.font,
            .foregroundColor: NSColor(Theme.Colors.ink),
            .paragraphStyle: NoteFieldLogic.paragraphStyle,
        ]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.string = text
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NoteNSTextView else { return }
        if view.string != text, !view.hasMarkedText() { view.string = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView
        init(_ parent: NoteTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, parent.text != view.string else { return }
            parent.text = view.string
        }
    }
}

final class NoteNSTextView: NSTextView {
    weak var coordinator: NoteTextView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The popover opens ready to type.
        Task { @MainActor [weak self] in
            guard let self, let window = self.window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        coordinator?.parent.onCancel()
    }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter.
        guard event.keyCode == 36 || event.keyCode == 76, let coordinator else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags
        switch PromptBarLogic.returnKeyAction(
            shift: flags.contains(.shift), command: flags.contains(.command), hasMarkedText: hasMarkedText(), canSend: true
        ) {
        case .send: coordinator.parent.onSubmit()
        case .newline: insertText("\n", replacementRange: selectedRange())
        case .ignore: break
        case .passThrough: super.keyDown(with: event)
        }
    }
}
