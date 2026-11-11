import SwiftUI

/// Publishes one real view's frame under a `CoachMarkTourModel.Mark` key, so a single overlay elsewhere in
/// the tree can float a bubble beside it without either view needing a reference to the other.
struct CoachMarkAnchorKey: PreferenceKey {
    static let defaultValue: [CoachMarkTourModel.Mark: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [CoachMarkTourModel.Mark: Anchor<CGRect>],
        nextValue: () -> [CoachMarkTourModel.Mark: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as the target of `mark`. Adds no styling of its own: a plain `anchorPreference` publish.
    func coachMarkAnchor(_ mark: CoachMarkTourModel.Mark) -> some View {
        anchorPreference(key: CoachMarkAnchorKey.self, value: .bounds) { [mark: $0] }
    }
}

/// The tour itself (WAG-338): the window dims, the real view of the mark shows through a honey ring, and one
/// dark bubble sits beside it. Rendered from `MainWindowView` over the ask, gated on the tour being active
/// for the case on screen. The dim never blocks a click: the person can use the real view while the mark shows.
struct CoachMarkOverlayView: View {
    @ObservedObject var tour: CoachMarkTourModel
    let anchors: [CoachMarkTourModel.Mark: Anchor<CGRect>]
    /// The width of the queue column at the left edge of the window; 0 when it is folded (WAG-343).
    var queueWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let bubbleWidth: CGFloat = 270
    static let bubbleHeight: CGFloat = 150

    var body: some View {
        GeometryReader { proxy in
            if let mark = tour.currentMark, let anchor = anchors[mark] {
                let rect = proxy[anchor]
                let avoid = [CoachMarkTourModel.Mark.round, .options].filter { $0 != mark }.compactMap { anchors[$0].map { proxy[$0] } }
                let placed = Self.placement(
                    target: rect, avoid: avoid, container: proxy.size,
                    queue: queueWidth > 0 ? CGRect(x: 0, y: 0, width: queueWidth, height: proxy.size.height) : nil,
                    size: CGSize(width: Self.bubbleWidth, height: Self.bubbleHeight))
                ZStack(alignment: .topLeading) {
                    CoachMarkScrim(hole: rect, radius: 12)
                        .fill(Theme.Colors.ink.opacity(0.28), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.Colors.honey500, lineWidth: 4)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                    CoachMarkBubble(mark: mark, onSkip: tour.skip, onNext: tour.next)
                        .frame(width: Self.bubbleWidth, alignment: .topLeading)
                        .background(alignment: .topLeading) {
                            CoachMarkPointer(side: placed.side, target: rect, origin: placed.origin)
                                .fill(Theme.Colors.ink)
                        }
                        .offset(x: placed.origin.x, y: placed.origin.y)
                }
                .transition(reduceMotion ? .identity : .opacity)
                .id(mark)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: tour.currentMark)
    }

    /// Where the bubble sits, and which side of the target it is on (the pointer faces the target).
    struct Placement: Equatable {
        enum Side: Equatable { case below, above, right, left, inside }
        var origin: CGPoint
        var side: Side
    }

    static let margin: CGFloat = 12
    static let gap: CGFloat = 14

    /// Tries below the target, then above, then right, then left. A try wins when the bubble stays inside the
    /// container (12 pt margin) and touches neither the target nor any `avoid` rect (the request title, the
    /// composer). Along the other axis the bubble lines up with the target and is clamped into the window.
    /// When no side is clear, the side with the least overlap wins.
    /// WAG-343: the queue column is the last choice. A side that would sit over it is skipped; the bubble
    /// goes inside the target's top left corner (the case pane) before it covers the person's queue row.
    static func placement(
        target: CGRect, avoid: [CGRect], container: CGSize, queue: CGRect? = nil, size: CGSize
    ) -> Placement {
        let blocked = [target] + avoid + (queue.map { [$0] } ?? [])
        let maxX = max(margin, container.width - size.width - margin)
        let maxY = max(margin, container.height - size.height - margin)
        func clampX(_ x: CGFloat) -> CGFloat { max(margin, min(x, maxX)) }
        func clampY(_ y: CGFloat) -> CGFloat { max(margin, min(y, maxY)) }
        let tries: [(Placement.Side, CGPoint, Bool)] = [
            (.below, CGPoint(x: clampX(target.minX), y: target.maxY + gap), target.maxY + gap <= maxY),
            (.above, CGPoint(x: clampX(target.minX), y: target.minY - gap - size.height), target.minY - gap - size.height >= margin),
            (.right, CGPoint(x: target.maxX + gap, y: clampY(target.minY)), target.maxX + gap <= maxX),
            (.left, CGPoint(x: target.minX - gap - size.width, y: clampY(target.minY)), target.minX - gap - size.width >= margin),
        ]
        func overQueue(_ origin: CGPoint) -> Bool {
            guard let queue else { return false }
            return CGRect(origin: origin, size: size).intersects(queue)
        }
        // Inside the target, pointing at nothing outside it: only when the target is big enough to hold it.
        let inside = CGPoint(x: clampX(target.minX + gap), y: clampY(target.minY + gap))
        let insideFits = target.width >= size.width + 2 * gap && target.height >= size.height + 2 * gap
        func overlap(_ origin: CGPoint) -> CGFloat {
            let frame = CGRect(origin: origin, size: size)
            return blocked.reduce(0) { total, rect in
                let hit = frame.intersection(rect)
                return total + (hit.isNull ? 0 : hit.width * hit.height)
            }
        }
        if let clear = tries.first(where: { $0.2 && overlap($0.1) == 0 && !overQueue($0.1) }) {
            return Placement(origin: clear.1, side: clear.0)
        }
        if insideFits, queue != nil, !overQueue(inside),
           !avoid.contains(where: { CGRect(origin: inside, size: size).intersects($0) }) {
            return Placement(origin: inside, side: .inside)
        }
        let best = tries.map { try_ -> (Placement.Side, CGPoint, CGFloat) in
            let origin = CGPoint(x: clampX(try_.1.x), y: clampY(try_.1.y))
            return (try_.0, origin, overlap(origin))
        }.min { $0.2 < $1.2 }!
        return Placement(origin: best.1, side: best.0)
    }

}

/// A small triangle on the bubble edge that faces the target. Drawn in the bubble's own space (0,0 at its
/// top left corner); the tip lines up with the target's centre, kept inside the bubble's rounded corners.
struct CoachMarkPointer: Shape {
    let side: CoachMarkOverlayView.Placement.Side
    let target: CGRect
    let origin: CGPoint
    static let size: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, s = Self.size
        var p = Path()
        switch side {
        case .inside:
            break
        case .below, .above:
            let x = max(20, min(target.midX - origin.x, w - 20))
            let y: CGFloat = side == .below ? 0 : h
            let dir: CGFloat = side == .below ? -1 : 1
            p.move(to: CGPoint(x: x - s, y: y)); p.addLine(to: CGPoint(x: x, y: y + dir * s)); p.addLine(to: CGPoint(x: x + s, y: y))
        case .right, .left:
            let y = max(20, min(target.midY - origin.y, h - 20))
            let x: CGFloat = side == .right ? 0 : w
            let dir: CGFloat = side == .right ? -1 : 1
            p.move(to: CGPoint(x: x, y: y - s)); p.addLine(to: CGPoint(x: x + dir * s, y: y)); p.addLine(to: CGPoint(x: x, y: y + s))
        }
        p.closeSubpath()
        return p
    }
}

/// The whole window with a hole where the mark's target is.
struct CoachMarkScrim: Shape {
    let hole: CGRect
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius))
        return path
    }
}

/// One mark's bubble: title, body, then the counter, Skip and the button.
private struct CoachMarkBubble: View {
    let mark: CoachMarkTourModel.Mark
    let onSkip: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mark.title)
                .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                .foregroundColor(Theme.Colors.win)
            Text(mark.body)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.onInkBody)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(mark.counterLabel)
                    .knockTextStyle(Theme.Typography.keyHint11_5w400)
                    .foregroundColor(Theme.Colors.onInkMuted)
                Spacer(minLength: 0)
                Button("Skip", action: onSkip)
                    .buttonStyle(.plain).pointerCursor()
                    .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                    .foregroundColor(Theme.Colors.onInkQuiet)
                Button(action: onNext) {
                    Text(mark.buttonLabel)
                        .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                        .foregroundColor(Theme.Colors.ink)
                        .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.regionBox).fill(Theme.Colors.honey500))
                }
                .buttonStyle(.pressable).pointerCursor()
            }
            .padding(.top, 6)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.Colors.ink))
        .shadow(color: Theme.Colors.shadowBlack.opacity(0.25), radius: 15, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(mark.title). \(mark.body)")
    }
}
