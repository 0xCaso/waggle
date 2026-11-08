import AppKit
import SwiftUI

/// The tooltip window of an option row (WAG-379). It is the native popover that `.popover` makes, with one
/// difference: its behaviour is `applicationDefined`, so it never closes itself on a click outside.
///
/// A `.popover` is transient. A click while it is open (the pointer rested on the row for 0.4 s) only closes the
/// popover: the press never reaches the row, and the person has to click again. The row closes this popover
/// itself, on the press, on leaving the row, on lost focus and when it goes away.
struct OptionTipPresenter<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    /// The window lost its key state or the app went to the background: the tip has to go, as a transient popover would.
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.update(isPresented: isPresented, anchor: view, content: AnyView(content()))
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.update(isPresented: false, anchor: view, content: nil)
    }

    /// Fills the row and lets every click through.
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        private(set) var popover: NSPopover?
        private var observers: [NSObjectProtocol] = []
        var onDismiss: () -> Void = {}

        func update(isPresented: Bool, anchor: AnchorView, content: AnyView?) {
            guard isPresented, let content, anchor.window != nil else {
                close()
                return
            }
            if let popover, popover.isShown {
                (popover.contentViewController as? NSHostingController<AnyView>)?.rootView = content
                return
            }
            let controller = NSHostingController(rootView: content)
            controller.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.contentViewController = controller
            self.popover = popover
            watch(window: anchor.window)
            // `.minY` is below the row, as the arrow at the top of a `.popover` was. AppKit flips it when there is no room.
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }

        func close() {
            popover?.close()
            popover = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        private func watch(window: NSWindow?) {
            let center = NotificationCenter.default
            let leave: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.onDismiss() }
            }
            observers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: leave),
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: leave),
            ]
        }
    }
}
