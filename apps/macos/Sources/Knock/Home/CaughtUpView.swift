import SwiftUI

/// "All caught up": the pane of an empty inbox after the first answer (docs/decisions/2026-11-11-caught-up-empty-state.md).
/// Centred: the app mark, the title, one line, two chips and one quiet line. The numbers come from
/// `AppModel.caughtUpStats`; a chip hides at zero.
struct CaughtUpView: View {
    let stats: CaughtUpStats.Values

    var body: some View {
        VStack(spacing: 10) {
            KnockMarkView()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            Text(FirstRunRules.caughtUpTitle)
                .knockTextStyle(Theme.Typography.dialogTitle19w650)
                .foregroundColor(Theme.Colors.ink)
                .padding(.top, 4)
            Text(FirstRunRules.caughtUpSubtitle)
                .knockTextStyle(Theme.Typography.body13_5w400)
                .foregroundColor(Theme.Colors.ink2)
            let chips = FirstRunRules.chips(answeredToday: stats.answeredToday, agentsRunning: stats.agentsRunning)
            if !chips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.text) { chip in CaughtUpChipView(chip: chip) }
                }
                .padding(.top, 4)
            }
            Text(FirstRunRules.caughtUpQuietLine)
                .knockTextStyle(Theme.Typography.caption11_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
                .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.win)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("caught-up-pane")
    }
}

private struct CaughtUpChipView: View {
    let chip: CaughtUpChip

    var body: some View {
        Text(chip.text)
            .knockTextStyle(Theme.Typography.caption11_5w400)
            .foregroundColor(chip.tone == .green ? Theme.Colors.ok : Theme.Colors.ds)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(chip.tone == .green ? Theme.Colors.okSoft : Theme.Colors.dsSoft))
    }
}
