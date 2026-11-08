import SwiftUI

/// The main window's root (WAG-375, issue 9). With the default window rule (content sets the minimum size),
/// `NSHostingView` measures the whole page at a proposed size of 0 on every layout pass and every constraint update,
/// to find the window's minimum. On a long request that is a typeset at about 1 pt of width, thousands of points tall,
/// in every pass. This layout answers the minimum, ideal and maximum probes from fixed numbers and never asks the page,
/// so only the real size reaches it.
struct FixedMinimumLayout: Layout {
    let minSize: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: max(minSize.width, proposal.width ?? minSize.width),
            height: max(minSize.height, proposal.height ?? minSize.height)
        )
    }

    // WAG-378 (issue 9): a stack or a background around the root asks for its alignment guides. The default
    // answer places the page to find them, at the minimum size, so every probe still measured the whole page
    // at 900 wide next to the real pass. The root has no guides of its own to give.
    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? { nil }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

extension View {
    /// Gives the window a fixed minimum size without measuring this view for it (WAG-375).
    func fixedWindowMinimum(width: CGFloat, height: CGFloat) -> some View {
        FixedMinimumLayout(minSize: CGSize(width: width, height: height)) { self }
    }
}
