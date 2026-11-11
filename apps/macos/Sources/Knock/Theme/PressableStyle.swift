import SwiftUI

/// The one press feel for every button (UI audit, "feel"): a 0.97 scale, 120 ms ease-out, and no scale under Reduce Motion.
enum PressFeel {
    static let scale: CGFloat = 0.97
    static let duration: Double = 0.12

    /// The scale for a press state. Reduce Motion never scales.
    static func scale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
        isPressed && !reduceMotion ? scale : 1
    }

    /// The press animation. Reduce Motion gets none.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }
}

extension View {
    /// Scales the view while pressed, with the shared values. Use inside a custom `ButtonStyle`.
    func pressFeel(isPressed: Bool) -> some View { modifier(PressFeelModifier(isPressed: isPressed)) }
}

private struct PressFeelModifier: ViewModifier {
    let isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(PressFeel.scale(isPressed: isPressed, reduceMotion: reduceMotion))
            .animation(PressFeel.animation(reduceMotion: reduceMotion), value: isPressed)
    }
}

/// A plain button with the shared press feel. Use it for filled and outlined buttons. Text links keep `.plain`.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pressFeel(isPressed: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

/// A row or tab that is a real button: a soft hover fill, the pointer cursor, no scale. Keyboard focus and the
/// accessibility button trait come from `Button` itself. The hover fill sits behind the label, so a row's own
/// selected fill stays on top.
struct HoverRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Theme.Colors.hover.opacity(isHovered || configuration.isPressed ? 1 : 0)))
                .animation(.easeOut(duration: PressFeel.duration), value: isHovered)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .pointerCursor()
        }
    }
}

extension ButtonStyle where Self == HoverRowButtonStyle {
    static var hoverRow: HoverRowButtonStyle { HoverRowButtonStyle() }
    static func hoverRow(cornerRadius: CGFloat) -> HoverRowButtonStyle { HoverRowButtonStyle(cornerRadius: cornerRadius) }
}
