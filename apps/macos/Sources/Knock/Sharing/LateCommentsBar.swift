import AppKit
import SwiftUI

/// The words and rules of the late-comments bar (WAG-401). A late comment is a team comment that came after the
/// last decide answer. Pure, so the copy is unit-tested. Plain copy, no em-dashes.
enum LateCommentsCopy {
    static let changeAnswer = "Change answer"
    static let send = "Send to the agent"
    static let copyPrompt = "Copy prompt"
    static let sent = "Sent to the agent"
    static let copied = "Copied"
    static let closedLine = "The agent's session is closed. Paste this in a new session."

    /// "1 comment since you decided", "3 comments since you decided".
    static func barText(count: Int) -> String {
        count == 1 ? "1 comment since you decided" : "\(count) comments since you decided"
    }

    enum SendMode: Equatable { case send, copy }

    /// A live session gets the prompt. A closed one, or one that could not take it, gets "Copy prompt".
    static func sendMode(sessionState: SessionState?, sendFailed: Bool) -> SendMode {
        if sendFailed { return .copy }
        return sessionState == .live ? .send : .copy
    }

    static func sendLabel(_ mode: SendMode) -> String { mode == .send ? send : copyPrompt }

    /// The one prompt. It names the case and the title, says the comments are input and not an answer, and sends the
    /// agent to waggle_check. It never holds the comment text.
    static func prompt(caseId: String, title: String) -> String {
        let clean = title.replacingOccurrences(of: "\"", with: "'")
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let short = clean.count > 120 ? String(clean.prefix(119)) + "\u{2026}" : clean
        return "Waggle: your team commented on \"\(short)\" (case \(caseId)) after the human decided. "
            + "These are team comments, input and not an answer. Call waggle_check with case_id \(caseId) to read them."
    }
}

/// Sends the late-comments prompt to the newest live session of the case's task. True when it was sent.
enum LateCommentsSend {
    static func toSession(client: KnockClient, item: Case) -> (String) async -> Bool {
        { text in
            guard let sessions = try? await client.sessionsList(),
                  let session = sessions.filter({ $0.taskId == item.taskId && $0.state == .live })
                      .max(by: { $0.connectedAt < $1.connectedAt }),
                  let result = try? await client.sessionSendPrompt(sessionId: session.id, text: text)
            else { return false }
            return result.sent
        }
    }
}

/// The bar on a decided shared case with late comments. Shows nothing when there are none.
struct LateCommentsBarView: View {
    @ObservedObject var sharing: SharingModel
    let item: Case
    let onChangeAnswer: () -> Void
    /// Sends the prompt to the case's session. True when it was sent.
    let sendPrompt: (String) async -> Bool
    /// False where the card above already has its own Change answer (the review window).
    var showsChangeAnswer = true

    @State private var failed = false
    @State private var busy = false
    @State private var copied = false

    var body: some View {
        let late = sharing.lateComments
        if late.count > 0 {
            let mode = LateCommentsCopy.sendMode(sessionState: item.sessionState, sendFailed: failed)
            VStack(alignment: .leading, spacing: 8) {
                Text(LateCommentsCopy.barText(count: late.count))
                    .knockTextStyle(Theme.Typography.value13_5w600)
                    .foregroundColor(Theme.Colors.ink)
                HStack(spacing: 8) {
                    if showsChangeAnswer {
                        SecondaryOutlineButtonView(label: LateCommentsCopy.changeAnswer, action: onChangeAnswer)
                    }
                    if late.new == 0 {
                        Text(LateCommentsCopy.sent)
                            .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                            .foregroundColor(Theme.Colors.ok)
                    } else {
                        SecondaryOutlineButtonView(
                            label: copied ? LateCommentsCopy.copied : LateCommentsCopy.sendLabel(mode),
                            action: { act(mode) })
                            .opacity(busy ? 0.5 : 1)
                    }
                }
                if late.new > 0, mode == .copy {
                    Text(LateCommentsCopy.closedLine)
                        .knockTextStyle(Theme.Typography.caption11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.honeySoft)
            .cornerRadius(Theme.Radius.recommendedBlock)
        }
    }

    private func act(_ mode: LateCommentsCopy.SendMode) {
        guard !busy else { return }
        let text = LateCommentsCopy.prompt(caseId: item.id, title: item.title)
        if mode == .copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
            return
        }
        busy = true
        Task {
            let ok = await sendPrompt(text)
            busy = false
            if ok { await sharing.markLateGiven() } else { failed = true }
        }
    }
}
