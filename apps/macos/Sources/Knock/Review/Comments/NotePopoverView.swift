import SwiftUI

/// The note popover a drafted pin opens (docs/design/mvp-values.md §2.13,
/// §M5 `qAwAc`): "New note on <target>", a text field, and a "↵ to add"
/// hint. ↵ saves, Shift+↵ adds a line, Esc cancels (docs/stories/KNOCK-11.md AC).
/// The field grows with the text up to 4 lines, then scrolls (HAIL-233).
struct NotePopoverView: View {
    let pinNumber: Int
    let targetLabel: String
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PinView(number: pinNumber, size: Theme.Spacing.pinSmall)
                Text("New note on \(targetLabel)")
                    .knockTextStyle(Theme.Typography.badgeLabel11w500)
                    .foregroundColor(Theme.Colors.ink3)
            }
            NoteTextView(text: $text, onSubmit: onSave, onCancel: onCancel)
                .frame(height: NoteFieldLogic.fieldHeight(text: text))
            Text("↵ to add")
                .knockTextStyle(Theme.Typography.keyHint10_5w400)
                .foregroundColor(Theme.Colors.ink3)
        }
        .notePopoverChrome()
        .onExitCommand(perform: onCancel)
    }
}

extension View {
    /// The note popover's box: padding, width, surface, border and shadow
    /// (docs/design/mvp-values.md §2.13). Shared by the new-note popover and
    /// the HAIL-75 inline comment card and hover preview.
    func notePopoverChrome(width: CGFloat = Theme.Spacing.notePopoverWidth) -> some View {
        self
            .padding(12)
            .frame(width: width)
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
    }
}
