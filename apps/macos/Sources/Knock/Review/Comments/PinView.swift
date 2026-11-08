import SwiftUI

/// A numbered pin (docs/design/mvp-values.md §2.11, §M5 `t3SUea`/`LR475`
/// stage/list size, `YvVkm` popover-head size): a circle, always `accent`
/// filled, with a white bold number.
struct PinView: View {
    let number: Int
    var size: CGFloat = Theme.Spacing.pinLarge
    /// HAIL-75: the highlighted pin gets an accent ring around it.
    var isSelected: Bool = false

    var body: some View {
        Circle()
            .fill(Theme.Colors.accent)
            .frame(width: size, height: size)
            .overlay(
                Text("\(number)")
                    .knockTextStyle(size >= Theme.Spacing.pinLarge ? Theme.Typography.pinNumber11w700 : Theme.Typography.pinNumber9_5w700)
                    .foregroundColor(Theme.Colors.win)
            )
            .background(
                Circle()
                    .stroke(Theme.Colors.accent, lineWidth: 2)
                    .frame(width: size + 9, height: size + 9)
                    .opacity(isSelected ? 1 : 0)
            )
    }
}
