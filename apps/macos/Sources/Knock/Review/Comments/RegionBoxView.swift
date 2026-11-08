import SwiftUI

/// A pin's region rectangle (docs/design/mvp-values.md §2.12, §M5 `NFUxI`
/// committed / `od4Eu` drafting): rounded, `accent`-stroked, with a lighter
/// fill while still drafting than once saved. A drafting region also shows
/// two corner drag-handles (`snFiG`/`FqRI9`).
struct RegionBoxView: View {
    enum Style {
        case committed
        case drafting
    }

    let style: Style
    var showsHandles: Bool = false
    /// HAIL-75: the highlighted comment's box is filled deeper with a heavier edge.
    var isSelected: Bool = false

    private var fillAlpha: Double {
        if isSelected { return Theme.Alpha.regionSelected }
        return style == .committed ? Theme.Alpha.regionCommitted : Theme.Alpha.regionDrafting
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.regionBox)
                .fill(Theme.Colors.accent.opacity(fillAlpha))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.regionBox)
                        .stroke(Theme.Stroke.regionBox.color, lineWidth: Theme.Stroke.regionBox.width + (isSelected ? 1.5 : 0))
                )
            if showsHandles {
                GeometryReader { proxy in
                    handle.position(x: 0, y: 0)
                    handle.position(x: proxy.size.width, y: proxy.size.height)
                }
            }
        }
    }

    private var handle: some View {
        Circle()
            .fill(Theme.Colors.win)
            .frame(width: Theme.Spacing.regionHandleSize, height: Theme.Spacing.regionHandleSize)
            .overlay(
                Circle().stroke(Theme.Stroke.regionBox.color, lineWidth: Theme.Stroke.regionBox.width)
            )
    }
}
