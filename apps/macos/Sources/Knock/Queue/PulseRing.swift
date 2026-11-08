import AppKit
import SwiftUI

/// WAG-365: the ring that grows and fades round a working dot. Core Animation runs it on its own layer, so SwiftUI
/// does no work and no layout on each frame. A `repeatForever` SwiftUI animation re-ran the graph for every frame.
/// The caller shows it only when the dot is working and Reduce Motion is off. It runs while it is in a window.
struct PulseRing: NSViewRepresentable {
    let color: Color
    let lineWidth: CGFloat
    let opacity: CGFloat
    let scale: CGFloat

    func makeNSView(context: Context) -> PulseRingView { PulseRingView() }

    func updateNSView(_ view: PulseRingView, context: Context) {
        view.configure(color: NSColor(color), lineWidth: lineWidth, opacity: opacity, scale: scale)
    }
}

final class PulseRingView: NSView {
    static let animationKey = "waggle.pulse"
    private let ring = CAShapeLayer()
    private var opacity: CGFloat = 0.8
    private var scale: CGFloat = 2.4
    /// How many times the animation was added. Tests read it.
    private(set) var animationStarts = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(ring)
        ring.fillColor = nil
        ring.opacity = 0
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    var isPulsing: Bool { ring.animation(forKey: Self.animationKey) != nil }

    func configure(color: NSColor, lineWidth: CGFloat, opacity: CGFloat, scale: CGFloat) {
        effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = color.cgColor }
        ring.lineWidth = lineWidth
        if self.opacity != opacity || self.scale != scale {
            self.opacity = opacity
            self.scale = scale
            stop()
        }
        startIfNeeded()
    }

    override func layout() {
        super.layout()
        // The ring is a circle in the view, scaled from its centre.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.bounds = bounds
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.path = CGPath(ellipseIn: bounds, transform: nil)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { startIfNeeded() }
    }

    private func startIfNeeded() {
        guard window != nil, !isPulsing else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = scale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.4
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        ring.add(group, forKey: Self.animationKey)
        animationStarts += 1
    }

    private func stop() { ring.removeAnimation(forKey: Self.animationKey) }
}
