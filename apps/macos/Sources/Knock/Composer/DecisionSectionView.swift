import SwiftUI

/// The ask's decision card (HAIL-85, HAIL-107): every option in full, in order, so
/// the answer box can show only a short title per row. Each entry has its
/// number key, the short title in 600 weight, the full label below in regular
/// weight, and "✦ Recommended" on the recommended one. Nothing is clamped.
/// Shared by the case pane and the review workspace's question column.
struct DecisionSectionView: View {
    let options: [Option]
    let recommendationId: String
    /// Set for a select "many" ask (HAIL-123): check boxes in place of number keys, the head reads
    /// "Decision · pick any", and no box starts ticked (WAG-329).
    var multi: Multi? = nil

    struct Multi: Equatable, Sendable {
        let max: Int?
        let recommendedIds: Set<String>

        init(max: Int?, recommendedIds: Set<String>) {
            self.max = max
            self.recommendedIds = recommendedIds
        }

        /// `nil` for a single-choice ask.
        init?(_ item: Case) {
            guard item.select == .many else { return nil }
            self.init(max: item.max, recommendedIds: Set(item.recommendations))
        }
    }

    nonisolated static func title(multi: Multi? = nil) -> String {
        multi.map { MultiSelectCopy.decisionHead(max: $0.max) } ?? "Decision"
    }

    /// One entry of the section as plain data, so a test can check the full
    /// labels without hosting the view.
    struct Entry: Equatable, Sendable {
        let position: Int
        let title: String
        let label: String
        let isRecommended: Bool

        /// The full text under the title, unless it only repeats the title
        /// ("Ship as is" / "Ship as is" on a short option).
        var showsLabel: Bool {
            let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            let body = trim(label)
            return !body.isEmpty && body.caseInsensitiveCompare(trim(title)) != .orderedSame
        }
    }

    nonisolated static func entries(options: [Option], recommendationId: String, multi: Multi? = nil) -> [Entry] {
        options.enumerated().map { index, option in
            Entry(
                position: index + 1, title: option.displayTitle,
                label: OptionLabelFormatting.decisionBody(label: option.label, title: option.displayTitle),
                isRecommended: multi?.recommendedIds.contains(option.id) ?? (option.id == recommendationId))
        }
    }

    var body: some View {
        if !options.isEmpty {
            let entries = Self.entries(options: options, recommendationId: recommendationId, multi: multi)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Colors.ink3)
                        .frame(width: 16, height: 16)
                    Text(Self.title(multi: multi))
                        .knockTextStyle(Theme.Typography.caption11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
                ForEach(entries, id: \.position) { entry in
                    Rectangle().fill(Theme.Colors.line).frame(height: 1)
                    row(entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .paneCardSurface()
        }
    }

    private func row(_ entry: Entry) -> some View {
        let emphasised = entry.isRecommended
        return HStack(alignment: .top, spacing: 10) {
            if multi != nil {
                CheckBoxMark(isTicked: false)
            } else {
                Text("\(entry.position)")
                    .knockTextStyle(Theme.Typography.keyBadge12w600)
                    .foregroundColor(emphasised ? Theme.Colors.win : Theme.Colors.ink)
                    .frame(width: 22, height: 22)
                    .background(emphasised ? Theme.Colors.ink : Color.clear)
                    .cornerRadius(Theme.Radius.chip)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .stroke(emphasised ? Color.clear : Theme.Stroke.card.color, lineWidth: Theme.Stroke.card.width)
                    )
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title)
                        .knockTextStyle(Theme.Typography.value13_5w600)
                        .foregroundColor(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if entry.isRecommended {
                        Text("✦ Recommended")
                            .knockTextStyle(Theme.Typography.tagLabel10_5w500)
                            .foregroundColor(Theme.Colors.recommendedTagText)
                    }
                }
                if entry.showsLabel {
                    AgentMarkdownText(text: entry.label, style: Theme.Typography.body12_5w400, color: Theme.Colors.ink2)
                }
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
