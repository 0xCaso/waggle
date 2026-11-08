import SwiftUI

extension View {
    /// The right pane's white card: radius 10, a hairline and a 1 pt shadow (HAIL-107 prototype `.tc`).
    func paneCardSurface() -> some View {
        background(Theme.Colors.win)
            .cornerRadius(Theme.Radius.threadCard)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.threadCard).stroke(Theme.Colors.line, lineWidth: 1))
            .shadow(Theme.Shadow.cardLift)
    }
}

/// "Need from you" and "Why I can't decide" in one card, two icon rows (HAIL-107).
struct NeedWhyCardView: View {
    let need: String
    /// nil leaves the second row out (a returned revision shows the agent's message there instead).
    let why: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(symbol: "scope", label: "Need from you", text: need, style: Theme.Typography.body13w400)
            if let why {
                Rectangle().fill(Theme.Colors.line).frame(height: 1)
                row(symbol: "questionmark.circle", label: "Why I can't decide", text: why, style: Theme.Typography.body12_5w400, color: Theme.Colors.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneCardSurface()
    }

    private func row(symbol: String, label: String, text: String, style: Theme.TextStyle, color: Color = Theme.Colors.ink) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundColor(Theme.Colors.ink3)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                AgentMarkdownText(text: text, style: style, color: color)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
