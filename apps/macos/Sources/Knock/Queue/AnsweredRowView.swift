import SwiftUI

/// A compact row in the queue's "Answered" group (HAIL-64): a small still
/// grid, the title, "you → <answer>" and the age on the right. The title
/// truncates before the age does.
struct AnsweredRowView: View {
    let item: Case
    /// "9m ago", "1d ago".
    let ageLabel: String
    let ageTooltip: String?
    let isSelected: Bool
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isSelected {
                Rectangle()
                    .fill(Theme.Colors.ink)
                    .frame(width: Theme.Spacing.selectionBarWidth)
                    .frame(maxHeight: .infinity)
            }
            HStack(alignment: .top, spacing: 10) {
                // A still faint grid: dozens of rows must not each animate.
                PixelStatusGrid(pattern: AgentStatus.closed.pattern, color: AgentStatus.closed.color, cell: 2.5)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.rowTitle)
                            .knockTextStyle(Theme.AskDoc.Typography.answeredRow12_5)
                            .foregroundColor(Theme.AskDoc.Colors.quiet)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text(ageLabel)
                            .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                            .foregroundColor(Theme.Colors.ink3)
                            .fixedSize(horizontal: true, vertical: false)
                            .help(optional: ageTooltip)
                    }
                    if let summary = item.answeredSummaryLine {
                        Text(summary)
                            .knockTextStyle(Theme.Typography.caption11_5w400)
                            .foregroundColor(Theme.Colors.ink3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.Colors.win : Color.clear)
        .contextMenu {
            Button("Dismiss", action: onDismiss)
        }
    }
}

extension View {
    /// `.help(_:)` with no tooltip at all when `text` is `nil`.
    @ViewBuilder
    func help(optional text: String?) -> some View {
        if let text {
            self.help(text)
        } else {
            self
        }
    }
}
