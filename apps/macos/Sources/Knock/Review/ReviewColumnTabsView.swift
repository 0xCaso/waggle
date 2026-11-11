import SwiftUI

/// The decision column's Decision · Conversation · Comments switch (C8): one component at the top of the
/// column in the case pane and in full size (`AskColumnView`, `CommentsColumnView`).
///
/// Independent of `ReviewMode` (the canvas toolbar's Interact/Comment tool): selecting a tab here only changes
/// what the column shows, and a tool switch alone never moves this (`ReviewViewModel.tab`, see its own doc).
struct ReviewColumnTabsView: View {
    let tab: ReviewColumnTab
    /// The case's comment count, for the Comments badge; hidden at 0.
    let commentCount: Int
    /// The rounds of the conversation, as the mockup's "Conversation 3"; nil hides it.
    var conversationCount: Int? = nil
    /// A new agent message you have not opened the Conversation tab for (`ConversationDot`).
    var conversationDot = false
    /// Team comments you have not seen yet (`CommentsDot`).
    var commentsDot = false
    let onSelect: (ReviewColumnTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(.question, label: "Decision", badgeCount: nil, dot: false)
            segment(.conversation, label: "Conversation", badgeCount: conversationCount, dot: conversationDot)
            segment(.comments, label: "Comments", badgeCount: commentCount > 0 ? commentCount : nil, dot: commentsDot)
        }
        .padding(3)
        .background(Theme.Colors.side)
        .clipShape(RoundedRectangle(cornerRadius: Column.tabsTrackRadius))
    }

    private typealias Column = Theme.AskDoc.Column

    private func segment(_ value: ReviewColumnTab, label: String, badgeCount: Int?, dot: Bool) -> some View {
        let isActive = tab == value
        return HStack(spacing: 6) {
            // `.tabs span`: 500 13, ink3; the open tab ink on white. The line box is the CSS one (13 × 1.45).
            Text(label)
                .knockTextStyle(Column.tabLabel)
                .foregroundColor(isActive ? Theme.Colors.ink : Theme.Colors.ink3)
                .lineLimit(1)
                .fixedSize()
                .frame(height: Column.lineBox(13))
            if let badgeCount {
                countBadge(badgeCount)
            }
            if dot {
                Circle().fill(Theme.Colors.link).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Column.tabSegmentRadius)
                .fill(isActive ? Theme.Colors.win : Color.clear)
                .shadow(
                    color: isActive ? Theme.Shadow.columnTab.color : .clear,
                    radius: Column.tabShadowBlur / 2,
                    x: Theme.Shadow.columnTab.offset.width, y: Theme.Shadow.columnTab.offset.height))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(value) }.pointerCursor()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + (badgeCount.map { ", \($0)" } ?? "") + (dot ? ", new" : ""))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    /// `.tabs .n`: mono 400 11, quiet, no fill.
    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .knockTextStyle(Column.tabCount)
            .foregroundColor(Theme.AskDoc.Colors.quiet)
            .fixedSize()
    }
}
