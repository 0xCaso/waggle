import SwiftUI

/// The header of a pick-several list (HAIL-123, WAG-334): "Pick up to 2 · 1 of 2", "limit reached", "Tick the
/// recommended" and "Clear". One view for a single request's dock and for an item in a step, so the list
/// has one look in every layout.
struct PickSeveralHeaderView: View {
    let count: Int
    let max: Int?
    let isAtLimit: Bool
    let canTickRecommended: Bool
    let onTickRecommended: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(MultiSelectCopy.dockLabel(count: count, max: max))
                .knockTextStyle(Theme.Typography.caption11_5w400)
                .foregroundColor(Theme.Colors.ink3)
            if isAtLimit {
                Text(MultiSelectCopy.limitReached)
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.accent)
            }
            Spacer(minLength: 8)
            if canTickRecommended {
                Button(MultiSelectCopy.tickRecommended, action: onTickRecommended)
                    .buttonStyle(.plain).pointerCursor()
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .underline()
            }
            Button(MultiSelectCopy.clear, action: onClear)
                .buttonStyle(.plain).pointerCursor()
                .knockTextStyle(Theme.Typography.caption11_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .opacity(count == 0 ? 0.5 : 1)
                .disabled(count == 0)
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 7, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
    }
}
