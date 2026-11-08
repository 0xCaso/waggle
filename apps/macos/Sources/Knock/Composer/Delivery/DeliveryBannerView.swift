import SwiftUI

/// The reply bubble's line. Never "You:" with nothing after it (HAIL-147).
enum DeliveryBubbleCopy {
    static func text(for summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return "You: \(trimmed.isEmpty ? "your reply" : trimmed)"
    }
}

/// The M8 delivery banner (docs/design/mvp-values.md §M8 `Egyj0`, panels
/// 1-4): replaces the composer input while a reply is sending, or once it
/// cannot be shown as delivered (AC 8) - offline or failed, both of which
/// need an explicit, safe Retry instead of a text field to type into.
struct DeliveryBannerView: View {
    let state: DeliveryState
    /// The REPLY value being sent, e.g. "Go with A. Two fixes:" - shown in
    /// the locked reply bubble (`Bfg84` and its Panel 2-4 equivalents) so the
    /// human can see what is (or was) being sent while the composer itself
    /// is replaced by this banner.
    let replySummary: String
    /// False when the options stay on show above the banner (WAG-306).
    var showsReply = true
    let onRetry: () -> Void
    /// Starts the "waiting for pickup" timer of the sent row (the moment the
    /// row first shows when the caller passes nothing).
    var sentAt: Date?
    /// False in the case pane: its top banner owns a failed outcome, so the composer never draws a
    /// second one for the same reply (WAG-258, `DeliveryBannerSlot`).
    var showsFailure = true

    @State private var shownAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsReply { replyBubble }
            switch state {
            case .idle:
                EmptyView()
            case .sending:
                sendingRow
            case .sent:
                sentRow
            case .delivered:
                DeliveryOutcomeBanner(state: state, onRetry: onRetry)
            case .failed:
                if showsFailure { DeliveryOutcomeBanner(state: state, onRetry: onRetry) }
            case .offline:
                offlineBanner
            case .refused(let reason):
                refusedBanner(reason: reason)
            }
        }
    }

    // MARK: - Reply bubble (`P6oot` and Panel 2-4 equivalents)

    private var replyBubble: some View {
        HStack(spacing: 6) {
            Text(DeliveryBubbleCopy.text(for: replySummary))
                .knockTextStyle(Theme.Typography.deliverySoftNote11_5w400)
                .foregroundColor(Theme.Colors.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if state == .sending {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Colors.ink3)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.deliveryReplyBubble)
    }

    // MARK: - Panel 1 · Sending (`mhQbH`)

    private var sendingRow: some View {
        HStack(spacing: 8) {
            LoadingStatus(label: "Sending your answer", labelFont: .labelStrong)
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.deliveryBanner)
    }

    // MARK: - Sent, queued (Amendment 1, KNOCK-13 fold - same recipe as
    // Panel 1's Sending row, no panel id of its own: `reply.submit`
    // resolved to `queued`, not yet confirmed delivered - AC 8 forbids the
    // check-mark style for this.)

    private var sentRow: some View {
        HStack(spacing: 8) {
            AgentStatusLine(
                status: .waitingForPickup, cell: 4, label: "Sent · waiting for the agent to pick it up",
                since: sentAt ?? shownAt, labelFont: .labelStrong, spacing: 8)
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.deliveryBanner)
    }

    // MARK: - Panel 3 · Offline (`alW2Q`)

    private var offlineBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Colors.accent)
                Text("Not sent · Waggle service is offline")
                    .knockTextStyle(Theme.Typography.deliveryBannerTitle12w600)
                    .foregroundColor(Theme.Colors.accent)
            }
            Text("Your reply is saved on this Mac.")
                .knockTextStyle(Theme.Typography.deliverySoftNote11_5w400)
                .foregroundColor(Theme.Colors.ink2)
            retryButton
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.accentSoft)
        .cornerRadius(Theme.Radius.deliveryBanner)
    }

    // MARK: - Refused (WAG-349): the service is up, and it said no

    private func refusedBanner(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Colors.accent)
                Text("Not sent · Waggle refused the reply")
                    .knockTextStyle(Theme.Typography.deliveryBannerTitle12w600)
                    .foregroundColor(Theme.Colors.accent)
            }
            Text("Reason: \(reason)")
                .knockTextStyle(Theme.Typography.deliverySoftNote11_5w400)
                .foregroundColor(Theme.Colors.ink2)
            Text("Your reply is saved on this Mac.")
                .knockTextStyle(Theme.Typography.deliverySoftNote11_5w400)
                .foregroundColor(Theme.Colors.ink2)
            retryButton
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.accentSoft)
        .cornerRadius(Theme.Radius.deliveryBanner)
    }

    // MARK: - Offline's own Retry button (`oFeUb`) - `DeliveryOutcomeBanner`
    // has the Failed panel's equivalent (`kmm7x`), same visual, since the
    // two banners no longer share a body here.

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

/// The case pane footer once `AppModel.deliveryStatusByCaseId` has confirmed
/// an outcome for a question ask (docs/stories/HAIL-32.md "One state
/// source"): `CasePaneDetailView` shows this instead of `ComposerFooterView`
/// once that dictionary names this case, so the footer can never disagree
/// with the pane's own top banner (`DeliveryOutcomeBanner`, driven by the
/// same dictionary) - the operator report this fixes was exactly that
/// disagreement (a confirmed Delivered banner at the top, a footer still
/// reading its own stale, never-updated `sendFlow.deliveryState`).
///
/// Delivered collapses to the one line AC 3 asks for, with no reply bubble
/// above it - "the footer collapses into a single line". Failed stays
/// exactly `DeliveryOutcomeBanner`'s existing panel (AC 4: "unchanged").
struct CaseFooterConfirmedView: View {
    let state: DeliveryState
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .delivered(let at):
            deliveredCollapsedRow(at: at)
        case .failed:
            // The pane's top banner owns a failed outcome (`DeliveryBannerSlot`).
            EmptyView()
        case .idle, .sending, .sent, .offline, .refused:
            EmptyView()
        }
    }

    private func deliveredCollapsedRow(at: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(Theme.Colors.ok)
            Text(state.footerDeliveredLine ?? "")
                .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                .foregroundColor(Theme.Colors.ok)
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.okSoft)
        .cornerRadius(Theme.Radius.deliveryBanner)
    }
}
