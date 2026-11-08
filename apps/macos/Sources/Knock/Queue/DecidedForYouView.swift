import SwiftUI

/// The words of the "Decided for you" part of the queue (WAG-412). Plain, friendly, no em-dashes.
enum DecidedForYouCopy {
    static func headerTitle(count: Int) -> String { "Decided for you · \(count) today" }
    static let changeMind = "Change my mind"
    static let hint = "Your rules answered these. The agent has gone on with the answer."

    /// "Naming" for the small tag on a row.
    static func categoryTitle(_ category: AskCategory) -> String { category.title }

    /// The line under a row's title: what the rule chose.
    static func chosenLine(_ item: Case) -> String? {
        item.autoDecided.map { "Chose: \($0.answer)" }
    }
}

/// The folded row "Decided for you · N today". It opens to the list of cases a rule answered.
struct DecidedForYouHeader: View {
    let count: Int
    let isOpen: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text(DecidedForYouCopy.headerTitle(count: count))
                    .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                Spacer(minLength: 0)
                Text(isOpen ? "HIDE" : "SHOW")
                    .knockTextStyle(Theme.Typography.labelCaps10_5w600)
            }
            .foregroundColor(Theme.Colors.ink3)
            .opacity(0.7)
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 6, trailing: 18))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .top)
        .accessibilityLabel(DecidedForYouCopy.headerTitle(count: count))
        .accessibilityAddTraits(.isButton)
    }
}

/// One decided case: the title, what the rule chose, its category, and "Change my mind".
struct DecidedForYouRow: View {
    let item: Case
    let isSelected: Bool
    let onOpen: () -> Void
    let onChangeMind: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.rowTitle)
                    .knockTextStyle(Theme.AskDoc.Typography.answeredRow12_5)
                    .foregroundColor(Theme.Colors.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let category = item.autoDecided?.category {
                    Text(DecidedForYouCopy.categoryTitle(category))
                        .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.Colors.side)
                        .clipShape(Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let line = DecidedForYouCopy.chosenLine(item) {
                    Text(line)
                        .knockTextStyle(Theme.Typography.caption11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Button(action: onChangeMind) {
                    Text(DecidedForYouCopy.changeMind)
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                        .foregroundColor(Theme.Colors.ink)
                        .underline()
                }
                .buttonStyle(.plain).pointerCursor()
                .accessibilityLabel("\(DecidedForYouCopy.changeMind): \(item.rowTitle)")
            }
        }
        .padding(EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.Colors.win : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}
