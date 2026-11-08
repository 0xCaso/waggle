import SwiftUI

/// "3 earlier asks ▾" on the crumbs line and the popover it opens (WAG-257, case c_e6dab43f): one row
/// per earlier ask of the same session. Pure, so the rows and the footer are unit-tested.
struct EarlierAsksModel: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        /// "You picked: Flagged first", "You: ship it" or "No answer yet".
        let outcome: String
        /// "21:30": when you answered, or when the ask arrived.
        let time: String
        let isAnswered: Bool
    }

    let rows: [Row]
    /// Asks of this session that arrived today, this one included.
    let stepsToday: Int

    /// The crumbs link; nil (hidden) when there are no earlier asks.
    var linkLabel: String? {
        rows.isEmpty ? nil : "\(rows.count) earlier request\(rows.count == 1 ? "" : "s")"
    }

    var footer: String { "Thread: \(stepsToday) step\(stepsToday == 1 ? "" : "s") today" }

    static let label = "EARLIER IN THIS SESSION"
    static let historyLabel = "Open the history ›"
    /// A reply longer than this is cut, so a row stays one line.
    static let shortReplyLimit = 60

    static func make(
        item: Case, cases: [Case], now: Date = Date(), calendar: Calendar = .current, timeZone: TimeZone = .current
    ) -> EarlierAsksModel {
        let earlier = SessionContextBlock.earlierAsks(of: item, in: cases)
            .sorted { ($0.createdAtDate ?? .distantPast, $0.id) < ($1.createdAtDate ?? .distantPast, $1.id) }
        let rows = earlier.map { ask -> Row in
            let answered = ask.latestReplyAt != nil
            let at = (answered ? ask.latestReplyAtDate : nil) ?? ask.createdAtDate
            return Row(
                id: ask.id, title: ask.title, outcome: outcome(ask),
                time: at.map { ThreadCopy.clock($0, timeZone: timeZone) } ?? "", isAnswered: answered)
        }
        let today = (earlier + [item]).filter { ask in
            ask.createdAtDate.map { calendar.isDate($0, inSameDayAs: now) } ?? false
        }.count
        return EarlierAsksModel(rows: rows, stepsToday: today)
    }

    static func outcome(_ ask: Case) -> String {
        guard ask.latestReplyAt != nil else { return "No answer yet" }
        if !ask.latestReplyChoices.isEmpty { return "You picked: " + ask.repliedChoiceTitles.joined(separator: ", ") }
        if let words = ask.latestReplyWithChangesWords { return "You picked: " + words }
        if let choice = ask.latestReplyChoice, !choice.isEmpty {
            return "You picked: " + (ask.repliedOptions.first { $0.id == choice }?.displayTitle ?? choice)
        }
        if let line = SessionContextBlock.firstLine(ask.latestReplyMessage) {
            let short = line.count > shortReplyLimit ? String(line.prefix(shortReplyLimit)) + "…" : line
            return "You: " + short
        }
        return "You answered"
    }
}

/// The blue link at the end of the crumbs line. Hidden when there is nothing earlier.
struct EarlierAsksLink: View {
    let model: EarlierAsksModel
    var onOpenCase: (String) -> Void
    /// `nil` where there is no conversation to open (the review panel): the history link is left out.
    var onOpenHistory: (() -> Void)?
    @State private var isOpen = false

    var body: some View {
        if let label = model.linkLabel {
            Button { isOpen.toggle() } label: {
                Text(label + " ▾")
                    .knockTextStyle(Theme.AskDoc.Typography.crumbs12_5)
                    .foregroundColor(Theme.Colors.ds)
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.plain).pointerCursor()
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                EarlierAsksPopover(
                    model: model,
                    onOpenCase: { isOpen = false; onOpenCase($0) },
                    onOpenHistory: onOpenHistory.map { open in { isOpen = false; open() } })
            }
        }
    }
}

/// 440 wide, radius 14, a line border and a shadow. Rows and the footer never set the width: they truncate.
struct EarlierAsksPopover: View {
    let model: EarlierAsksModel
    var onOpenCase: (String) -> Void = { _ in }
    var onOpenHistory: (() -> Void)? = {}
    static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(EarlierAsksModel.label)
                .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                .foregroundColor(Theme.Colors.ink3)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        Button { onOpenCase(row.id) } label: { rowView(row) }
                            .buttonStyle(.plain).pointerCursor()
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack(spacing: 8) {
                Text(model.footer)
                    .knockTextStyle(Theme.AskDoc.Typography.crumbs12)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let onOpenHistory {
                    Button(action: onOpenHistory) {
                        Text(EarlierAsksModel.historyLabel)
                            .knockTextStyle(Theme.AskDoc.Typography.crumbs12_5)
                            .foregroundColor(Theme.Colors.ds)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .top)
        }
        .frame(width: Self.width)
        .background(Theme.Colors.win)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.Colors.line, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.10), radius: 12, y: 4)
    }

    private func rowView(_ row: EarlierAsksModel.Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.isAnswered ? "checkmark" : "circle.dotted")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(row.isAnswered ? Theme.Colors.ok : Theme.AskDoc.Colors.quiet)
                .frame(width: 14)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .knockTextStyle(Theme.AskDoc.Typography.earlierTitle13_5)
                    .foregroundColor(Theme.Colors.ink)
                    .lineLimit(1).truncationMode(.tail)
                Text(row.time.isEmpty ? row.outcome : "\(row.outcome) · \(row.time)")
                    .knockTextStyle(Theme.AskDoc.Typography.answeredRow12_5)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .contentShape(Rectangle())
    }
}
