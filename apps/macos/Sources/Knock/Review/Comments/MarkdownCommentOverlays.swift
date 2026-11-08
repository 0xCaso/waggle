import SwiftUI

/// HAIL-150: the small "Comment" button that follows a text selection in a markdown explanation.
/// A white pill with the app's hairline border and note-popover shadow, and the `C` shortcut as a hint.
/// WAG-384: with `onExplain` it sits beside an "Explain" button (key `E`), Comment first, 6 pt apart.
struct MarkdownCommentButton: View {
    let onTap: () -> Void
    var onExplain: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            SelectionActionButton(symbol: "text.bubble", iconColor: Theme.Colors.accent, label: "Comment", hint: "C", action: onTap)
            if let onExplain {
                SelectionActionButton(
                    symbol: "questionmark.circle", iconColor: Theme.Colors.ink, label: "Explain", hint: "E",
                    help: "Ask how this works  E", action: onExplain)
            }
        }
        .fixedSize()
        .padding(EdgeInsets(top: 4, leading: 4, bottom: 18, trailing: 18))
    }
}

/// One button of the selection row: icon, label and the key hint, in the note-popover box.
private struct SelectionActionButton: View {
    let symbol: String
    let iconColor: Color
    let label: String
    let hint: String
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(iconColor)
                Text(label)
                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    .foregroundColor(Theme.Colors.ink)
                Text(hint)
                    .knockTextStyle(Theme.Typography.keyHint10_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .padding(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                    .background(Theme.Colors.side)
                    .cornerRadius(Theme.Radius.chip)
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 8))
            .background(Theme.Colors.win)
            .cornerRadius(Theme.Radius.notePopover)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.notePopover)
                    .stroke(Theme.Stroke.notePopover.color, lineWidth: Theme.Stroke.notePopover.width)
            )
            .shadow(
                color: Theme.Shadow.notePopover.color,
                radius: Theme.Shadow.notePopover.blur / 2,
                x: Theme.Shadow.notePopover.offset.width,
                y: Theme.Shadow.notePopover.offset.height
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(help ?? "")
    }
}

/// WAG-384: the "Explain" request for a text selection, and the hook that sends it. The case pane and the
/// review workspace set the hook; it is `nil` where a selection cannot send a request.
enum ExplainRequest {
    static let maxQuote = 300

    /// `Explain how this works: "<selected text>"`, the quote cut at 300 characters with "…".
    static func text(forSelection selection: String) -> String {
        let quote = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = quote.count > maxQuote ? String(quote.prefix(maxQuote)) + "…" : quote
        return "Explain how this works: \"\(cut)\""
    }
}

private struct ExplainSelectionKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    /// Sends the "Explain" request for the selected text. `nil` where the Explain button does not show.
    var explainSelection: ((String) -> Void)? {
        get { self[ExplainSelectionKey.self] }
        set { self[ExplainSelectionKey.self] = newValue }
    }
}

/// HAIL-150: the new-note popover for a text selection. The same box as a pin's note popover
/// (`NotePopoverView`); Enter saves, Escape cancels. An empty note saves nothing.
struct MarkdownDraftNoteView: View {
    let number: Int
    /// "New note on <label>": the selection, or the part of a request (WAG-357).
    var targetLabel = "selection"
    @State var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    /// Called after the text changes, so the host can re-fit the popover as it grows (HAIL-233).
    var onResize: () -> Void = {}

    var body: some View {
        NotePopoverView(
            pinNumber: number,
            targetLabel: targetLabel,
            text: $text,
            onSave: { onSave(text) },
            onCancel: onCancel
        )
        .padding(EdgeInsets(top: 4, leading: 4, bottom: 18, trailing: 18))
        .onChange(of: text) { _, _ in onResize() }
    }
}

/// HAIL-150: the read-only note shown beside a hovered highlight.
struct MarkdownHoverNoteView: View {
    let text: String

    var body: some View {
        CommentHoverPreviewView(text: text)
            .padding(EdgeInsets(top: 4, leading: 4, bottom: 18, trailing: 18))
    }
}
