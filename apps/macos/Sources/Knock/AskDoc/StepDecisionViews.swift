import SwiftUI

/// The step bar under the crumb (WAG-287): a pill per question and a last "Send" pill. The current pill is
/// ink, a question with all its points answered shows a check.
struct StepBarView: View {
    @Binding var doc: QuestionsDocModel

    var body: some View {
        ChipFlowLayout(spacing: 6) {
            ForEach(doc.stepPills, id: \.index) { pill in
                Button { doc.jump(to: pill.index) } label: { label(pill) }
                    .buttonStyle(.plain).pointerCursor()
                    .accessibilityLabel(pill.isSend ? "Review and send" : "Decision \(pill.index + 1): \(pill.title)")
                    .accessibilityAddTraits(pill.isCurrent ? .isSelected : [])
            }
        }
    }

    private func label(_ pill: QuestionsDocModel.StepPill) -> some View {
        let showsCheck = pill.isDone && !pill.isCurrent
        return HStack(spacing: 6) {
            ZStack {
                Circle().fill(showsCheck ? Theme.Colors.ok : Theme.Colors.win).frame(width: 18, height: 18)
                if showsCheck {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.Colors.onFill)
                } else if pill.isSend {
                    Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundColor(pill.isCurrent ? Theme.Colors.ink : Theme.Colors.ink2)
                } else {
                    Text("\(pill.index + 1)")
                        .knockTextStyle(Theme.AskDoc.Typography.countPill11_5w700)
                        .foregroundColor(Theme.Colors.ink)
                }
            }
            Text(pill.title)
                .knockTextStyle(Theme.AskDoc.Typography.chip12_5)
                .foregroundColor(pill.isCurrent ? Theme.Colors.onFill : Theme.Colors.ink2)
                .lineLimit(1)
        }
        .padding(EdgeInsets(top: 4, leading: 5, bottom: 4, trailing: 10))
        .background(pill.isCurrent ? Theme.Colors.ink : Theme.Colors.side)
        .clipShape(Capsule())
        .contentShape(Capsule())
    }
}

/// The last step: a row per question with its picks. A click on a row goes to that step.
struct ReviewStepView: View {
    @Binding var doc: QuestionsDocModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(doc.reviewRows, id: \.index) { row in
                Button { doc.jump(to: row.index) } label: {
                    HStack(spacing: 12) {
                        Text("\(row.index + 1)")
                            .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                            .foregroundColor(Theme.Colors.honey600)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .knockTextStyle(Theme.AskDoc.Typography.pointText14_5)
                                .foregroundColor(Theme.Colors.ink)
                                .multilineTextAlignment(.leading)
                            Text(row.summary)
                                .knockTextStyle(Theme.AskDoc.Typography.artifactMeta12_5)
                                .foregroundColor(Theme.Colors.ink3)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.isDecided ? "Decided" : row.pendingWord)
                            .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                            .foregroundColor(row.isDecided ? Theme.Colors.ok : Theme.Colors.ink3)
                            .padding(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                            .background(row.isDecided ? Theme.Colors.okSoft : Theme.Colors.side)
                            .clipShape(Capsule())
                    }
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Colors.win)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.Colors.line, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain).pointerCursor()
            }
            if let hint = doc.reviewHint {
                Text(hint)
                    .knockTextStyle(Theme.AskDoc.Typography.artifactMeta12_5)
                    .foregroundColor(Theme.Colors.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }
}

/// A grey Back button, used by the bottom bar and the side panel.
struct StepBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Back")
                .knockTextStyle(Theme.Typography.button13_5w600)
                .foregroundColor(Theme.Colors.ink)
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .background(Theme.Colors.side)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .fixedSize()
    }
}

/// An ink "Next: decision 2" / "Review and send" button. It is always on: skipping a question is fine.
struct StepNextButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .knockTextStyle(Theme.Typography.button13_5w600)
                .foregroundColor(Theme.Colors.onFill)
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .background(Theme.Colors.ink)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .fixedSize()
    }
}
