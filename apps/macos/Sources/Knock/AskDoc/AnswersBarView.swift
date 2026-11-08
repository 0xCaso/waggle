import SwiftUI

/// The bottom bar of an ask with questions: "N answered", the note field and "Send N answers" (prototype
/// `.dock`). A note with no answer sends as "Send feedback" (WAG-285). It never shows the options of a simple ask: each point sits on the page.
struct AnswersBarView: View {
    @Binding var doc: QuestionsDocModel
    @ObservedObject var sendFlow: SendFlowController
    @ObservedObject var deliveryState: DeliveryStateViewModel
    /// "Change answer" is open: the bar sends through `reply.replace`, and the label says so.
    var isChanging = false
    /// The tallest the points of a step get before they scroll inside the bar (about 40% of the window).
    var maxPointsHeight: CGFloat = DecisionDock.minCap
    @State private var pointsHeight: CGFloat = 0
    @State private var isNoteFocused = false

    var body: some View {
        let _ = EvidenceLayoutLog.bump("body.answersBar")
        VStack(spacing: 0) {
            if deliveryState.state == .idle {
                if doc.isStepped, let question = doc.currentQuestion { stepPoints(question) }
                ObservedFiles(files: sendFlow.composer.files) { _ in promptBar }
            } else {
                DeliveryBannerView(
                    state: deliveryState.state, replySummary: sendFlow.deliveryReplySummary,
                    onRetry: { Task { await sendFlow.retryDelivery() } })
                    .padding(14)
            }
        }
        .boundedIdealWidth()
        .background(Theme.Colors.win.shadow(Theme.Shadow.dockUp))
        .overlay(Rectangle().fill(Theme.Colors.line2).frame(height: 1), alignment: .top)
        .onAppear {
            // Evidence only (WAG-330): `KNOCK_EVIDENCE_DRAFT_TEXT=<text>` fills the note, so a capture shows "Ask".
            if let text = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_DRAFT_TEXT"], !text.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if doc.note.isEmpty { doc.note = text } }
            }
            EvidenceWindowSnapshot.scheduleIfRequested(delay: 5)
        }
        .background { if !doc.isLocked { stepShortcuts } }
    }

    /// The keys of the single dock, on the current point of the step (WAG-334). Cmd-Return sends as before; Cmd-D
    /// and the digits pick on the page and send nothing; Return moves a step on when a tick is made.
    private var stepShortcuts: some View {
        let ticked = doc.keyPoint.map { $0.point.select == .many && !doc.draft($0.question.id, $0.point.id).choices.isEmpty } ?? false
        return DockShortcutsView(
            isAskingForDetail: sendFlow.composer.isAskingForDetail, isTextFocused: isNoteFocused,
            returnActs: doc.isStepped && ticked,
            onAccept: { if doc.isStepped { doc.acceptRecommendation() } },
            onSend: { if canSend { send() } },
            onPick: { if doc.isStepped { doc.pick(position: $0) } },
            onReturn: { if doc.nextLabel != nil { doc.next() } },
            onAskForDetail: { if doc.showsAskForDetail { sendFlow.composer.beginAskingForDetail() } })
    }

    /// The points of the current step and their options, in the bar so a choice never needs a scroll (WAG-291).
    /// Past the cap the bar scrolls inside itself and the page does not.
    private func stepPoints(_ question: Question) -> some View {
        let content = StepPointsView(question: question, doc: $doc, sendFlow: sendFlow, composer: sendFlow.composer)
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 0, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
        return ScrollView {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { EvidenceLayoutLog.event("answers.pointsHeight", "old=\(pointsHeight) new=\($0)"); pointsHeight = $0 }
        }
        .frame(height: min(max(pointsHeight, 1), maxPointsHeight))
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The shared prompt bar (WAG-305): "+" attach, the note and the primary button. On a step the button is
    /// Next and "Back" is a quiet button; on the review step, or on the one-page document, it sends.
    private var promptBar: some View {
        let stepping = doc.isStepped && doc.nextLabel != nil
        let comments = sendFlow.pinnedCommentCount
        return PromptBarCore(
            text: $doc.note,
            placeholder: PromptBarLogic.placeholder(.steps),
            maxLines: PromptBarLogic.paneMaxLines,
            quietLabels: PromptBarLogic.answersQuietLabels(doc: doc, comments: comments),
            pillLabels: PromptBarLogic.answersPillLabels(doc: doc, comments: comments),
            canSend: stepping || canSend,
            // Return never moves a step on or decides; it sends a typed question (WAG-330).
            returnSends: stepping ? doc.stepTalksNow : nil,
            keepsArrow: !stepping && comments > 0,
            onQuiet: { label in
                if label == PromptBarLogic.backLabel { doc.back() } else if label == doc.nextLabel { doc.next() }
            },
            onSend: { if stepping && !doc.stepTalksNow(comments: comments) { doc.next() } else { send() } },
            files: sendFlow.composer.files,
            isFocused: $isNoteFocused)
    }

    private var canSend: Bool { doc.canSend(comments: sendFlow.pinnedCommentCount, hasFiles: sendFlow.composer.hasFiles) }

    private func send() {
        guard canSend else { return }
        let message = doc.message
        if doc.usesItems, !doc.sendsAnswers, message != nil || doc.isDiscussing {
            // Keep talking: the note, with the answers, leans and rule-outs given so far (WAG-330).
            sendFlow.sendItemDiscuss(
                leaning: doc.leaningIds, ruledOut: doc.ruledOutIds, message: message, itemAnswers: doc.itemAnswers())
        } else if doc.sendsDiscuss {
            sendFlow.sendItemDiscuss(leaning: doc.leaningIds, ruledOut: doc.ruledOutIds, message: message)
        } else if !doc.sendsAnswers {
            // Pinned comments alone go with a fixed message, so the daemon always has one (WAG-287). So do files alone.
            sendFlow.sendFeedback(
                message: message ?? (sendFlow.pinnedCommentCount > 0
                    ? QuestionsDocModel.commentsOnlyMessage : QuestionsDocModel.filesOnlyMessage))
        } else if doc.usesItems {
            sendFlow.sendItemAnswers(doc.itemAnswers(), message: message)
        } else {
            sendFlow.sendAnswers(doc.answers(), message: message)
        }
        doc.markSent()
    }
}

/// Re-draws its content when the files of the next reply change (WAG-345): `sendFlow.composer.files` is two
/// objects down, so the bar cannot observe it through `sendFlow`.
private struct ObservedFiles<Content: View>: View {
    @ObservedObject var files: ComposerAttachments
    @ViewBuilder let content: (ComposerAttachments) -> Content

    var body: some View { content(files) }
}

/// The points of one step in the bar (WAG-304): "DECIDE · n", the rows of each point and, as the last row,
/// "Ask for more detail" as on a single decision. It opens the same panel and sends a `more_detail` reply.
struct StepPointsView: View {
    let question: Question
    @Binding var doc: QuestionsDocModel
    let sendFlow: SendFlowController
    @ObservedObject var composer: ComposerViewModel

    private var about: String? { doc.isStepped ? AgentMarkdown.singleLine(question.title) : nil }

    var body: some View {
        if composer.isAskingForDetail {
            AskForDetailPanelView(
                composer: composer, onSend: { sendFlow.askForMoreDetail(about: about) },
                onSendFormat: { sendFlow.askForMoreDetail(format: $0, about: about) })
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // A lone point reads like a single decision: no "DECIDE" label (WAG-326).
                if question.points.count > 1 {
                    Text(QuestionsDocModel.toDecideLabel(question))
                        .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                        .foregroundColor(Theme.Colors.honey600)
                }
                ForEach(Array(question.points.enumerated()), id: \.element.id) { index, point in
                    ItemRowsView(
                        number: index + 1, point: point, questionId: question.id, pointCount: question.points.count,
                        doc: $doc, inBar: true)
                }
                if doc.showsAskForDetail {
                    Rectangle().fill(Theme.Colors.line).frame(height: 1)
                    AskForDetailRowView(
                        composer: composer, onSend: { sendFlow.askForMoreDetail(about: about) },
                        onSendFormat: { sendFlow.askForMoreDetail(format: $0, about: about) })
                }
            }
        }
    }
}
