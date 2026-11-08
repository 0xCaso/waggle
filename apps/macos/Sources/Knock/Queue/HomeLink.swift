import AppKit
import SwiftUI

/// The "← Home" link and its Esc key (HAIL-119). A case that is not in Needs you (answered, waiting,
/// closed) can be opened from the home screen; the pane header then offers a way back. Pure rules,
/// so they are unit-tested without a window.
enum HomeLink {
    /// Shown for a case that is not in Needs you. A Needs you ask has no "Home": it is the work.
    static func isVisible(caseId: String, needsYou: [Case]) -> Bool {
        !needsYou.contains { $0.id == caseId }
    }

    /// Esc goes home only when nothing else owns the key: no text field or editor has focus, no
    /// unsent work (a note, a detail, a comment, a Change answer edit), no dialog is open, and the
    /// both-sides fold (which also uses Esc) is off.
    static func escapeGoesHome(
        isVisible: Bool, textInputFocused: Bool, holdsUnsentWork: Bool, dialogOpen: Bool, isBothFolded: Bool
    ) -> Bool {
        isVisible && !textInputFocused && !holdsUnsentWork && !dialogOpen && !isBothFolded
    }

    /// True while a text field, a text editor or a web view (a page with fields) has the keyboard.
    static func textInputHasFocus(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSText || responder is NSTextInputClient
    }
}

/// The header's "← Home  esc" (reference `.homebar`).
struct HomeLinkButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left").font(.system(size: 11, weight: .medium))
                Text("Home").knockTextStyle(Theme.Typography.body13w400)
            }
            .foregroundColor(Theme.Colors.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityLabel("Back to home")
        Text("esc")
            .knockTextStyle(Theme.Typography.sessionsMono10_5)
            .foregroundColor(Theme.Colors.ink3)
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.Colors.line2, lineWidth: 1))
    }
}

/// Watches Esc for one window. `shouldHandle` runs at the key press, so it reads live state; when it
/// says no, the key goes on untouched to whatever owned it before.
struct EscapeKeyCatcher: NSViewRepresentable {
    let shouldHandle: (NSWindow?) -> Bool
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView { context.coordinator.view }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldHandle = shouldHandle
        context.coordinator.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator {
        let view = NSView()
        var shouldHandle: (NSWindow?) -> Bool = { _ in false }
        var onEscape: () -> Void = {}
        private var monitor: Any?

        init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  let window = view.window, event.window === window, shouldHandle(window) else { return false }
            onEscape()
            return true
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
