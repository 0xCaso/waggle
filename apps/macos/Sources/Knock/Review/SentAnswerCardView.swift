import SwiftUI

/// The words of the "You picked" card (HAIL-86). Pure, so the copy is unit-tested.
enum SentAnswerCopy {
    /// What the operator sent: the label above it, the main line, and the note under it.
    struct Answer: Equatable {
        let label: String
        let title: String
        let note: String?
    }

    /// The chosen option as "1 · Compact", the message alone for a message-only reply, and the
    /// message as the note when there is a choice. "More detail" asks read "You asked".
    static func answer(for item: Case, reply: Reply? = nil) -> Answer {
        let message = item.latestReplyMessage.flatMap { $0.isEmpty ? nil : $0 }
        // A discuss reply (WAG-303) has no pick: show the leans and rule-outs, and the message under them.
        if item.latestReplyIntent == .discuss {
            let options = item.repliedOptions
            let lines = DiscussCopy.lines(
                leaning: DiscussCopy.titles(reply?.leaning, in: options), ruledOut: DiscussCopy.titles(reply?.ruledOut, in: options))
            return Answer(label: "YOU ARE TALKING IT OVER", title: lines.isEmpty ? "Talking it over" : lines.joined(separator: "\n"), note: message)
        }
        if item.latestReplyIntent == .moreDetail {
            return Answer(label: "YOU ASKED", title: message ?? "More detail", note: nil)
        }
        if !item.latestReplyChoices.isEmpty {
            // Several picks (HAIL-123): one line each, numbered by their place in the option list.
            let options = item.repliedOptions
            let lines = item.latestReplyChoices.map { id -> String in
                guard let index = options.firstIndex(where: { $0.id == id }) else { return id }
                return "\(index + 1) · \(options[index].displayTitle)"
            }
            return Answer(label: "YOU PICKED", title: lines.joined(separator: "\n"), note: message)
        }
        if let choice = item.latestReplyChoice {
            let options = item.repliedOptions
            let index = options.firstIndex { $0.id == choice }
            var title = index.map { "\($0 + 1) · \(options[$0].displayTitle)" } ?? choice
            if let words = item.latestReplyWithChangesWords { title = words }
            return Answer(label: "YOU PICKED", title: title, note: message)
        }
        return Answer(label: "YOU REPLIED", title: message ?? (reply?.attachments?.isEmpty == false ? "Sent files" : ""), note: nil)
    }

    /// HAIL-170: a case answered in the Claude app (no wake-up possible) labels the card "YOUR ANSWER".
    static func claudeApp(_ answer: Answer) -> Answer {
        answer.label == "YOU PICKED" || answer.label == "YOU REPLIED"
            ? Answer(label: "YOUR ANSWER", title: answer.title, note: answer.note) : answer
    }

    /// "sent 13:02", the footer's right side.
    static func sentLine(sentAt: Date?, timeZone: TimeZone = .current) -> String? {
        guard let sentAt else { return nil }
        return "sent \(AgentStatusCopy.clock(sentAt, timeZone: timeZone))"
    }
}

/// The one small line under the answer (WAG-267): how far the answer got. Pure, so each line is
/// unit-tested. Plain copy, no em-dashes.
enum ReplyApplyCopy {
    static let sent = "Sent"
    /// WAG-410: the failed reply went to a new session in its first message.
    static let handedOver = "Handed over to a new session. Your answer is in its first message."
    static let gotIt = "The agent got it"
    static let applied = "Applied"
    static let notApplied = "The agent got your answer but has not acted on it yet."

    enum Tone: Equatable { case quiet, good, attention }

    struct Line: Equatable {
        let text: String
        let tone: Tone
    }

    /// nil for a failed or superseded reply (the banner owns those) and for a case with no reply.
    /// `delivery` is the app's own fresher view of the send: a delivered one wins over a stale list row.
    static func line(for item: Case, delivery: DeliveryState? = nil) -> Line? {
        if let state = item.latestReplyState {
            switch state {
            case .failed, .superseded: return nil
            case .handedOver: return Line(text: handedOver, tone: .quiet)
            case .queued:
                if case .delivered? = delivery { return Line(text: gotIt, tone: .quiet) }
                return Line(text: sent, tone: .quiet)
            case .delivered:
                switch item.latestReplyApplyState ?? .pending {
                case .pending: return Line(text: gotIt, tone: .quiet)
                case .applied: return Line(text: applied, tone: .good)
                case .notApplied: return Line(text: notApplied, tone: .attention)
                }
            }
        }
        return nil
    }
}

/// The answer box once the answer is sent (HAIL-86, prototype tab D): what the operator picked,
/// the live status of the agent, and "Change answer". One card, so the split column shows the
/// status once.
struct SentAnswerCardView: View {
    let item: Case
    /// The full reply behind the card, for the leans and rule-outs of a discuss reply (WAG-303).
    var reply: Reply? = nil
    let delivery: DeliveryState?
    var settled: AnswerGrouping.Settled?
    let onChangeAnswer: () -> Void
    var onOpenCase: (String) -> Void = { _ in }
    /// The late-comments bar of a decided shared case (WAG-401), under the card.
    var lateBar: AnyView? = nil

    @Environment(\.nudge) private var nudge

    var body: some View {
        let status = AgentStatus.forCase(item, deliveryStatus: delivery)
        let fromClaudeApp = ClaudeCheck.appliesTo(item)
        let answer = fromClaudeApp
            ? SentAnswerCopy.claudeApp(SentAnswerCopy.answer(for: item, reply: reply)) : SentAnswerCopy.answer(for: item, reply: reply)
        VStack(alignment: .leading, spacing: 8) {
            card(answer: answer, status: status, fromClaudeApp: fromClaudeApp)
            lateBar
        }
    }

    @ViewBuilder
    private func card(answer: SentAnswerCopy.Answer, status: AgentStatus, fromClaudeApp: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(answer.label)
                .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                .foregroundColor(Theme.Colors.ink3)
            Text(answer.title)
                .knockTextStyle(Theme.Typography.value13_5w600)
                .foregroundColor(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 3)
            if let note = answer.note {
                AgentMarkdownText(text: note, style: Theme.Typography.replyNote13w400, color: Theme.Colors.ink2)
                    .padding(.top, 4)
            }
            SentAttachmentsView(files: reply?.attachments ?? []).padding(.top, 8)
            if !fromClaudeApp, let line = ReplyApplyCopy.line(for: item, delivery: delivery) {
                ReplyApplyLineView(line: line, item: item)
                    .padding(.top, 6)
            }
            Rectangle().fill(Theme.Colors.line).frame(height: 1).padding(.vertical, 10)
            if let settled {
                SettledAnswerLine(settled: settled, onOpenCase: onOpenCase)
            } else {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if let check = ClaudeCheck.state(for: item, delivery: delivery, now: context.date) {
                        ClaudeCheckView(item: item, state: check)
                    } else {
                        statusBlock(status: status, now: context.date)
                    }
                }
            }
            HStack {
                SecondaryOutlineButtonView(label: "Change answer", action: onChangeAnswer)
                Spacer(minLength: 8)
                if let sent = fromClaudeApp
                    ? ClaudeCheck.sentLine(sentAt: item.latestReplyAtDate)
                    : SentAnswerCopy.sentLine(sentAt: item.latestReplyAtDate) {
                    Text(sent)
                        .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
            }
            .padding(.top, 8)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.recommendedBlock)
    }

    /// The live status line, "read at" and the pickup fallback. A nudge does not change the
    /// headline or the waiting timer.
    @ViewBuilder
    private func statusBlock(status: AgentStatus, now: Date) -> some View {
        let runtime = item.runtimeLabel
        let woke = Nudge.wokeUp(item: item, record: nudge.records[item.id])
        let readAt: Date? = { if case .delivered(let at)? = delivery { return at }; return item.latestReplyDeliveredAtDate }()
        VStack(alignment: .leading, spacing: 8) {
            AgentStatusLine(
                status: status, cell: 5, label: label(status: status, runtime: runtime, now: now),
                since: since(status: status, now: now), labelFont: .sans(12.5), spacing: 10)
            if let read = AgentStatusCopy.readLine(readAt: readAt, afterNudge: woke) {
                Text(read)
                    .knockTextStyle(Theme.Typography.monoMeta11w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
            if status == .waitingForPickup {
                PickupFallbackView(item: item, style: .strip)
            }
        }
    }

    private func label(status: AgentStatus, runtime: String, now: Date) -> String {
        status.label
    }

    private func since(status: AgentStatus, now: Date) -> Date? {
        AgentStatus.timerStart(item, status: status, deliveryStatus: delivery)
    }
}

/// One line, under the answer. A "not acted on yet" line carries the existing pickup actions (copy
/// the prompt, show the terminal) when the session can use them.
struct ReplyApplyLineView: View {
    let line: ReplyApplyCopy.Line
    let item: Case

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line.text)
                .knockTextStyle(Theme.Typography.caption11_5w400)
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
            if line.tone == .attention {
                PickupFallbackView(item: item, style: .strip)
            }
        }
    }

    private var color: Color {
        switch line.tone {
        case .quiet: Theme.Colors.ink3
        case .good: Theme.Colors.ok
        case .attention: Theme.Colors.ink2
        }
    }
}
