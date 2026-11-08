import SwiftUI

/// What a request with an artifact shows on the main page. On a wide window (WAG-290, prototype "B";
/// every ask since WAG-306) the page has two columns: the artifact at full height on the left, the question and its calm
/// option cards on the right. A narrow window stacks them: the question scrolls, and a bar above the answers names
/// the artifact and opens it (decision 2026-11-05).
enum AskLayout {
    enum Layout: Equatable {
        /// The artifact on the left, the question on the right.
        case sideBySide
        /// One column: the track, the write-up, then the question.
        case stacked
    }

    /// The artifact column's share of the width.
    static let artifactShare: CGFloat = 0.57
    /// The right column never gets narrower than this; below it the page stacks.
    static let minQuestionWidth: CGFloat = 320
    /// Below this window width the page stacks.
    static let minSideBySideWidth: CGFloat = 1000

    /// Two columns for any ask with an artifact, in a window wide enough for both (WAG-306).
    static func layout(width: CGFloat, hasArtifact: Bool) -> Layout {
        guard hasArtifact else { return .stacked }
        let questionWidth = width * (1 - artifactShare)
        return width >= minSideBySideWidth && questionWidth >= minQuestionWidth ? .sideBySide : .stacked
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

/// The two columns of a side-by-side ask: the artifact takes `artifactShare` of the width it is given, the
/// question the rest. Issue 9: an `HStack` sized the artifact from the column's measured width. When the question
/// needed a little more than its share, the stack grew past the pane, the measured width grew with it, the artifact
/// grew again, and the page laid itself out about ten times a second without settling. This layout splits the
/// offered width and reports the offered size, so the artifact's size never depends on its own result. It never asks
/// the columns for a size either: the artifact holds a whole write-up, and an ideal size of it would typeset every
/// line unwrapped.
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
        let artifact = max(0, (total * AskLayout.artifactShare).rounded(.down))
        return [artifact, max(0, total - artifact)]
    }
}

/// The ask's artifact on a stacked page (decision 2026-11-05, every ask with an artifact): one bar directly above the
/// answers, outside the scroll, so it never moves off screen. Open shows the artifact full size, with its tabs and
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
