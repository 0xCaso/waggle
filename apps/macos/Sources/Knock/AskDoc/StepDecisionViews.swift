import SwiftUI

/// The step bar at the top of the decision (WAG-287, C2): numbers only, 1 · 2 · 3 · Send. The tooltip gives each
/// step's full title; the title of the current step is the question right under the bar. A finished step shows a
/// check, the current one is ink. A click jumps to the step.
struct StepBarView: View {
    @Binding var doc: QuestionsDocModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(doc.stepPills, id: \.index) { pill in
                Button { doc.jump(to: pill.index) } label: { label(pill) }
                    .buttonStyle(.plain).pointerCursor()
                    .help(pill.help)
                    .accessibilityLabel(pill.isSend ? "Review and send" : "Decision \(pill.index + 1): \(pill.help)")
                    .accessibilityAddTraits(pill.isCurrent ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func label(_ pill: QuestionsDocModel.StepPill) -> some View {
        let showsCheck = pill.isDone && !pill.isCurrent
        if pill.isSend {
            Text(pill.number)
                .knockTextStyle(Theme.AskDoc.Typography.chip12_5)
                .foregroundColor(pill.isCurrent ? Theme.Colors.onFill : Theme.Colors.ink2)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(pill.isCurrent ? Theme.Colors.ink : Theme.Colors.side)
                .clipShape(Capsule())
                .contentShape(Capsule())
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(pill.isCurrent ? Theme.Colors.ink : (showsCheck ? Theme.Colors.okSoft : Theme.Colors.side))
                if showsCheck {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.Colors.ok)
                } else {
                    Text(pill.number)
                        .knockTextStyle(Theme.AskDoc.Typography.countPill11_5w700)
                        .foregroundColor(pill.isCurrent ? Theme.Colors.onFill : Theme.Colors.ink2)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
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
