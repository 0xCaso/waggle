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
        // Mockup B `.row.done`: the green dot, the title in 500 ink2 (two lines at most), then the meta line in
        // quiet 12: "you → B · 16m" (the answer, then the age, which was on the right before).
        HStack(alignment: .firstTextBaseline, spacing: Theme.AskDoc.Chrome.rowGap) {
            RowDot(color: Theme.Colors.ok, pulses: false)
                .sidebarDotOnBaseline()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.AskDoc.Chrome.rowMetaGap) {
                Text(item.rowTitle)
                    .knockTextStyle(Theme.AskDoc.Chrome.rowTitleDone)
                    .foregroundColor(Theme.Colors.ink2)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(metaLine)
                    .knockTextStyle(Theme.AskDoc.Chrome.rowMeta)
                    .foregroundColor(Theme.AskDoc.Colors.quiet)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(optional: ageTooltip)
            }
        }
        .padding(Theme.AskDoc.Chrome.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.AskDoc.Chrome.selectedFill : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Theme.AskDoc.Chrome.selectedBar).frame(width: Theme.AskDoc.Chrome.selectedBarWidth)
            }
        }
        .contextMenu {
            Button("Dismiss", action: onDismiss)
        }
    }

    /// "you → B · 16m": the answer line and the age, the age alone when there is no answer line.
    private var metaLine: String {
        [item.answeredSummaryLine, ageLabel.isEmpty ? nil : ageLabel].compactMap { $0 }.joined(separator: " · ")
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
