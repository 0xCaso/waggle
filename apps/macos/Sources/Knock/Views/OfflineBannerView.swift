import SwiftUI

/// M11's service-offline banner (docs/design/mvp-values.md §2.14 "Service
/// offline", §M11 `SyfHH` → `S9dILy`).
struct OfflineBannerView: View {
    let onStartService: () -> Void
    let onViewLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .foregroundColor(Theme.Colors.accent)
                Text("Waggle service isn't running")
                    .knockTextStyle(Theme.Typography.body13_5w400)
                    .fontWeight(.semibold)
                    .foregroundColor(Theme.Colors.accent)
            }
            Text("Agents can't reach you. waggle_ask calls fail and agents fall back to the terminal.")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink2)
            HStack(spacing: 10) {
                Button(action: onStartService) {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                        Text("Start service")
                            .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                    }
                    .foregroundColor(Theme.Colors.win)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 11)
                    .background(Theme.Colors.ink)
                    .cornerRadius(Theme.Radius.buttonSmall)
                }
                .buttonStyle(.plain).pointerCursor()

                Button(action: onViewLog) {
                    Text("View log")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                        .foregroundColor(Theme.Colors.ink2)
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.accentSoft)
    }
}
