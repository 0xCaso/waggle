import SwiftUI

/// The header of a pick-several list (HAIL-123, WAG-334), in the look of the list label (mockup `.ol`, template
/// `multi`): "PICK UP TO 4" and "limit reached" on the left, "Tick the recommended" and "Clear" on the
/// right as plain underlined links. One view for a single request and for an item in a step, so the list has one
/// look in every layout.
struct PickSeveralHeaderView: View {
    let count: Int
    let max: Int?
    let isAtLimit: Bool
    let canTickRecommended: Bool
    let onTickRecommended: () -> Void
    let onClear: () -> Void

    var body: some View {
        // CSS flex items stretch and their text sits at the top of the row.
        HStack(alignment: .top, spacing: 8) {
            OptionListLabel(text: MultiSelectCopy.listLabel(max: max))
                // The count shows in the answer area ("2 picked", "Send 2 of 4"); VoiceOver reads it here too.
                .accessibilityLabel(MultiSelectCopy.dockLabel(count: count, max: max))
            if isAtLimit {
                OptionListLabel(text: MultiSelectCopy.limitReached, color: Theme.Colors.accent)
            }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                if canTickRecommended { link(MultiSelectCopy.tickRecommended, action: onTickRecommended) }
                link(MultiSelectCopy.clear, action: onClear)
                    .opacity(count == 0 ? 0.5 : 1)
                    .disabled(count == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `.ol u`: Inter Tight 500 12 `ink3`, underlined, no upper case. Line height 1, as the label's.
    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .knockTextStyle(OptionCardStyle.labelLink)
                .foregroundColor(Theme.Colors.ink3)
                .underline()
                .lineLimit(1)
                .cssLine(size: 12, lineHeight: 1)
        }
        .buttonStyle(.plain).pointerCursor()
    }
}
