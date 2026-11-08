import AppKit
import Combine
import SwiftUI

/// The motion of a 3x3 pixel grid (HAIL-66), ported from the Beautiful UI
/// loader. Opacity only. Pure: `opacity(cell:at:)` is the whole animation, so
/// tests can ask for any cell at any time.
struct PixelPattern: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case drive, dots, orbit, still }

    let kind: Kind
    /// Seconds for one pulse of one cell.
    let duration: TimeInterval
    /// Opacity of every cell of a `.still` grid.
    let stillOpacity: Double

    static let baseOpacity = 0.15
    static let peakOpacity = 1.0
    /// The centre cell of Orbit stays nearly out.
    static let orbitCentreOpacity = 0.07
    private static let orbitOrder = [0, 1, 2, 5, 8, 7, 6, 3]

    static let drive = PixelPattern(kind: .drive, duration: 0.65, stillOpacity: 0)
    static func dots(duration: TimeInterval = 0.65) -> PixelPattern {
        PixelPattern(kind: .dots, duration: duration, stillOpacity: 0)
    }
    static let orbit = PixelPattern(kind: .orbit, duration: 0.95, stillOpacity: 0)
    static func still(_ opacity: Double) -> PixelPattern {
        PixelPattern(kind: .still, duration: 0, stillOpacity: opacity)
    }

    var isAnimated: Bool { kind != .still }
    /// Dots draw round cells.
    var isRound: Bool { kind == .dots }

    /// Seconds before this cell starts pulsing. Drive and Dots: a chevron,
    /// (column + |row - 1|) x 90 ms. Orbit: 110 ms per step round the edge.
    func delay(cell: Int) -> TimeInterval {
        switch kind {
        case .drive, .dots:
            let row = cell / 3, column = cell % 3
            return Double(column + abs(row - 1)) * 0.09
        case .orbit:
            guard let step = Self.orbitOrder.firstIndex(of: cell) else { return 0 }
            return Double(step) * 0.11
        case .still:
            return 0
        }
    }

    /// Opacity of one cell (0...8, row-major) `time` seconds after the start.
    /// A nil time is the frozen dim state (Reduce Motion, window hidden).
    func opacity(cell: Int, at time: TimeInterval?) -> Double {
        if kind == .still { return stillOpacity }
        if kind == .orbit && cell == 4 { return Self.orbitCentreOpacity }
        guard let time else { return Self.baseOpacity }
        let local = time - delay(cell: cell)
        // Like a CSS animation with a delay and no fill: dim until it starts.
        guard local >= 0 else { return Self.baseOpacity }
        let phase = local.truncatingRemainder(dividingBy: duration) / duration
        // Up to the peak and back, each half eased in and out.
        let half = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        let eased = half * half * (3 - 2 * half)
        return Self.baseOpacity + (Self.peakOpacity - Self.baseOpacity) * eased
    }
}

/// Whether motion may run: some Knock window is on screen and Reduce Motion is
/// off. One observer for the whole app, so a full queue adds no per-row work.
@MainActor
final class MotionGate: ObservableObject {
    static let shared = MotionGate()

    /// A Knock window is visible (not covered, not minimised). Timers use this.
    @Published private(set) var isVisible = false
    @Published private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Grids and shimmer move only when this is true.
    var animates: Bool { isVisible && !reduceMotion }

    /// Evidence hook: a capture run cannot always keep a window uncovered.
    /// Never set in a real install.
    private static let alwaysVisible = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_MOTION_ALWAYS_ACTIVE"] == "1"

    private init() {
        let center = NotificationCenter.default
        for name in [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification, NSApplication.didHideNotification,
            NSApplication.didUnhideNotification, NSApplication.didFinishLaunchingNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduce != reduceMotion { reduceMotion = reduce }
        let visible = Self.alwaysVisible || (!NSApp.isHidden && NSApp.windows.contains {
            $0.canBecomeKey && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        })
        if visible != isVisible { isVisible = visible }
    }
}

/// A 3x3 grid of cells (HAIL-66). `cell` is the cell size in points; the gap is
/// 0.375 x cell and the radius cell / 4 (round for Dots). The nine cells are
/// Core Animation layers whose opacity pulses run in the render server, on one
/// shared clock (every animation begins at `PixelClock.epoch`), so a full queue
/// costs the app nothing per frame. A still pattern, Reduce Motion and a hidden
/// window hold the dim frame and run no animation.
struct PixelStatusGrid: NSViewRepresentable {
    let pattern: PixelPattern
    let color: Color
    let cell: CGFloat

    nonisolated static func side(cell: CGFloat) -> CGFloat { cell * 3 + cell * 0.375 * 2 }

    func makeNSView(context: Context) -> PixelGridNSView { PixelGridNSView() }

    func updateNSView(_ view: PixelGridNSView, context: Context) {
        view.configure(pattern: pattern, color: NSColor(color), cell: cell)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PixelGridNSView, context: Context) -> CGSize? {
        let side = Self.side(cell: cell)
        return CGSize(width: side, height: side)
    }
}

/// The one time origin of every pulse. CoreAnimation keeps an animation with a
/// begin time in the past on the same phase, so grids created at different
/// moments still pulse together.
enum PixelClock {
    static let epoch: CFTimeInterval = CACurrentMediaTime()
}

@MainActor
final class PixelGridNSView: NSView {
    private var cells: [CALayer] = []
    private var pattern = PixelPattern.still(0)
    private var color = NSColor.black
    private var cell: CGFloat = 4
    private var subscription: AnyCancellable?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for _ in 0..<9 {
            let cellLayer = CALayer()
            layer?.addSublayer(cellLayer)
            cells.append(cellLayer)
        }
        setAccessibilityElement(false)
        subscription = MotionGate.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyMotion() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The grid never takes clicks: the row or button under it does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(pattern: PixelPattern, color: NSColor, cell: CGFloat) {
        let changed = pattern != self.pattern || color != self.color || cell != self.cell
        guard changed else { return }
        self.pattern = pattern
        self.color = color
        self.cell = cell
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let gap = cell * 0.375
        let side = PixelStatusGrid.side(cell: cell)
        for (index, layer) in cells.enumerated() {
            let row = CGFloat(index / 3), column = CGFloat(index % 3)
            layer.frame = CGRect(
                x: column * (cell + gap), y: side - (row + 1) * cell - row * gap, width: cell, height: cell)
            layer.cornerRadius = pattern.isRound ? cell / 2 : cell / 4
            layer.backgroundColor = color.cgColor
        }
        CATransaction.commit()
        applyMotion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMotion()
    }

    /// Holds the dim (or still) frame, then adds the pulses when motion is allowed.
    private func applyMotion() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in cells.enumerated() {
            layer.removeAllAnimations()
            layer.opacity = Float(pattern.opacity(cell: index, at: nil))
        }
        CATransaction.commit()
        guard pattern.isAnimated, window != nil, MotionGate.shared.animates else { return }
        for (index, layer) in cells.enumerated() where !(pattern.kind == .orbit && index == 4) {
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [PixelPattern.baseOpacity, PixelPattern.peakOpacity, PixelPattern.baseOpacity]
            pulse.keyTimes = [0, 0.5, 1]
            pulse.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            pulse.duration = pattern.duration
            pulse.repeatCount = .infinity
            pulse.beginTime = layer.convertTime(PixelClock.epoch, from: nil) + pattern.delay(cell: index)
            layer.add(pulse, forKey: "pulse")
        }
    }
}
