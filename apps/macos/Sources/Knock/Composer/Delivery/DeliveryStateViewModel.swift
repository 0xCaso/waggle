import Foundation

/// Drives the M8 delivery banner (docs/design/mvp-values.md §M8 `Egyj0`,
/// requirements `Ufy4A`) from the outcome of `SendCoordinator.send` and
/// `KnockClient.replyRetry`. Owned by `SendFlowController`, one per case's
/// review workspace.
///
/// `reply.submit`/`reply.retry` only ever resolve synchronously to `queued`
/// (shown as `.sent`) or, when the owning session had already ended,
/// `failed` (daemon/src/store.ts `insertReply`/`submitReply`) -  `delivered`
/// is set later, asynchronously, once the shim acknowledges the payload
/// (docs/protocol-mvp.md: "delivered is set only when the daemon has
/// written the payload to the shim and the shim acknowledged it ... never
/// earlier"). By the time that confirmation can arrive, `SendFlowController`
/// has already closed the review workspace (`onSent()` fires as soon as
/// `.sent` comes back - see `SendFlowControllerTests`), so this view model
/// never produces `.delivered` itself. `AppModel` applies it later, from a
/// `reply.state_changed` event, for the case pane and queue row (Amendment
/// 2, KNOCK-13 fold) - the earlier "optimistic delivered" choice here was
/// rejected: it broke AC 8 by showing Delivered for a reply nobody had
/// confirmed, if the agent's session ended right after submit.
@MainActor
final class DeliveryStateViewModel: ObservableObject {
    @Published private(set) var state: DeliveryState = .idle

    private let coordinator: SendCoordinator
    private let client: KnockClient?
    /// The reply last handed to `send`, kept so `retry()` can re-submit it
    /// with the same idempotency key when it never reached the daemon at all
    /// (docs/protocol-mvp.md: "the app keeps the unsent reply locally ...
    /// re-submits with the same key").
    private var lastAttempt: PendingReply?

    init(coordinator: SendCoordinator, client: KnockClient?) {
        self.coordinator = coordinator
        self.client = client
    }

    /// M8 AC 6: "Lock the reply while it is sending" - true while `sending`
    /// and `sent` (about to leave the review workspace); `offline`/`failed`
    /// show Retry instead of a composer, so they are "locked" the same way
    /// by simply having no text field to type into. `delivered` is included
    /// only for exhaustiveness - see the type's doc comment, this view model
    /// never sets it itself.
    var isLocked: Bool {
        switch state {
        case .sending, .sent, .delivered: true
        case .idle, .offline, .refused, .failed: false
        }
    }

    func reset() {
        state = .idle
        lastAttempt = nil
    }

    /// Sends `reply`, moving `state` from `sending` to its outcome. Never
    /// throws: a thrown submit becomes `.offline` (the reply is already
    /// saved locally by `SendCoordinator.send` by the time this returns).
    /// A timeout first checks whether the daemon got the reply anyway, and
    /// shows `.sent` when it did, never a false "offline".
    @discardableResult
    func send(_ reply: PendingReply) async -> DeliveryState {
        lastAttempt = reply
        state = .sending
        // `KNOCK_EVIDENCE_HOLD_SENDING=1` (HAIL-147 evidence): stays on the Sending banner so it can be captured.
        if ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_HOLD_SENDING"] == "1" {
            try? await Task.sleep(for: .seconds(3600))
        }
        do {
            let result = try await coordinator.send(reply)
            state = Self.outcome(for: result)
        } catch KnockClient.ClientError.timeout {
            state = await coordinator.landedAfterTimeout(reply) ? .sent : .offline
        } catch let error as JSONRPCErrorPayload {
            // The daemon answered with an error: it refused the reply, so the service is not offline (WAG-349).
            // A bare "Internal error" hides the cause, so the banner shows the daemon's own words (WAG-358).
            let reason = error.code == -32603 ? (error.cause ?? error.message) : error.message
            state = .refused(reason: Self.plainReason(reason))
        } catch {
            state = .offline
        }
        return state
    }

    /// The daemon's message as one plain line for the "Not sent" banner.
    static func plainReason(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "The service gave no reason." }
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "..." : trimmed
    }

    /// M8's Retry action: `reply.retry` when the reply reached the daemon
    /// and was later marked failed, or a plain re-submit (the same
    /// idempotency key, via `send`) when it never reached the daemon at all
    /// (docs/protocol-mvp.md "Case and reply states": "On reconnect it
    /// re-submits with the same key" - the same rule applies to a manual
    /// Retry while still offline). Either path reuses one key, so the
    /// daemon's idempotency check makes a duplicate reply impossible
    /// (docs/design/mvp-values.md §M8: "Retry sends this same reply once,
    /// never twice").
    @discardableResult
    func retry() async -> DeliveryState {
        switch state {
        case .offline, .refused:
            guard let lastAttempt else { return state }
            return await send(lastAttempt)
        case .failed(let replyId):
            guard let client else { return state }
            state = .sending
            do {
                let result = try await client.replyRetry(replyId: replyId)
                state = Self.outcome(for: result)
            } catch {
                state = .failed(replyId: replyId)
            }
            return state
        case .idle, .sending, .sent, .delivered:
            return state
        }
    }

    /// `queued` (the only outcome `reply.submit`/`reply.retry` return short
    /// of a synchronous failure) becomes `.sent`, never `.delivered` - AC 8.
    private static func outcome(for reply: Reply) -> DeliveryState {
        reply.state == .failed ? .failed(replyId: reply.id) : .sent
    }

    /// "Change answer" while the reply is still queued (docs/stories/
    /// HAIL-34.md, operator decision on case c_c548e66e…): calls
    /// `reply.replace` under the same reply id, never `reply.submit` - there
    /// is no local-durability/offline-resubmit path here the way `send` has,
    /// since a replace only ever applies to a reply the daemon already has.
    /// Resets to `.idle` on failure (most notably the daemon's own rejection
    /// once the reply has already been delivered) so the composer reappears
    /// rather than getting stuck on `.sending`; the caller surfaces the
    /// thrown error as its own message.
    func replace(
        replyId: String, choice: String?, optionsSet: String? = nil, message: String?, comments: [Comment],
        captures: [Capture], choices: [String]? = nil, answers: [PointAnswer]? = nil, itemAnswers: [ItemAnswer]? = nil,
        editRevision: Int? = nil, attachments: [ReplyAttachmentInput]? = nil
    ) async throws -> DeliveryState {
        guard let client else { throw ReplyReplaceError.noClient }
        state = .sending
        do {
            let result = try await client.replyReplace(
                replyId: replyId, choice: choice, optionsSet: optionsSet, message: message, comments: comments,
                captures: captures, choices: choices, answers: answers, itemAnswers: itemAnswers,
                edit: editRevision.map(ReplyEditRef.init), attachments: attachments
            )
            state = Self.outcome(for: result)
            return state
        } catch {
            state = .idle
            throw error
        }
    }
}

/// Thrown by `DeliveryStateViewModel.replace` when this view model was built
/// without a `KnockClient` - every real call site (the case pane, the review
/// workspace) always provides one; only a test omitting it would ever see
/// this.
enum ReplyReplaceError: Error {
    case noClient
}
