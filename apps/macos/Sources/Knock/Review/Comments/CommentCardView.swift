import SwiftUI

/// One saved comment in the comments column (docs/design/mvp-values.md §M5
/// `uyrRs` → `OGZrm`): pin, note text, and a meta row. The design's meta row
/// shows a semantic region label ("annual toggle · region") that only makes
/// sense for the mock's own sample artifact; a real artifact has no such
/// label available, so this shows the generic "region" the story's DATA
/// SHOWN list asks for, plus edit/delete on hover (docs/stories/KNOCK-11.md
/// AC: "Pins and notes can be edited and deleted before sending" — not
/// pictured in the frozen mock, since it only shows one moment in time).
struct CommentCardView: View {
    let comment: Comment
    /// HAIL-75: the highlighted card (its pin is highlighted on the artifact).
    var isSelected: Bool = false
    /// Meta prefix such as "Screen 2" for a screenshot set; `nil` otherwise.
    var locationLabel: String? = nil
    /// WAG-280: what the pin points at on the live page ("On the button "Pay now"", or "No page element").
    var elementLabel: String? = nil
    /// WAG-307: the anchor line of the shared list ("On the span", "Capture 2 · region"). Replaces
    /// the plain meta word when set.
    var anchorLabel: String? = nil
    /// WAG-307: a comment on a state that is not on screen offers Show; `notice` is the one plain
    /// line Show leaves when it could not find the part.
    var onShow: (() -> Void)? = nil
    var notice: String? = nil
    var onSelect: () -> Void = {}
    var onEditingChanged: (Bool) -> Void = { _ in }
    let onEditText: (String) -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var draftText = ""
    @State private var isHovering = false
    @FocusState private var editFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PinView(number: comment.n, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 4) {
                if let anchor = comment.anchor {
                    quoteLine(anchor.quote)
                } else if let ask = comment.askAnchor {
                    quoteLine(ask.quote)
                }
                if isEditing {
                    TextField("", text: $draftText)
                        .textFieldStyle(.plain)
                        .knockTextStyle(Theme.Typography.body13w400)
                        .foregroundColor(Theme.Colors.ink)
                        .focused($editFocused)
                        .onSubmit(save)
                        .onExitCommand(perform: cancelEdit)
                        .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                        .background(Theme.Colors.win)
                        .cornerRadius(Theme.Radius.chip)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .stroke(Theme.Colors.accent, lineWidth: Theme.Stroke.hairline.width)
                        )
                } else {
                    Text(comment.text)
                        .knockTextStyle(Theme.Typography.body13w400)
                        .foregroundColor(Theme.Colors.ink)
                }
                if let elementLabel {
                    Text(elementLabel)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink2)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let notice {
                    Text(notice)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                metaRow
            }
        }
        .padding(12)
        .background(isSelected ? Theme.Colors.accentSoft : Theme.Colors.list)
        .cornerRadius(Theme.Radius.commentCard)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.commentCard)
                .stroke(
                    isSelected ? Theme.Colors.accent : Theme.Stroke.hairline.color,
                    lineWidth: isSelected ? Theme.Stroke.regionBox.width : Theme.Stroke.hairline.width
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.commentCard))
        .onTapGesture(perform: onSelect).pointerCursor()
        .onHover { isHovering = $0 }
        .onAppear {
            // `KNOCK_EVIDENCE_EDIT_COMMENT=<text>` (HAIL-65 evidence hook):
            // opens the card with exactly this text in edit mode, as no click
            // can reach it in evidence.
            if ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_EDIT_COMMENT"] == comment.text { beginEdit() }
        }
    }

    /// The quoted source text a text comment is on (HAIL-150), cut to two lines.
    private func quoteLine(_ quote: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.Colors.accent).frame(width: 2)
            Text(quote)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink2)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Text(anchorLabel ?? (comment.isAsk ? (comment.askAnchor?.part.onWords ?? "request") : comment.isText ? "text" : (locationLabel.map { "\($0) · region" } ?? "region")))
                .knockTextStyle(Theme.Typography.monoMeta11w400)
                .foregroundColor(Theme.Colors.ink3)
            Spacer(minLength: 0)
            if let onShow, !isEditing {
                Button(action: onShow) {
                    Text("Show")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                        .foregroundColor(Theme.Colors.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .accessibilityLabel("Show comment \(comment.n)")
            }
            if isHovering && !isEditing {
                Button(action: beginEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Colors.ink3)
                }
                .buttonStyle(.plain).pointerCursor()
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Colors.ink3)
                }
                .buttonStyle(.plain).pointerCursor()
            } else {
                Text("saved")
                    .knockTextStyle(Theme.Typography.badgeLabel11w500)
                    .foregroundColor(Theme.Colors.ink3)
            }
        }
    }

    private func beginEdit() {
        draftText = comment.text
        isEditing = true
        editFocused = true
        onEditingChanged(true)
    }

    private func save() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onEditText(trimmed)
        isEditing = false
        onEditingChanged(false)
    }

    private func cancelEdit() {
        isEditing = false
        onEditingChanged(false)
    }
}

/// A pin still being drafted, shown in the comments column while its note
/// popover is open on the stage (docs/design/mvp-values.md §M5 `uyrRs` →
/// `O8Tw6`): same card shape, `accent`-stroked, with a "typing…" status
/// instead of the meta row.
struct DraftingCommentCardView: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PinView(number: number)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .knockTextStyle(Theme.Typography.body13w400)
                    .foregroundColor(Theme.Colors.ink)
                Text("typing…  ↵ to add")
                    .knockTextStyle(Theme.Typography.statusCaption11w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
        }
        .padding(12)
        .background(Theme.Colors.win)
        .cornerRadius(Theme.Radius.commentCard)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.commentCard)
                .stroke(Theme.Colors.accent, lineWidth: Theme.Stroke.regionBox.width)
        )
    }
}
