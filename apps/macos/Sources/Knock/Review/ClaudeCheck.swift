import AppKit
import SwiftUI

/// "Claude is not checking" (HAIL-170). In the Claude app and Cowork, Knock cannot wake Claude, so
/// an answer waits until Claude calls knock_check. This is the pure state machine and the reply line.
enum ClaudeCheck {
    /// How long after the answer, with no knock_check since, Claude counts as not checking.
    static let notCheckingAfter: TimeInterval = 120

    enum State: Equatable {
        /// Sent, and Claude has had less than 2 minutes.
        case waiting
        /// 2 minutes with no knock_check since the answer: show the Copy reply card.
        case notChecking
        /// Claude fetched the answer.
        case pickedUp
    }

    /// Only a Claude case whose session cannot be nudged, answered and not closed. A Claude Code case
    /// (can_nudge true), a Codex case and a case with an unknown session never get these states.
    static func appliesTo(_ item: Case) -> Bool {
        guard item.isDesktopClient else { return false }
        guard item.status == .waitingOnAgent, !item.isDone, item.latestReplyAtDate != nil else { return false }
        if let session = item.sessionState, session != .live { return false }
        return item.latestReplyState != .failed
    }

    /// The state of one answered case, or nil when the states do not apply.
    static func state(for item: Case, delivery: DeliveryState? = nil, now: Date) -> State? {
        guard appliesTo(item), let answeredAt = item.latestReplyAtDate else { return nil }
        var delivered = item.latestReplyState == .delivered
        if case .delivered? = delivery { delivered = true }
        if delivered { return .pickedUp }
        let checkedSince = item.lastCheckAtDate.map { $0 > answeredAt } ?? false
        if !checkedSince, now.timeIntervalSince(answeredAt) >= notCheckingAfter { return .notChecking }
        return .waiting
    }

    /// The last line of the standalone paste: how an agent with Waggle tools marks the answer delivered.
    static let pasteHint = "If your Waggle tools are connected, call waggle_check with this case_id to mark it delivered."

    /// The text the operator pastes into the chat (WAG-295): the ask title, the case_id and the answer
    /// body the daemon formats for waggle_check, so an agent without Waggle tools still gets the answer.
    /// The body comes from the daemon (`latestReplyAnswerText`); there is no second formatter here.
    static func standaloneAnswer(for item: Case) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = title.isEmpty
            ? "My Waggle answer (case \(item.id)):"
            : "My Waggle answer to \"\(title)\" (case \(item.id)):"
        let body = item.latestReplyAnswerText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [head, body.isEmpty ? replyLine(for: item) : body, pasteHint].joined(separator: "\n")
    }

    /// The short fallback body when the daemon sent no answer text (an older daemon): choice titles
    /// (joined by commas for several picks), or a plain line when the reply has none.
    static func replyLine(for item: Case) -> String {
        let options = item.repliedOptions
        var ids = item.latestReplyChoices
        if ids.isEmpty, let choice = item.latestReplyChoice { ids = [choice] }
        let titles = ids.map { id -> String in
            let title = options.first { $0.id == id }?.displayTitle ?? id
            return title.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
        }.filter { !$0.isEmpty }
        if titles.isEmpty { return "I answered your Waggle question in Waggle. Continue." }
        return "I answered your Waggle question: \(titles.joined(separator: ", ")). Continue."
    }

    static func copyReply(for item: Case) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(standaloneAnswer(for: item), forType: .string)
    }

    static let waitingLabel = "Waiting for Claude to pick it up"
    static let pickedUpLabel = "Claude picked up your answer"
    static let notCheckingTitle = "Claude is not checking Waggle"
    static func notCheckingBody(for item: Case) -> String {
        ClientName.isCowork(item.sessionClientName)
            ? "In Cowork, Claude does not see your answer until you tell it. Paste this in your Cowork task:"
            : "In the Claude app, Claude does not see your answer until you tell it. Paste this in the chat:"
    }
    static let notCheckingFoot = "It goes away when Claude checks again."
    /// The row and strip headline (HAIL-173): the same fallback as the card, in one short line.
    static let notCheckingShort = "Claude is not checking"
    static let copyReplyLabel = "Copy answer"
    /// Names the place to paste: Cowork, the Claude chat, or both when the client is unknown (HAIL-186).
    static func copiedLine(for item: Case) -> String {
        if ClientName.isCowork(item.sessionClientName) { return "Copied. Paste it in your Cowork task." }
        if let name = item.sessionClientName, !name.isEmpty { return "Copied. Paste it in the Claude chat." }
        return "Copied. Paste it in your Claude chat or Cowork task."
    }
    /// The footer of the sent card for these cases.
    static func sentLine(sentAt: Date?, timeZone: TimeZone = .current) -> String? {
        guard let sentAt else { return nil }
        return "Sent to Claude app · \(AgentStatusCopy.clock(sentAt, timeZone: timeZone))"
    }
}

/// The three states under the sent answer card (HAIL-170, knock.pen band "Claude is not checking, Copy reply").
struct ClaudeCheckView: View {
    let item: Case
    let state: ClaudeCheck.State
    @State private var copied = false

    var body: some View {
        switch state {
        case .waiting:
            row(fill: Theme.Colors.side) {
                Circle().fill(Theme.Colors.ink3).frame(width: 7, height: 7)
                Text(ClaudeCheck.waitingLabel)
                    .font(.custom(Theme.FontFamily.sans, size: 13)).foregroundColor(Theme.Colors.ink2)
            }
        case .pickedUp:
            row(fill: Theme.Colors.okSoft) {
                Text("✓").font(.custom(Theme.FontFamily.sans, size: 13).weight(.medium)).foregroundColor(Theme.Colors.ok)
                Text(ClaudeCheck.pickedUpLabel)
                    .font(.custom(Theme.FontFamily.sans, size: 13).weight(.medium)).foregroundColor(Theme.Colors.ok)
            }
        case .notChecking:
            VStack(alignment: .leading, spacing: 8) {
                Text(ClaudeCheck.notCheckingTitle)
                    .font(.custom(Theme.FontFamily.sans, size: 14).weight(.semibold)).foregroundColor(Theme.Colors.accent)
                Text(ClaudeCheck.notCheckingBody(for: item))
                    .font(.custom(Theme.FontFamily.sans, size: 13)).foregroundColor(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ClaudeCheck.standaloneAnswer(for: item))
                    .font(.custom(Theme.FontFamily.mono, size: 12)).foregroundColor(Theme.Colors.ink)
                    .textSelection(.enabled)
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Colors.win)
                    .cornerRadius(7)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Colors.line, lineWidth: 1))
                HStack(spacing: 10) {
                    Button(action: copy) {
                        Text(copied ? "Copied" : ClaudeCheck.copyReplyLabel)
                            .font(.custom(Theme.FontFamily.sans, size: 12.5).weight(.semibold)).foregroundColor(Theme.Colors.onFill)
                            .padding(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
                            .background(Theme.Colors.ink)
                            .cornerRadius(Theme.Radius.buttonSmall)
                    }
                    .buttonStyle(.plain).pointerCursor()
                    Text(copied ? ClaudeCheck.copiedLine(for: item) : ClaudeCheck.notCheckingFoot)
                        .font(.custom(Theme.FontFamily.sans, size: 12)).foregroundColor(Theme.Colors.ink3)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.accentSoft)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Colors.accent, lineWidth: 1))
        }
    }

    private func row<Content: View>(fill: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .cornerRadius(Theme.Radius.buttonSmall)
    }

    private func copy() {
        ClaudeCheck.copyReply(for: item)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(4))
            copied = false
        }
    }
}
