import SwiftUI

/// One example of what an agent can bring you.
struct ExampleRequest: Equatable {
    let area: String
    let symbol: String
    let title: String
    let artifact: String

    /// Eight areas, one example each. They were step 2 of the old setup (HAIL-101); since WAG-338 they are
    /// the empty state of the queue, where a person with nothing yet sees what could come.
    static let all: [ExampleRequest] = [
        ExampleRequest(area: "MARKETING", symbol: "megaphone", title: "Which headline for the launch email: A or B?", artifact: "2 drafts"),
        ExampleRequest(area: "DESIGN", symbol: "paintpalette", title: "Pricing card: compact or detailed?", artifact: "prototype"),
        ExampleRequest(area: "OPERATIONS", symbol: "gearshape", title: "Move support to a shared inbox this week?", artifact: "trade-off grid"),
        ExampleRequest(area: "FINANCE", symbol: "banknote", title: "Annual plan at 20% or 15% off?", artifact: "chart"),
        ExampleRequest(area: "CODE", symbol: "chevron.left.forwardslash.chevron.right", title: "Migrate to Postgres now, or after launch?", artifact: "plan"),
        ExampleRequest(area: "WRITING", symbol: "pencil", title: "Is this reply to the customer too blunt?", artifact: "draft"),
        ExampleRequest(area: "DATA", symbol: "chart.bar", title: "Signups dropped 18%. Which fix ships first?", artifact: "chart"),
        ExampleRequest(area: "PERSONAL", symbol: "star", title: "Lisbon or Porto for the team offsite?", artifact: "screenshots"),
    ]

    static let heading = "Nothing here yet"
    static let subheading = "Any decision your agent would stop to ask you about. Not only code. A few ideas:"
}

/// The queue's empty state: the eight examples, one per row.
struct QueueEmptyStateView: View {
    /// Inside the queue's own scroll view (the list sits under it): no scroll view of its own.
    var embedded = false

    var body: some View {
        if embedded { content } else { ScrollView { content } }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(ExampleRequest.heading)
                    .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                    .foregroundColor(Theme.Colors.ink)
                Text(ExampleRequest.subheading)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    ForEach(ExampleRequest.all, id: \.area) { example in row(example) }
                }
                .padding(.top, 2)
            }
            .padding(EdgeInsets(top: 12, leading: 18, bottom: 18, trailing: 18))
            .accessibilityIdentifier("queue-empty-state")
    }

    private func row(_ example: ExampleRequest) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: example.symbol)
                .font(.system(size: 12))
                .foregroundColor(Theme.Colors.ink2)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(example.title)
                    .knockTextStyle(Theme.Typography.button13_5w500)
                    .foregroundColor(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(example.area.capitalized) · \(example.artifact)")
                    .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(Theme.Colors.win)
        .cornerRadius(Theme.Radius.card)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.Colors.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
