import SwiftUI

/// The questions branch of the workspace's ask column (WAG-305, audit F2): the same step bar, question,
/// pick box and review step as the case pane, driven by the same `AskDocController` and `QuestionsDocModel`.
/// The DECIDE rows and the note sit in the dock below (`AskColumnQuestionsDock`).
struct AskColumnQuestionsBody: View {
    let knockCase: Case
    @ObservedObject var askDoc: AskDocController

    var body: some View {
        if let doc = askDoc.doc {
            let binding = Binding(get: { askDoc.doc ?? doc }, set: { askDoc.doc = $0 })
            if doc.isStepped {
                stepped(doc, binding)
            } else {
                ForEach(doc.questions) { question in
                    QuestionSectionView(
                        question: question, doc: binding, cards: [], selectedCardId: nil,
                        lastTarget: { askDoc.lastTarget(fullSize: $0) }, onOpen: { _, _ in })
                }
            }
        }
    }

    private func stepped(_ doc: QuestionsDocModel, _ binding: Binding<QuestionsDocModel>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            StepBarView(doc: binding)
            if let question = doc.currentQuestion {
                GroupHeadingView(title: question.groupTitle)
                Text(AgentMarkdown.singleLine(question.title))
                    .knockTextStyle(AskHeaderWidth.narrow.titleStyle)
                    .foregroundColor(Theme.Colors.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if doc.showsDocNeed {
                    NeedCalloutView(
                        need: knockCase.need, why: knockCase.why, isCompact: true, labelAbove: doc.sectionLabel(of: question))
                }
                QuestionSectionView(
                    question: question, doc: binding, cards: [], selectedCardId: nil,
                    lastTarget: { askDoc.lastTarget(fullSize: $0) }, onOpen: { _, _ in },
                    showsHeader: false, showsPoints: !DecisionDock.optionsInDock(.step), showsPicks: true)
            } else {
                Text("Send your \(doc.questions.count) decisions?")
                    .knockTextStyle(AskHeaderWidth.narrow.titleStyle)
                    .foregroundColor(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                ReviewStepView(doc: binding)
            }
        }
        .id(doc.step)
    }
}

/// The dock of that branch: the shared steps bar, which sends the same answers as the case pane.
struct AskColumnQuestionsDock: View {
    @ObservedObject var askDoc: AskDocController
    @ObservedObject var sendFlow: SendFlowController
    let columnHeight: CGFloat

    var body: some View {
        if let doc = askDoc.doc {
            AnswersBarView(
                doc: Binding(get: { askDoc.doc ?? doc }, set: { askDoc.doc = $0 }),
                sendFlow: sendFlow, deliveryState: sendFlow.deliveryState, isChanging: sendFlow.isEditingLockedAnswer,
                maxPointsHeight: AskPanelLayout.dockCap(columnHeight: columnHeight))
        }
    }
}
