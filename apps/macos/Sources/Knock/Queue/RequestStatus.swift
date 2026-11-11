import AppKit
import SwiftUI

/// The request's status as one line in the context line (C10, spec 2026-11-09 section 8). It replaces the delivery
/// banners, the session-closed notice, the agent status strip and the done strip. A button shows only when there is
/// something to do. Pure, so each state is tested without a view.
enum RequestStatus {
    /// What a button on the line does. The page wires each one to the same call the old banner made.
    enum Action: Equatable, Hashable {
        case retry
        case copyAnswer
        case viewReview
        case openReview
        case changeAnswer
        case continueInNewSession
        case gotIt
        case openFollowUp(caseId: String)

        var label: String {
            switch self {
            case .retry: "Retry"
            case .copyAnswer: ClaudeCheck.copyReplyLabel
            case .viewReview: "View review"
            case .openReview: "Open review"
            case .changeAnswer: "Change answer"
            case .continueInNewSession: ContinueInNewSessionCopy.label
            case .gotIt: "Got it"
            case .openFollowUp: "Open the follow-up"
            }
        }
    }

    enum Kind: Equatable {
        /// The agent finished and needs no answer.
        case done
        /// The service was offline when Send was pressed: the reply is saved on this Mac.
        case notSent
        /// The service or the agent session refused or could not take the reply.
        case notDelivered
        /// The agent's session ended: the answer waits for it, or goes to a new session.
        case saved
        /// The session closed while the ask still needs you.
        case sessionClosed
        case sending
        /// Sent, waiting for the agent to pick it up.
        case sent
        /// The agent has the reply and works on it.
        case working
        /// The session closed while the reply waited.
        case closed
        /// Answered long ago: when the agent picked it up, and its follow-up.
        case settled
        case delivered
        /// The failed reply went to a new session (WAG-410).
        case handedOver
    }

    enum Tone: Equatable {
        case neutral
        case ok
        /// A live agent status, drawn with its grid (and a timer when the line has `since`).
        case agent(AgentStatus)
        /// Red icon and red text on a soft red fill (C10): the reason must be easy to see and read.
        case failed
    }

    struct Line: Equatable {
        var kind: Kind
        /// The words, bold for a failure: "Not delivered".
        var text: String
        /// The reason or the longer words after the text, in full (they wrap, never cut).
        var reason: String? = nil
        /// Small text after the words: "read at 16:05".
        var meta: String? = nil
        /// The tooltip: the reply or case id, or what the line means.
        var help: String? = nil
        var tone: Tone = .neutral
        /// Starts the line's timer.
        var since: Date? = nil
        var actions: [Action] = []
        /// The pickup fallback (Copy prompt, Nudge, Show the terminal) in a ⋯ menu.
        var hasMoreMenu = false
        /// A failure stays until Retry works or the person hides it.
        var canHide = false

        /// The same line without the buttons a place cannot wire (full size has no "Continue in a new session").
        func keeping(only allowed: Set<Action>) -> Line {
            var copy = self
            copy.actions = actions.filter { allowed.contains($0) }
            return copy
        }

        /// Every word the line shows, for VoiceOver and the tests.
        var spoken: String { [text, reason, meta].compactMap { $0 }.joined(separator: " · ") }
    }

    struct Input {
        var item: Case
        /// `AppModel.deliveryStatusByCaseId[case]`: the outcome the service confirmed.
        var confirmed: DeliveryState? = nil
        /// The page's own send (`SendFlowController.deliveryState`): sending, or not sent and why.
        var local: DeliveryState = .idle
        var isEditingLockedAnswer = false
        var settled: AnswerGrouping.Settled? = nil
        var pickup: PickupFallback.Kind = .none
        /// The timer start of the agent's status (the pickup, else the send).
        var since: Date? = nil
        var readAt: Date? = nil
        /// The person hid this failure; it does not show again until a new one comes.
        var isHidden = false
        /// The agent woke up after a nudge: the read line says so.
        var wokeAfterNudge = false
    }

    /// The line to copy when the agent's session is gone (HAIL-192): "Copy answer" puts it on the clipboard. `nil`
    /// while Retry can still work.
    static func copyLine(for item: Case) -> String? {
        item.sessionState == .ended ? ClaudeCheck.standaloneAnswer(for: item) : nil
    }

    static let savedOnMac = "Your reply is saved on this Mac."
    static let unreachable = "The agent session is unreachable. Retry sends this same reply once, never twice."
    static let hideLabel = "Hide this message"

    /// The one status line of the request, or `nil` when there is nothing to say.
    static func line(_ input: Input) -> Line? {
        let item = input.item
        if item.isDone {
            return Line(
                kind: .done, text: "Done · \(item.runtimeLabel) finished and needs no answer", tone: .ok, actions: [.gotIt])
        }
        if input.isEditingLockedAnswer { return nil }
        if let failure = failure(input) {
            return input.isHidden && failure.canHide ? nil : failure
        }
        if item.sessionClosedBeforeAnswer {
            return Line(
                kind: .sessionClosed, text: "Session closed", reason: SessionClosedCopy.notice,
                actions: [.continueInNewSession])
        }
        if input.local == .sending {
            return Line(kind: .sending, text: "Sending your answer", tone: .agent(.waitingForPickup))
        }
        if item.status == .waitingOnAgent || input.local == .sent {
            if let waiting = waiting(input) { return waiting }
        }
        if case .delivered(let at)? = input.confirmed, item.replyLockState == .delivered {
            return Line(
                kind: .delivered, text: DeliveryState.delivered(at: at).footerDeliveredLine ?? "Delivered ✓", tone: .ok,
                actions: item.kind == .review ? [.copyAnswer, .viewReview] : [.copyAnswer])
        }
        if item.latestReplyState == .handedOver {
            return Line(kind: .handedOver, text: ReplyApplyCopy.handedOver)
        }
        return nil
    }

    /// The line for the page's own send alone (sending, not sent and why), for the full-size column, whose
    /// answer box has no context line of its own above it.
    static func localLine(_ state: DeliveryState, item: Case) -> Line? {
        switch state {
        case .idle, .delivered: return nil
        case .sending, .offline, .refused, .failed:
            return line(Input(item: item, local: state))
        case .sent:
            return Line(kind: .sent, text: "Sent · waiting for the agent", tone: .agent(.waitingForPickup))
        }
    }

    /// A reply that did not reach the agent: red, with the reason and Retry, until it works or is hidden.
    private static func failure(_ input: Input) -> Line? {
        let item = input.item
        switch input.local {
        case .offline:
            return Line(
                kind: .notSent, text: "Not sent", reason: "The Waggle service is offline. \(savedOnMac)",
                tone: .failed, actions: [.retry], canHide: true)
        case .refused(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let because = trimmed.isEmpty ? "Waggle refused the reply." : "Waggle refused the reply: \(trimmed)"
            return Line(
                kind: .notDelivered, text: "Not delivered", reason: "\(because) \(savedOnMac)",
                tone: .failed, actions: [.retry], canHide: true)
        default:
            break
        }
        var replyId: String?
        if case .failed(let id) = input.local { replyId = id }
        if item.status == .waitingOnAgent, case .failed(let id)? = input.confirmed { replyId = id }
        if replyId == nil, item.replyLockState == .failed { replyId = item.latestReplyId ?? "" }
        guard let replyId else { return nil }
        if copyLine(for: item) != nil {
            // The session is gone, so Retry cannot work: the answer waits, or goes by hand or to a new session.
            // Red like a failure (operator, 10 Nov): the answer has not reached the agent yet.
            return Line(
                kind: .saved, text: SessionClosedCopy.savedTitle, reason: SessionClosedCopy.savedNote,
                help: "case \(item.id)", tone: .failed, actions: [.copyAnswer, .continueInNewSession])
        }
        if item.sessionState == .live, input.local == .idle {
            // The session came back (often under a new id): the service hands this reply to the agent at its next
            // check (HAIL-192), so it is not an error. Retry stays for an agent that does not check again.
            return Line(
                kind: .saved, text: SessionClosedCopy.resumedTitle, reason: SessionClosedCopy.resumedNote,
                help: replyId.isEmpty ? nil : "reply \(replyId)", tone: .agent(.waitingForPickup), actions: [.retry], canHide: true)
        }
        return Line(
            kind: .notDelivered, text: "Not delivered", reason: unreachable,
            help: replyId.isEmpty ? nil : "reply \(replyId)", tone: .failed, actions: [.retry], canHide: true)
    }

    /// The reply is with the service or the agent: waiting for pickup, worked on, or the session closed.
    private static func waiting(_ input: Input) -> Line? {
        let item = input.item
        let status = input.local == .sent && item.status != .waitingOnAgent
            ? .waitingForPickup : AgentStatus.forCase(item, deliveryStatus: input.confirmed)
        let runtime = item.runtimeLabel
        let more = input.pickup != .none
        if let settled = input.settled, AgentStatusCopy.headline(status: status, runtime: runtime) != nil {
            return Line(
                kind: .settled, text: AgentStatusCopy.settledLine(pickedUpAt: settled.pickedUpAt),
                help: settled.followUp.map(AgentStatusCopy.followUpLine), tone: .agent(.closed),
                actions: settled.followUp.map { [.openFollowUp(caseId: $0.id)] } ?? [])
        }
        switch status {
        case .waitingForPickup:
            var actions: [Action] = []
            if item.replyLockState == .queued { actions.append(.changeAnswer) }
            if item.kind == .review { actions.append(.openReview) }
            return Line(
                kind: .sent,
                text: item.isWaitingOnMoreDetail ? "Asked for more detail · waiting for the agent" : "Sent · waiting for the agent",
                tone: .agent(.waitingForPickup), since: input.since ?? item.latestReplyAtDate, actions: actions,
                hasMoreMenu: more)
        case .working, .writingToYou:
            return Line(
                kind: .working, text: AgentStatusCopy.headline(status: status, runtime: runtime, item: item) ?? runtime,
                meta: AgentStatusCopy.readLine(readAt: input.readAt, afterNudge: input.wokeAfterNudge),
                tone: .agent(status), since: input.since,
                actions: item.kind == .review && item.replyLockState == .delivered ? [.viewReview] : [],
                hasMoreMenu: more)
        case .closed:
            var actions: [Action] = []
            if item.latestReplyState != .delivered {
                if copyLine(for: item) != nil { actions.append(.copyAnswer) }
                actions.append(.continueInNewSession)
            }
            return Line(
                kind: .closed, text: SessionClosedCopy.stripHeadline(for: item), tone: .agent(.closed),
                actions: actions, hasMoreMenu: more)
        case .needsYou, .connected:
            return nil
        }
    }
}

/// Failures the person hid on the status line (C10), for this run of the app. A hidden failure stays in the
/// queue row with its Retry. It is hidden only while it lasts: Retry, or any line that is not a failure
/// (sending, sent, delivered), shows the case's next failure again, even with the same reason.
@MainActor
final class HiddenStatusStore: ObservableObject {
    static let shared = HiddenStatusStore()
    @Published private(set) var keys: Set<String> = []

    static func key(caseId: String, line: RequestStatus.Line) -> String { "\(caseId)|\(line.kind)|\(line.reason ?? "")|\(line.help ?? "")" }

    func isHidden(_ key: String) -> Bool { keys.contains(key) }
    func hide(_ key: String) { keys.insert(key) }
    /// Follows the case's status line: when it stops being a failure, the next failure is a new one and shows.
    func follow(caseId: String, failing: Bool) {
        if !failing { showAgain(caseId: caseId) }
    }

    /// Forgets the case's hidden failures: after a Retry, and when its failure ends.
    func showAgain(caseId: String) { keys = keys.filter { !$0.hasPrefix("\(caseId)|") } }
}

/// The status line (C10): an icon or the agent's grid, the words, the reason in full, and the buttons when there is
/// something to do. It is one line when it fits; else the buttons go under the words, and the words wrap: a
/// reason is never cut. A failure is red on a soft red fill, with a button to hide it.
struct RequestStatusLineView: View {
    let line: RequestStatus.Line
    /// The case, for the ⋯ menu of the pickup fallback.
    var item: Case? = nil
    /// "Continue in a new session" shows what it is doing, as before (WAG-410).
    var continueSession: ContinueInNewSessionModel? = nil
    let onAction: (RequestStatus.Action) -> Void
    var onHide: (() -> Void)? = nil

    @State private var copied = false

    private var isFailed: Bool { line.tone == .failed }
    /// Delivered reads in the pro green, as mockup B's "✓ Round 1 delivered 15:01".
    private var textColor: Color {
        if isFailed { return Theme.Colors.statusFailedText }
        return line.tone == .ok ? Theme.AskDoc.Colors.pro : Theme.Colors.ink
    }
    private var reasonColor: Color { isFailed ? Theme.Colors.statusFailedText : Theme.Colors.ink2 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                words(wraps: false)
                Spacer(minLength: 8)
                controls
                hide
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    words(wraps: true)
                    Spacer(minLength: 0)
                    hide
                }
                if hasControls { HStack(spacing: 8) { controls } }
            }
        }
        .padding(isFailed ? EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 8) : EdgeInsets())
        .background {
            if isFailed { RoundedRectangle(cornerRadius: Theme.Radius.deliveryBanner).fill(Theme.Colors.statusFailedFill) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(OptionalHelp(text: line.help))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(line.spoken)
        .accessibilityIdentifier("request-status")
    }

    private var hasControls: Bool { !line.actions.isEmpty || (line.hasMoreMenu && item != nil) }

    @ViewBuilder
    private func words(wraps: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            icon
            text
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: wraps)
                .textSelection(.enabled)
            if let since = line.since, case .agent = line.tone { ElapsedTimer(since: since) }
            if let meta = line.meta {
                Text(meta)
                    .knockTextStyle(Theme.Typography.monoMeta11w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// Inter Tight, as the rest of the column (STYLE-AUDIT rule 4): 12.5, 500 (600 when failed, 400 delivered as
    /// in mockup B); the reason 400.
    private var text: Text {
        let column = Theme.AskDoc.Column.self
        let weight: NSFont.Weight = isFailed ? .semibold : (line.tone == .ok ? .regular : .medium)
        var words = Text(line.text)
            .font(column.font(12.5, weight))
            .foregroundColor(textColor)
        if let reason = line.reason {
            words = words + Text(" · ").font(column.font(12.5)).foregroundColor(reasonColor) + Text(reason)
                .font(column.font(12.5))
                .foregroundColor(reasonColor)
        }
        return words
    }

    @ViewBuilder
    private var icon: some View {
        switch line.tone {
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12.5))
                .foregroundColor(Theme.Colors.statusFailedText)
        case .ok:
            Text("✓")
                .font(Theme.AskDoc.Column.font(12.5, .semibold))
                .foregroundColor(Theme.AskDoc.Colors.pro)
        case .agent(let status):
            PixelStatusGrid(pattern: status.pattern, color: status.color, cell: 4)
                .centredOnXHeight(of: 12.5)
        case .neutral:
            Image(systemName: neutralSymbol)
                .font(.system(size: 12))
                .foregroundColor(Theme.Colors.ink3)
        }
    }

    private var neutralSymbol: String {
        switch line.kind {
        case .sessionClosed: "moon.zzz"
        case .saved: "tray.and.arrow.down"
        case .handedOver: "arrow.uturn.forward.circle"
        default: "info.circle"
        }
    }

    @ViewBuilder
    private var controls: some View {
        ForEach(line.actions, id: \.self) { action in button(action) }
        if line.hasMoreMenu, let item { PickupFallbackView(item: item, style: .menu) }
    }

    @ViewBuilder
    private var hide: some View {
        if line.canHide, let onHide {
            Button(action: onHide) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.Colors.statusFailedText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(RequestStatus.hideLabel)
            .accessibilityLabel(RequestStatus.hideLabel)
            .accessibilityIdentifier("request-status-hide")
        }
    }

    @ViewBuilder
    private func button(_ action: RequestStatus.Action) -> some View {
        if action == .continueInNewSession, let continueSession {
            ContinueInNewSessionButton(model: continueSession) { onAction(action) }
        } else {
            let primary = action == .retry || action == .gotIt
            let label = action == .copyAnswer && copied ? "Copied" : action.label
            Button {
                if action == .copyAnswer {
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(4)); copied = false }
                }
                onAction(action)
            } label: {
                // The case map's `.pill.closed button`: 600, underlined text. Retry and Got it stay a filled button.
                HStack(spacing: 5) {
                    if action == .retry { Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .semibold)) }
                    if primary {
                        Text(label).knockTextStyle(Theme.AskDoc.Column.status)
                    } else {
                        Text(label).knockTextStyle(Theme.AskDoc.Column.statusFailed).underline()
                    }
                }
                .foregroundColor(primary ? Theme.Colors.onFill : (isFailed ? Theme.Colors.statusFailedText : Theme.Colors.ink))
                .padding(primary ? EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10) : EdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2))
                .background(RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall).fill(primary ? Theme.Colors.ink : Color.clear))
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .accessibilityLabel(label)
        }
    }
}

/// A tooltip only when there is one to give.
private struct OptionalHelp: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}
