import AppKit
import SwiftUI

/// HAIL-180: where the queue header's lockup sits. Operator, 5 Oct: at the left edge, in line
/// with the section labels ("Waiting on agent"), on its own row under the traffic lights. With the
/// traffic lights shown the row starts below them; without them (full screen) it keeps the old top.
enum QueueHeaderLayout {
    /// The list's text inset (the section labels, rows and the header's trailing edge).
    static let textInset: CGFloat = 18
    /// The header's top inset when nothing sits above it (full screen).
    static let topWithoutTrafficLights: CGFloat = 16
    /// The header's top inset under the traffic lights: clear of the standard 28 pt title bar row.
    static let topUnderTrafficLights: CGFloat = 30
    /// The right edge of the standard traffic lights, used until the window reports the real one.
    static let defaultTrafficLightsMaxX: CGFloat = 68

    static func leadingInset(trafficLightsMaxX: CGFloat?) -> CGFloat { textInset }

    static func topInset(trafficLightsMaxX: CGFloat?) -> CGFloat {
        trafficLightsMaxX == nil ? topWithoutTrafficLights : topUnderTrafficLights
    }
}

/// Reports the right edge of the window's traffic lights (nil when they are hidden, as in full
/// screen) and updates when the window enters or leaves full screen.
struct TrafficLightsEdgeReader: NSViewRepresentable {
    let onChange: (CGFloat?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }

    final class ReaderView: NSView {
        var onChange: ((CGFloat?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            report()
        }

        @objc private func windowChanged(_ note: Notification) { report() }

        private func report() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let button = window.standardWindowButton(.zoomButton)
                let hidden = window.styleMask.contains(.fullScreen) || button == nil || button?.isHidden == true
                let edge = hidden ? nil : button.map { $0.convert($0.bounds, to: nil).maxX }
                self.onChange?(edge)
            }
        }
    }
}
