import SwiftUI

/// The words for an agent session that a host closed while an ask or an answer was open (WAG-258,
/// waggle-releases issue 3). Plain and friendly, no em-dashes.
enum SessionClosedCopy {
    /// The calm notice under the case header while the ask still needs you.
    static let notice = "This agent's session has closed. Your answer is saved and reaches the agent when you next message it."
    /// The small mark on a queue row.
    static let mark = "Session closed"
    /// The reply state once the human answered a closed session.
    static let savedTitle = "Saved · delivers when the agent's session resumes"
    static let savedNote = "Your answer is saved. It reaches the agent when you next message it, or paste the copied answer in the agent's chat."

    /// The status strip's line for a closed session, from the real order of events.
    static func stripHeadline(for item: Case) -> String {
        if item.latestReplyState == .delivered { return "The session closed after it read your reply" }
        return item.closedBeforeReply
            ? "The session closed before you replied"
            : "The session closed before it read your reply"
    }
}

extension Case {
    /// An open ask whose session ended before the human answered.
    var sessionClosedBeforeAnswer: Bool {
        status == .needsYou && sessionState == .ended && !isDone
    }

    /// The session ended before the reply was written (true), or after it (false). Without both times
    /// the answer is false: the older copy then applies.
    var closedBeforeReply: Bool {
        guard let ended = sessionEndedAtDate, let replied = latestReplyAtDate else { return false }
        return replied >= ended
    }

    /// True when the queue row shows the "Session closed" mark: an open ask on an ended session, an
    /// answer saved for an ended session, or any failed reply (WAG-258 AC 1 and 5).
    var showsSessionClosedMark: Bool {
        guard status != .resolved, !isDone else { return false }
        switch status {
        case .needsYou: return sessionState == .ended
        case .waitingOnAgent: return latestReplyState == .failed || isStaleQueuedReply
        case .resolved: return false
        }
    }
}

/// Which part of the case pane draws a delivery outcome (WAG-258). One reply, one banner: a failed
/// outcome belongs to the pane's top banner, a delivered one to the footer. The composer never draws
/// either. This replaces three views that each read the same state and each drew a failed banner.
enum DeliveryBannerSlot: Equatable {
    case paneTop
    case footer

    static func slot(for state: DeliveryState?) -> DeliveryBannerSlot? {
        switch state {
        case .failed: return .paneTop
        case .delivered: return .footer
        case .idle, .sending, .sent, .offline, .refused, .none: return nil
        }
    }
}

/// The calm notice under the case header (WAG-258 AC 1).
struct SessionClosedNotice: View {
    var continueSession: ContinueInNewSessionModel
    var onContinue: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 12))
                .foregroundColor(Theme.Colors.ink3)
            VStack(alignment: .leading, spacing: 8) {
                Text(SessionClosedCopy.notice)
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                ContinueInNewSessionButton(model: continueSession, action: onContinue)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 32, bottom: 10, trailing: 32))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
        .accessibilityElement(children: .combine)
    }
}

/// The "Continue in a new session" button and what it says after the click (WAG-410).
struct ContinueInNewSessionButton: View {
    @ObservedObject var model: ContinueInNewSessionModel
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: action) {
                Text(model.phase == .starting ? ContinueInNewSessionCopy.starting : ContinueInNewSessionCopy.label)
                    .knockTextStyle(Theme.Typography.deliveryRetryLabel12w500)
                    .foregroundColor(Theme.Colors.win)
                    .padding(EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
                    .background(Theme.Colors.ink)
                    .cornerRadius(Theme.Radius.buttonSmall)
            }
            .buttonStyle(.plain).pointerCursor()
            .disabled(model.phase == .starting)
            switch model.phase {
            case .started:
                Text(ContinueInNewSessionCopy.started)
                    .knockTextStyle(Theme.Typography.caption11_5w400).foregroundColor(Theme.Colors.ink2)
            case .failed(let message):
                Text(message)
                    .knockTextStyle(Theme.Typography.caption11_5w400).foregroundColor(Theme.Colors.accent)
            case .idle, .starting:
                EmptyView()
            }
        }
    }
}
