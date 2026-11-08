import AppKit
import SwiftUI

/// WAG-375: while the layout log is on, notes each change of the window's frame and of its minimum content size.
/// SwiftUI sets that minimum from the size of the whole page at a proposed size of 0, and the sample of issue 9 shows
/// it computed again on every turn of the run loop. A minimum that moves between two values on each turn would explain
/// that; a log line `window.minSize` with its old and new value says so. Off, the probe is not in the view tree.
struct LayoutLogWindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        private var minSizeObservation: NSKeyValueObservation?
        private var frameObservation: NSKeyValueObservation?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            minSizeObservation = nil
            frameObservation = nil
            guard let window else { return }
            // Evidence only: `KNOCK_EVIDENCE_WINDOW_WIDTH=<points>` sets the window width once, with the layout log on.
            if let text = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_WINDOW_WIDTH"], let width = Double(text) {
                DispatchQueue.main.async { window.setContentSize(NSSize(width: width, height: window.contentView?.frame.height ?? 800)) }
            }
            minSizeObservation = window.observe(\.contentMinSize, options: [.old, .new]) { _, change in
                EvidenceLayoutLog.event("window.minSize", "old=\(String(describing: change.oldValue)) new=\(String(describing: change.newValue))")
            }
            frameObservation = window.observe(\.frame, options: [.old, .new]) { _, change in
                guard change.oldValue?.size != change.newValue?.size else { return }
                EvidenceLayoutLog.event("window.size", "old=\(String(describing: change.oldValue?.size)) new=\(String(describing: change.newValue?.size))")
            }
        }

        override func layout() {
            super.layout()
            EvidenceLayoutLog.bump("probe.layout")
        }
    }
}

extension View {
    /// Adds the probe behind the view while the layout log is on.
    @ViewBuilder
    func layoutLogWindowProbe() -> some View {
        if EvidenceLayoutLog.enabled { background(LayoutLogWindowProbe()) } else { self }
    }
}

/// WAG-379: while the layout log is on, notes each turn of the main run loop that takes longer than 25 ms
/// (`main.long`, with its length and the end time), so a click that waits for a slow turn shows in the log.
@MainActor
enum RunLoopTurnProbe {
    private static var started = false
    nonisolated(unsafe) private static var turnStart: CFAbsoluteTime = 0
    /// Set by the first body pass that draws a selected row: the next end of a turn is when the frame is committed.
    nonisolated(unsafe) static var wantsDrawn = false

    static func startIfLogging() {
        guard EvidenceLayoutLog.enabled, !started else { return }
        started = true
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.afterWaiting, .beforeWaiting]).rawValue, true, 2_000_001) { _, activity in
            let uptime = ProcessInfo.processInfo.systemUptime * 1000
            if activity == .afterWaiting { turnStart = uptime; return }
            let length = uptime - turnStart
            if turnStart > 0, length > 25 {
                EvidenceLayoutLog.event("main.long", "len=\(String(format: "%.0f", length)) end=\(String(format: "%.1f", uptime))")
            }
            if wantsDrawn { wantsDrawn = false; EvidenceLayoutLog.event("opt.drawn", "end=\(String(format: "%.1f", uptime))") }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
