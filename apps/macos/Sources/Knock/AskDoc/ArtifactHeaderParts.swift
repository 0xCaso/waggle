import SwiftUI

/// WAG-323: how wide each tab of the box header is. Tabs that fit keep their own width. When they do not
/// fit, the short ones keep theirs and the long ones share what is left evenly, down to a floor. A shrunk
/// title ends in "…" and the tab's tooltip says the whole name.
enum ArtifactTabWidths {
    /// The icon and a few letters.
    static let minimum: CGFloat = 56

    static func fit(natural: [CGFloat], available: CGFloat, spacing: CGFloat) -> [CGFloat] {
        guard !natural.isEmpty else { return [] }
        let gaps = spacing * CGFloat(natural.count - 1)
        guard natural.reduce(0, +) + gaps > available else { return natural }
        var remaining = max(0, available - gaps)
        var left = natural.count
        var cap = CGFloat.infinity
        for width in natural.sorted() {
            let share = remaining / CGFloat(left)
            if width <= share {
                remaining -= width
                left -= 1
            } else {
                cap = share
                break
            }
        }
        return natural.map { max(minimum, min($0, cap)) }
    }
}

/// Lays the tabs out in one row with `ArtifactTabWidths`, so the last tab is never cut at the box width.
/// With `available` set, the row fits to that width whatever it is proposed (the scrolling copy).
private struct ArtifactTabRow: Layout {
    var spacing: CGFloat = 6
    var available: CGFloat?

    private func widths(_ subviews: Subviews, available: CGFloat) -> [CGFloat] {
        ArtifactTabWidths.fit(natural: subviews.map { $0.sizeThatFits(.unspecified).width }, available: available, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let fitted = widths(subviews, available: available ?? proposal.width ?? .infinity)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: fitted.reduce(0, +) + spacing * CGFloat(max(0, fitted.count - 1)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(subviews, available: available ?? bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// WAG-350: asks for the width of its first child (a hidden copy of the tab row) but never more than it is
/// offered, and gives that size to the second child, the sideways scroller. Tabs that do not fit scroll;
/// they never push the box wider.
private struct ArtifactTabViewport: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let measure = subviews.first else { return .zero }
        let size = measure.sizeThatFits(proposal)
        return CGSize(width: min(size.width, proposal.width ?? .infinity), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

/// The tab strip of the artifact box header. The case page box and the full-size toolbar share it
/// (WAG-309). The tabs shrink evenly to the width they get (WAG-323), each with its name as a tooltip.
/// Below the floor width they scroll sideways, with no bar, and the selected tab stays in view (WAG-350).
struct ArtifactTabStrip: View {
    let tabs: [ArtifactTab]
    let selectedId: String?
    let onSelect: (ArtifactTab) -> Void

    var body: some View {
        ArtifactTabViewport {
            ArtifactTabRow { ForEach(tabs) { tab in tabButton(tab) } }
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        ArtifactTabRow(available: geo.size.width) { ForEach(tabs) { tab in tabButton(tab).id(tab.id) } }
                    }
                    .onAppear { reveal(selectedId, with: proxy) }
                    .onChange(of: selectedId) { _, id in reveal(id, with: proxy) }
                }
            }
        }
    }

    private func reveal(_ id: String?, with proxy: ScrollViewProxy) {
        guard let id else { return }
        proxy.scrollTo(id)
    }

    private func tabButton(_ tab: ArtifactTab) -> some View {
        let isOn = tab.id == selectedId
        return Button { onSelect(tab) } label: {
            HStack(spacing: 5) {
                Image(systemName: LiveArtifactBoxView.symbol(tab.kind)).font(.system(size: 10))
                Text(tab.title).knockTextStyle(Theme.AskDoc.Typography.chip12_5).lineLimit(1).truncationMode(.tail)
            }
            .foregroundColor(isOn ? Theme.Colors.ink : Theme.Colors.ink3)
            .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
            .background(isOn ? Theme.Colors.win : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isOn ? Theme.Colors.line : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The Open menu of the full-size toolbar (WAG-309): the same items as the box menu, without "Full size",
/// since the view is full size already. "In a new window" always; "In the browser" for a page only.
struct ArtifactFullSizeOpenMenu: View {
    let kind: ArtifactKind?
    var onOpenWindow: (() -> Void)?
    var onOpenBrowser: (() -> Void)?

    /// The menu items, top to bottom.
    static func items(kind: ArtifactKind?, hasWindow: Bool, hasBrowser: Bool) -> [LiveArtifactBoxView.OpenItem] {
        LiveArtifactBoxView.openItems(kind: kind, hasWindow: hasWindow, hasBrowser: hasBrowser).filter { $0 != .fullSize }
    }

    var body: some View {
        let items = Self.items(kind: kind, hasWindow: onOpenWindow != nil, hasBrowser: onOpenBrowser != nil)
        if !items.isEmpty {
            Menu {
                ForEach(items, id: \.self) { item in
                    Button(item.label) {
                        switch item {
                        case .window: onOpenWindow?()
                        case .browser: onOpenBrowser?()
                        case .fullSize: break
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text("Open").knockTextStyle(Theme.Typography.buttonSm12_5w500).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(Theme.Colors.ink2)
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 8))
                .background(Theme.Colors.win)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.Colors.line2, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize().pointerCursor()
            .accessibilityLabel("Open")
            // `KNOCK_EVIDENCE_OPEN_MENU=1` (WAG-309 evidence hook): a native menu is not part of the window
            // snapshot, so the same items draw in a row beside the button (a web view would hide a list below it).
            .overlay(alignment: .topTrailing) {
                if ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_OPEN_MENU"] == "1" {
                    HStack(spacing: 0) {
                        ForEach(items, id: \.self) { item in
                            Text(item.label).knockTextStyle(Theme.Typography.buttonSm12_5w500)
                                .foregroundColor(Theme.Colors.ink)
                                .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 24))
                        }
                    }
                    .background(Theme.Colors.win)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Colors.line2, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .fixedSize()
                    .offset(x: -78)
                }
            }
        }
    }
}
