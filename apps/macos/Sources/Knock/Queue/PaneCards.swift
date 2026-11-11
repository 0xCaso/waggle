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
