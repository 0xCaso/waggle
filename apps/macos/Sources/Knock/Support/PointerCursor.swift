import AppKit
import SwiftUI

/// Pointing-hand cursor for anything the person can click (HAIL-221). One modifier, so every
/// clickable view says the same thing. Text fields do not use it: they keep the I-beam.
extension View {
    /// Shows the pointing hand while the pointer is over this view. Does nothing while the
    /// view is disabled.
    func pointerCursor() -> some View {
        modifier(PointerCursorModifier())
    }
}

/// Keeps push and pop of `NSCursor` balanced for the macOS 14 fallback. A pop without a push
/// (or a second push) would leave the wrong cursor on the stack.
struct PointerCursorTracker {
    private(set) var isPushed = false

    /// What the caller must do with the cursor stack for this hover change.
    enum Action: Equatable { case push, pop, none }

    mutating func hoverChanged(inside: Bool, enabled: Bool) -> Action {
        switch (inside && enabled, isPushed) {
        case (true, false): isPushed = true; return .push
        case (false, true): isPushed = false; return .pop
        default: return .none
        }
    }
}

private struct PointerCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(isEnabled ? .link : nil)
        } else {
            content.modifier(LegacyPointerCursorModifier(enabled: isEnabled))
        }
    }
}

private struct LegacyPointerCursorModifier: ViewModifier {
    let enabled: Bool
    @State private var tracker = PointerCursorTracker()
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                inside = hovering
                apply(tracker.hoverChanged(inside: hovering, enabled: enabled))
            }
            .onChange(of: enabled) { _, now in
                apply(tracker.hoverChanged(inside: inside, enabled: now))
            }
            .onDisappear {
                inside = false
                apply(tracker.hoverChanged(inside: false, enabled: enabled))
            }
    }

    private func apply(_ action: PointerCursorTracker.Action) {
        switch action {
        case .push: NSCursor.pointingHand.push()
        case .pop: NSCursor.pop()
        case .none: break
        }
    }
}
