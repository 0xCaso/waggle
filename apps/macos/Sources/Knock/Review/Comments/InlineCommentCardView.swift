import SwiftUI

/// HAIL-75: the inline card a saved pin opens on the artifact. Same box as the
/// new-note popover (`notePopoverChrome`), with the comment text editable in
/// place. Return saves, Shift+Return adds a line (the composer rule), Esc
/// closes without keeping an unsaved edit. "Delete" removes the comment.
struct InlineCommentCardView: View {
    let number: Int
    /// "Note on <label>": a region by default, a part of a request (WAG-357) otherwise.
    var label = "region"
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(number: Int, label: String = "region", text: String, onSave: @escaping (String) -> Void, onDelete: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.number = number
        self.label = label
        self.onSave = onSave
        self.onDelete = onDelete
        self.onClose = onClose
        _text = State(initialValue: text)
    }

    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PinView(number: number, size: Theme.Spacing.pinSmall)
                Text("Note on \(label)")
                    .knockTextStyle(Theme.Typography.badgeLabel11w500)
                    .foregroundColor(Theme.Colors.ink3)
            }
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink)
                .focused($isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        text += "\n"
                    } else {
                        save()
                    }
                    return .handled
                }
            HStack {
                Button("Delete", action: onDelete)
                    .buttonStyle(.plain).pointerCursor()
                    .knockTextStyle(Theme.Typography.badgeLabel11w500)
                    .foregroundColor(Theme.Colors.ink3)
                Spacer(minLength: 0)
                Text("↵ to save")
                    .knockTextStyle(Theme.Typography.keyHint10_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                Button("Save", action: save)
                    .buttonStyle(.plain).pointerCursor()
                    .knockTextStyle(Theme.Typography.badgeLabel11w500)
                    .foregroundColor(canSave ? Theme.Colors.accent : Theme.Colors.ink3)
                    .disabled(!canSave)
            }
        }
        .notePopoverChrome()
        .onExitCommand(perform: onClose)
        .onAppear { isFocused = true }
    }

    private func save() {
        guard canSave else { return }
        onSave(text)
    }
}

/// HAIL-75: the small read-only preview shown beside a hovered pin.
struct CommentHoverPreviewView: View {
    let text: String

    var body: some View {
        Text(text)
            .knockTextStyle(Theme.Typography.body12_5w400)
            .foregroundColor(Theme.Colors.ink)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .notePopoverChrome()
            .allowsHitTesting(false)
    }
}
