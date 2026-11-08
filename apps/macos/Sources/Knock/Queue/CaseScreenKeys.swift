import AppKit
import SwiftUI

/// WAG-340: ← and → flip the screenshots set in the artifact box of the case page without a click in the
/// box first. Pure rules, so they are unit-tested without a window.
enum CaseScreenKeys {
    /// The arrow goes to the box only when nothing else owns it: no text field has focus, full size and
    /// sheets are closed, and the set on show has screens to flip.
    static func flips(
        isFlippable: Bool, allowsScreenKeys: Bool, textInputFocused: Bool, fullSizeOpen: Bool, sheetOpen: Bool
    ) -> Bool {
        isFlippable && allowsScreenKeys && !textInputFocused && !fullSizeOpen && !sheetOpen
    }

    /// -1 for ←, 1 for →, nil for any other key or a key with a modifier.
    static func delta(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty else { return nil }
        switch keyCode {
        case 123: return -1
        case 124: return 1
        default: return nil
        }
    }
}

/// Watches ← and → for one window. `step` runs at the key press and returns true when it used the key;
/// otherwise the key goes on untouched.
struct CaseScreenKeyCatcher: NSViewRepresentable {
    let step: (Int, NSWindow?) -> Bool

    func makeNSView(context: Context) -> NSView { context.coordinator.view }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.step = step }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator {
        let view = NSView()
        var step: (Int, NSWindow?) -> Bool = { _, _ in false }
        private var monitor: Any?

        init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let delta = CaseScreenKeys.delta(keyCode: event.keyCode, modifiers: event.modifierFlags),
                  let window = view.window, event.window === window, window.isKeyWindow else { return false }
            return step(delta, window)
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
