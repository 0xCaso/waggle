import SwiftUI

/// The Delivered/Failed outcome banner (docs/design/mvp-values.md §M8
/// `Egyj0` panels 2 and 4) once the real outcome is known, either directly
/// from `reply.submit` (a session already ended at submit time - never
/// `.delivered`, only `.failed`, see `DeliveryStateViewModel`) or from a
/// later `reply.state_changed` event (Amendment 2, KNOCK-13 fold): `AppModel`
/// applies that outcome to the case pane and queue row, since the review
/// workspace has usually already closed by the time it arrives.
/// `DeliveryBannerView` renders the same two panels inline in the composer
/// for the synchronous-failure case.
struct DeliveryOutcomeBanner: View {
    let state: DeliveryState
    let onRetry: () -> Void
    /// HAIL-192: the one line to copy when the agent session is gone (the owning session ended).
    /// Set, it replaces Retry, which cannot work: the reply goes to the chat by hand.
    var copyLine: String? = nil
    /// WAG-295: the id `waggle_check` takes. Shown under the box in place of the reply id when the
    /// answer is a paste, so the operator can quote it.
    var caseId: String? = nil
    /// WAG-410: set when the session is gone. Shows "Continue in a new session" under the copy button.
    var continueSession: ContinueInNewSessionModel? = nil
    var onContinue: () -> Void = {}

    @State private var copied = false

    /// The line for a case whose session is gone, or nil while Retry can still work.
    static func copyLine(for item: Case) -> String? {
        item.sessionState == .ended ? ClaudeCheck.standaloneAnswer(for: item) : nil
    }

    var body: some View {
        switch state {
        case .delivered(let at):
            deliveredRow(at: at)
        case .failed(let replyId):
            failedBanner(replyId: replyId)
        case .idle, .sending, .sent, .offline, .refused:
            EmptyView()
        }
    }

    // MARK: - Panel 2 · Delivered (`PRJDc`)

    private func deliveredRow(at: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(Theme.Colors.ok)
            Text("Delivered ✓ \(KnockDateFormat.dateTime(from: at))")
                .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                .foregroundColor(Theme.Colors.ok)
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.okSoft)
        .cornerRadius(Theme.Radius.deliveryBanner)
    }

    // MARK: - Panel 4 · Failed (`cXBVL`)

    private func failedBanner(replyId: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Colors.accent)
                Text(copyLine != nil ? SessionClosedCopy.savedTitle : "Delivery failed · agent session unreachable")
                    .knockTextStyle(Theme.Typography.deliveryBannerTitle12w600)
                    .foregroundColor(Theme.Colors.accent)
            }
            if let copyLine {
                copyButton(line: copyLine)
                if let continueSession {
                    ContinueInNewSessionButton(model: continueSession, action: onContinue)
                }
                Text(SessionClosedCopy.savedNote)
                    .knockTextStyle(Theme.Typography.deliveryIdempotentNote11w400)
                    .foregroundColor(Theme.Colors.ink2)
            } else {
                retryButton
                Text("Retry sends this same reply once, never twice.")
                    .knockTextStyle(Theme.Typography.deliveryIdempotentNote11w400)
                    .foregroundColor(Theme.Colors.ink2)
            }
            Text(copyLine != nil && caseId != nil ? "case \(caseId!)" : replyId)
                .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.accentSoft)
        .cornerRadius(Theme.Radius.deliveryBanner)
    }

    // MARK: - Copy reply, in the Retry button's style (HAIL-192)

    private func copyButton(line: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
            Text(copied ? "Copied" : ClaudeCheck.copyReplyLabel)
                .knockTextStyle(Theme.Typography.deliveryRetryLabel12w500)
        }
        .foregroundColor(Theme.Colors.win)
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
        .background(Theme.Colors.ink)
        .cornerRadius(Theme.Radius.buttonSmall)
        .contentShape(Rectangle())
        .onTapGesture {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(line, forType: .string)
            copied = true
        }
    }

    // MARK: - Shared Retry button (`kmm7x`)

    private var retryButton: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11))
            Text("Retry")
                .knockTextStyle(Theme.Typography.deliveryRetryLabel12w500)
        }
        .foregroundColor(Theme.Colors.win)
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
        .background(Theme.Colors.ink)
        .cornerRadius(Theme.Radius.buttonSmall)
        .contentShape(Rectangle())
        .onTapGesture(perform: onRetry).pointerCursor()
    }
}
