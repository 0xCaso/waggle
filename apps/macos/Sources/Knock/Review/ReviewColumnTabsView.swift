import SwiftUI

/// The right column's Decision | Comments switch (HAIL-56 contract, frames
/// `ovd06`/`PPM9l` node `PBNIR`/`CdVIh` "Column tabs"): sits at the top of
/// both `AskColumnView` and `CommentsColumnView`'s scrollable content, above
/// their own title/heading - the same 24pt-leading/20pt-top position both
/// already pad their content to.
///
/// Independent of `ReviewMode` (the canvas toolbar's Interact/Comment tool):
/// selecting a tab here only changes which of the two columns renders, and a
/// tool switch alone never moves this (`ReviewViewModel.tab`, see its own
/// doc).
struct ReviewColumnTabsView: View {
    let tab: ReviewColumnTab
    /// The session's total comment count, for the Comments segment's count
    /// badge - hidden at 0, the same threshold `AskColumnView.
    /// commentsSummaryPrefix` uses for its own "· Show" line.
    let commentCount: Int
    let onSelect: (ReviewColumnTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(.question, label: "Decision", badgeCount: nil)
            segment(.comments, label: "Comments", badgeCount: commentCount > 0 ? commentCount : nil)
        }
        .padding(3)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.columnTabsTrack)
    }

    private func segment(_ value: ReviewColumnTab, label: String, badgeCount: Int?) -> some View {
        let isActive = tab == value
        return HStack(spacing: 6) {
            Text(label)
                .knockTextStyle(isActive ? Theme.Typography.buttonSm12_5w600 : Theme.Typography.buttonSm12_5w500)
                .foregroundColor(isActive ? Theme.Colors.ink : Theme.Colors.ink2)
            if let badgeCount {
                countBadge(badgeCount, isActive: isActive)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        .frame(maxWidth: .infinity)
        .background(isActive ? Theme.Colors.win : Color.clear)
        .cornerRadius(Theme.Radius.columnTabsSegment)
        .shadow(
            color: isActive ? Theme.Shadow.columnTab.color : .clear,
            radius: Theme.Shadow.columnTab.blur / 2,
            x: Theme.Shadow.columnTab.offset.width, y: Theme.Shadow.columnTab.offset.height
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect(value) }.pointerCursor()
    }

    private func countBadge(_ count: Int, isActive: Bool) -> some View {
        Text("\(count)")
            .knockTextStyle(Theme.Typography.countBadge10_5w600)
            .foregroundColor(isActive ? Theme.Colors.win : Theme.Colors.ink2)
            .padding(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
            .background(isActive ? Theme.Colors.accent : Theme.Colors.line)
            .cornerRadius(Theme.Radius.countBadge)
    }
}
