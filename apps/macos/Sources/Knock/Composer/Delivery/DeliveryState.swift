import Foundation

/// The states a reply can be in after Send (docs/design/mvp-values.md §M8
/// `Egyj0`, panels 1-4; docs/protocol-mvp.md "Case and reply states").
/// `idle` is the implicit state before Send - show the normal composer, not
/// one of M8's panels. `sent` has no panel of its own (Amendment 1, KNOCK-13
/// fold): it is Panel 1's Sending-row style with different text, standing in
/// for "queued" until the real outcome arrives.
///
/// AC 8 ("A failed or unsent reply never shows the delivered style"): each
/// failure/pending case is its own enum case, never a flag alongside
/// `delivered` - a caller switching over `DeliveryState` cannot accidentally
/// paint the delivered style for `sent`, `offline` or `failed`.
enum DeliveryState: Equatable {
    case idle
    case sending
    /// `reply.submit`/`reply.retry` resolved to `queued`: the daemon has
    /// the reply, the agent has not fetched it yet. Shown in the same
    /// Sending-row style, without a check mark - AC 8 forbids showing this
    /// as delivered. `SendFlowController` treats it exactly like a
    /// successful send (closes the review workspace, calls `onSent()`);
    /// `DeliveryStateViewModel` never produces `.delivered` itself - only
    /// `AppModel` does, from a later `reply.state_changed` event.
    case sent
    /// Set only by `AppModel`, from a `reply.state_changed` event
    /// confirming the daemon wrote the payload to the shim and the shim
    /// acknowledged it (docs/protocol-mvp.md: "delivered ... never
    /// earlier"). Shown in the case pane and queue row, not the composer -
    /// by the time this arrives the review workspace has already closed.
    case delivered(at: Date)
    case offline
    /// The daemon answered `reply.submit` with an error (WAG-349): it refused the reply, so the socket is fine.
    /// `reason` is the daemon's message in plain words.
    case refused(reason: String)
    /// `replyId` is the daemon's id for the failed reply (docs/design/mvp-
    /// values.md §M8 panel 4: "mono id `reply_8f2a1c`") - shown so a human
    /// reporting a stuck case can name which reply is stuck.
    case failed(replyId: String)
}

extension DeliveryState {
    /// The case pane footer's collapsed Delivered line (docs/stories/
    /// HAIL-32.md state 3: "the footer collapses into a single line,
    /// 'Delivered ✓ HH:mm · your reply is with the agent', with no stale
    /// Sent line") - a pure formatter, now the status line's Delivered words (C10)
    /// so the exact copy is unit-testable without a SwiftUI host. `nil` for
    /// every case but `.delivered`.
    var footerDeliveredLine: String? {
        guard case .delivered(let at) = self else { return nil }
        return "Delivered ✓ \(KnockDateFormat.dateTime(from: at)) · your reply is with the agent"
    }
}
