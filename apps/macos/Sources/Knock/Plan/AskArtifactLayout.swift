import SwiftUI

/// The one layout of a request page (C1, spec 2026-11-09 section 1). The decision is always a column: with an
/// artifact, the artifact fills the left and the column is `columnWidth` on the right; when that would leave the
/// artifact under `minArtifactWidth`, the artifact folds to the pinned bar at the top of the column; with no
/// artifact, the column is the page, centred, at most `pageMaxWidth` wide. The column scrolls as one piece, the
/// options in it once, and its answer box and send row are pinned at its bottom.
enum AskLayout {
    enum Layout: Equatable {
        /// The artifact on the left, the decision column on the right.
        case beside
        /// The pane is too narrow for both: the artifact is the pinned bar at the top of the column.
        case folded
        /// No artifact: the column is the page.
        case page
    }

    /// The decision column's width beside an artifact.
    static let columnWidth: CGFloat = 440
    /// The artifact never gets narrower than this beside the column; below it, it folds to the pinned bar.
    static let minArtifactWidth: CGFloat = 480
    /// The column's widest when it is the page (no artifact, or the artifact folded), for reading.
    static let pageMaxWidth: CGFloat = 640

    static func layout(width: CGFloat, hasArtifact: Bool) -> Layout {
        guard hasArtifact else { return .page }
        return width - columnWidth >= minArtifactWidth ? .beside : .folded
    }

    /// The column's width in `layout` for a pane `width` wide.
    static func columnWidth(_ layout: Layout, width: CGFloat) -> CGFloat {
        switch layout {
        case .beside: min(columnWidth, max(0, width))
        case .folded, .page: min(pageMaxWidth, max(0, width))
        }
    }

    /// Full size (C9): the narrowest the decision column gets to leave the artifact its share of the window.
    static let fullSizeMinColumnWidth: CGFloat = 340
    /// Full size (C9): the artifact keeps at least this share of the window while the column can still narrow.
    static let fullSizeArtifactShare: CGFloat = 0.6

    /// The full-size column's width in a window `width` wide (C9): 440 pt while that leaves the artifact at least
    /// 60 % of the window; narrower in step with the window below that (40 % of it), never under 340 pt. Whole
    /// points, so the text is not typeset again at a new fraction of a point.
    static func fullSizeColumnWidth(window width: CGFloat) -> CGFloat {
        let share = (max(0, width) * (1 - fullSizeArtifactShare)).rounded(.down)
        return min(columnWidth, max(fullSizeMinColumnWidth, share))
    }

    /// The stage label of the track: "QUESTION 2 OF ~5". It shows once, in the track, not in the honey box.
    static func questionLabel(_ plan: PlanInfo) -> String { PlanText.progressLabel(plan.stage).uppercased() }

    /// "Background write-up", or the artifact's kind in words when it is not text.
    static func writeUpTitle(_ tab: ArtifactTab?) -> String {
        guard let tab, let kind = tab.kind, kind != .markdown else { return "Background write-up" }
        return "Background " + (tab.hasName ? tab.title : ArtifactTabs.defaultTitle(kind)).lowercased()
    }

    /// The title of the pinned artifact bar: the artifact's own name, the same for a plan and any other ask.
    static func foldTitle(_ tab: ArtifactTab?) -> String {
        guard let tab else { return ArtifactTabs.defaultTitle(nil) }
        return tab.hasName ? tab.title : ArtifactTabs.defaultTitle(tab.kind)
    }

    /// The small line beside the bar's title: "Prototype · v2". A tab with no name already shows its kind as the title.
    static func barMeta(_ tab: ArtifactTab?) -> String? {
        guard let tab else { return nil }
        return tab.hasName ? "\(ArtifactTabs.defaultTitle(tab.kind)) · v\(tab.revision)" : "v\(tab.revision)"
    }
}

/// The artifact and the decision column: the column gets `AskLayout.columnWidth`, the artifact the rest. Issue 9:
/// an `HStack` sized the artifact from the column's measured width, and the page laid itself out about ten times a
/// second without settling. This layout splits the offered width and reports the offered size, so the artifact's
/// size never depends on its own result. It never asks the columns for a size either: the artifact holds a whole
/// write-up, and an ideal size of it would typeset every line unwrapped.
struct AskColumnsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    // A stack around it asks for its alignment guides; the default answer places the columns to find them, which
    // measures the artifact at every probe (WAG-378, the same trap as `FixedMinimumLayout`). It has none to give.
    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? { nil }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, Self.widths(bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }

    /// Whole points, so the text in each column is not typeset again at a new fraction of a point.
    static func widths(_ total: CGFloat) -> [CGFloat] {
        let total = max(0, total.rounded(.down))
        let column = AskLayout.columnWidth(.beside, width: total)
        return [total - column, column]
    }
}

/// The ask's artifact on a pane too narrow for it (`AskLayout.Layout.folded`): one bar at the top of the decision
/// column, outside its scroll, so it never moves off screen. Open shows the artifact full size, with its tabs and
/// comments. With several artifacts, the name is a menu that picks which one Open shows.
struct PinnedArtifactBar: View {
    @ObservedObject var model: LiveArtifactModel
    let composer: ComposerViewModel
    /// WAG-352: off for a request with several decisions, where the decision on screen drives the artifact.
    var followsComposer = true
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: LiveArtifactBoxView.symbol(model.selectedTab?.kind))
                .font(.system(size: 12))
                .foregroundColor(Theme.Colors.ink2)
            name
            if let meta = AskLayout.barMeta(model.selectedTab) {
                Text(meta)
                    .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            Button(action: onOpen) {
                Text("Open")
                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.recommendedBlock).fill(Theme.Colors.ink))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .accessibilityLabel("Open \(AskLayout.foldTitle(model.selectedTab))")
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 6))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Colors.ink, lineWidth: 1))
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        .onChange(of: composer.selectedOptionId) { _, _ in follow() }
        .task { follow() }
    }

    @ViewBuilder
    private var name: some View {
        if model.tabs.count > 1 {
            Menu {
                ForEach(model.tabs, id: \.id) { tab in
                    Button(AskLayout.foldTitle(tab)) { model.select(tab.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    title
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.Colors.ink3)
                }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).pointerCursor()
            .accessibilityLabel("Choose an artifact")
        } else {
            title
        }
    }

    private var title: some View {
        Text(AskLayout.foldTitle(model.selectedTab))
            .knockTextStyle(Theme.Typography.rowTitle13_5w600)
            .foregroundColor(Theme.Colors.ink)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func follow() {
        guard followsComposer else { return }
        model.follow(option: composer.selectedOptionId.flatMap { id in composer.options.first { $0.id == id } })
    }
}
