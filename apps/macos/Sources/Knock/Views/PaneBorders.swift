import AppKit
import SwiftUI

/// The two pane borders that move by drag (task 13a, docs/decisions/2026-11-10-mockup-style-in-the-whole-app.md):
/// the sidebar's right edge and the decision column's left edge. Pure, so the clamps, the reset and the saved
/// keys are unit-tested.
enum PaneBorder: String, CaseIterable {
    /// Between the sidebar (the queue) and the case pane.
    case sidebar
    /// Between the artifact and the decision column.
    case decisionColumn

    /// The width a double click sets again.
    var defaultWidth: CGFloat {
        switch self {
        case .sidebar: Theme.AskDoc.Chrome.sidebarWidth
        case .decisionColumn: AskLayout.columnWidth
        }
    }

    /// The narrowest and widest the pane on this border gets.
    var range: ClosedRange<CGFloat> {
        switch self {
        case .sidebar: 240...420
        case .decisionColumn: 360...640
        }
    }

    /// The saved width's key, next to the folds' `knock.split.*` keys.
    var defaultsKey: String { "knock.split.\(rawValue)Width" }

    /// A drag to the right widens the sidebar and narrows the decision column (it sits right of its border).
    var growsRightward: Bool { self == .sidebar }

    /// `width` inside `range`, in whole points, so the text is not typeset again at a fraction of a point.
    func clamp(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        return min(range.upperBound, max(range.lowerBound, width.rounded()))
    }

    /// The width after a drag of `translation` points from a drag that started at `start`. `limit` is the widest
    /// the pane can get right now (the decision column leaves the artifact its minimum); never under `range`.
    func dragged(from start: CGFloat, translation: CGFloat, limit: CGFloat? = nil) -> CGFloat {
        let width = clamp(start + (growsRightward ? translation : -translation))
        guard let limit else { return width }
        return max(range.lowerBound, min(width, limit.rounded(.down)))
    }

    /// The saved width, clamped; the default when nothing (or nothing valid) is saved.
    func saved(in defaults: UserDefaults) -> CGFloat {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultWidth }
        let value = CGFloat(defaults.double(forKey: defaultsKey))
        return value > 0 ? clamp(value) : defaultWidth
    }
}

/// The two saved widths. One store for the window, so the sidebar and the case pane read the same values.
@MainActor
final class PaneWidthStore: ObservableObject {
    static let shared = PaneWidthStore()

    @Published private(set) var sidebarWidth: CGFloat
    @Published private(set) var decisionColumnWidth: CGFloat
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sidebarWidth = PaneBorder.sidebar.saved(in: defaults)
        decisionColumnWidth = PaneBorder.decisionColumn.saved(in: defaults)
    }

    func width(_ border: PaneBorder) -> CGFloat {
        switch border {
        case .sidebar: sidebarWidth
        case .decisionColumn: decisionColumnWidth
        }
    }

    /// Sets the border's width (clamped) and, unless `save` is false, saves it. A drag moves the width with
    /// `save: false` on every step and calls `save(_:)` once when it ends.
    func set(_ border: PaneBorder, _ width: CGFloat, save: Bool = true) {
        let width = border.clamp(width)
        guard width != self.width(border) else { return }
        switch border {
        case .sidebar: sidebarWidth = width
        case .decisionColumn: decisionColumnWidth = width
        }
        if save { self.save(border) }
    }

    /// Saves the border's current width.
    func save(_ border: PaneBorder) {
        defaults.set(Double(width(border)), forKey: border.defaultsKey)
    }

    /// The double click: the default width again, and nothing saved.
    func reset(_ border: PaneBorder) {
        switch border {
        case .sidebar: sidebarWidth = border.defaultWidth
        case .decisionColumn: decisionColumnWidth = border.defaultWidth
        }
        defaults.removeObject(forKey: border.defaultsKey)
    }
}

/// The hit area over a pane's 1 pt border line: 6 pt wide, centred on the line, with the resize pointer. Drag
/// moves the border; a double click sets the default width again. The line looks the same; while dragging it
/// takes a soft honey tint.
struct PaneBorderHandle: View {
    let border: PaneBorder
    @ObservedObject var store: PaneWidthStore
    /// The widest the pane can get right now, or nil for the border's own maximum.
    var limit: CGFloat? = nil

    static let hitWidth: CGFloat = 6

    @State private var dragStart: CGFloat?
    @State private var hovering = false
    @State private var cursorPushed = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(dragStart == nil ? Color.clear : Theme.Colors.honey500.opacity(0.7))
                .frame(width: 1)
        }
        .frame(width: Self.hitWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            updateCursor()
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? store.width(border)
                    if dragStart == nil { dragStart = start }
                    store.set(
                        border, border.dragged(from: start, translation: value.translation.width, limit: limit),
                        save: false)
                    updateCursor()
                }
                .onEnded { _ in
                    if dragStart != nil { store.save(border) }
                    dragStart = nil
                    updateCursor()
                }
        )
        .onTapGesture(count: 2) { store.reset(border) }
        .onDisappear {
            hovering = false
            dragStart = nil
            updateCursor()
        }
        .accessibilityElement()
        .accessibilityLabel(border == .sidebar ? "Sidebar width" : "Decision column width")
        .accessibilityValue("\(Int(store.width(border))) points")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = direction == .increment ? 20 : -20
            let start = store.width(border)
            store.set(border, border.dragged(from: start, translation: border.growsRightward ? step : -step, limit: limit))
        }
    }

    /// The resize pointer while over the line or dragging it; balanced push and pop.
    private func updateCursor() {
        let wants = hovering || dragStart != nil
        if wants && !cursorPushed {
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
        } else if !wants && cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}
