import Foundation

/// Sends a reply and keeps it durable until the daemon confirms it
/// (docs/protocol-mvp.md `reply.submit`; AC: "A new idempotency key ...
/// reused for retries and offline re-submits", "kept locally ... and
/// re-submitted on reconnect with the same key").
///
/// One instance lives on `AppModel`, shared across every case's review
/// workspace, so a reconnect can resubmit a pending reply even for a case
/// whose workspace is not currently open.
///
/// HAIL-28 root cause: `send`'s only cleanup path used to be `store.remove`
/// running after `await client.replySubmit(...)` returned. `KnockClient.call`
/// had no timeout, so a request whose response never arrived (a stalled
/// socket, or a reconnect racing the in-flight request) left that `await`
/// suspended forever - even though the daemon had already processed and
/// delivered the reply on its side. The pending file, and every later
/// `resubmitPending()` behind it in `AppModel.onConnected` (itself awaited
/// before `subscribeEvents()`/`refreshCases()`), hung with it. The fix here
/// is threefold: every request is now bounded (`KnockClient`'s own
/// timeouts), a resubmit no longer blocks `onConnected`'s own list/events
/// path at all (it runs as a detached background task), and `resubmitOne`
/// can now also clean up a reply that plainly already landed - from
/// `AppModel`'s own fresh `cases.list`, at no extra round trip - without
/// depending on that one `reply.submit` call ever resolving cleanly.
@MainActor
final class SendCoordinator {
    private let client: KnockClient
    private let store: PendingReplyStore
    /// Overrides `reply.submit`'s own timeout for a live send. Tests only:
    /// lets a timeout test finish in milliseconds instead of 10 s.
    private let submitTimeout: Duration?
    /// Called once the daemon holds a reply, from a live send and from a reconnect resubmit (WAG-358).
    var onDelivered: ((PendingReply) -> Void)?
    /// The built-in sample request answers here and nowhere else: when set, `send` saves nothing, never
    /// calls the daemon and never touches the network. It returns the reply this closure builds.
    private let localDelivery: ((PendingReply) -> Reply)?

    /// A coordinator for the sample request: Decide is delivered to this process only.
    static func local(client: KnockClient, onAnswered: @escaping (PendingReply) -> Void = { _ in }) -> SendCoordinator {
        SendCoordinator(client: client, localDelivery: { reply in
            onAnswered(reply)
            return SampleRequest.localReply(for: reply)
        })
    }

    private init(client: KnockClient, localDelivery: @escaping (PendingReply) -> Reply) {
        self.client = client
        self.store = PendingReplyStore(environment: ["KNOCK_HOME": NSTemporaryDirectory() + "waggle-sample-unused"])
        self.submitTimeout = nil
        self.localDelivery = localDelivery
    }

    init(client: KnockClient, store: PendingReplyStore = PendingReplyStore(), submitTimeout: Duration? = nil) {
        self.client = client
        self.store = store
        self.submitTimeout = submitTimeout
        self.localDelivery = nil
    }

    /// The idempotency key this case's next send should use: an
    /// already-pending reply's key when this case has one queued (a retry,
    /// or the app restarted while offline), otherwise a fresh UUID.
    func idempotencyKey(for caseId: String) -> String {
        store.load(caseId: caseId)?.idempotencyKey ?? UUID().uuidString
    }

    /// Saves `reply` locally before attempting delivery, so it survives even
    /// if the app quits mid-send, then removes it once the daemon confirms
    /// the reply - either a freshly `queued`/`failed` result, or the
    /// existing reply `reply.submit` returns when `idempotencyKey` was
    /// already used (docs/protocol-mvp.md: "reply.submit with an existing
    /// idempotency_key returns the existing reply"; both respond the same
    /// way here, so both clear the pending copy). Throws (without removing
    /// the saved copy) when the socket is unreachable or the request times
    /// out; the caller shows that as "not sent".
    ///
    /// `timeout` overrides `KnockClient.replySubmit`'s own default only for
    /// `resubmitOne`'s reconnect path (see Choices ledger) - a live,
    /// human-initiated send always uses the client's normal 10s/30s rule.
    @discardableResult
    func send(_ reply: PendingReply, timeout: Duration? = nil) async throws -> Reply {
        // WAG-349: a saved reply with an out-of-range rect is repaired here, on Retry and on the reconnect resubmit.
        let reply = reply.withClampedRects()
        if let localDelivery { return localDelivery(reply) }
        try store.save(reply)
        let result = try await client.replySubmit(
            caseId: reply.caseId,
            idempotencyKey: reply.idempotencyKey,
            choice: reply.choice,
            optionsSet: reply.optionsSet,
            message: reply.message,
            comments: reply.comments,
            captures: reply.captures,
            intent: reply.intent,
            choices: reply.choices,
            answers: reply.answers,
            itemAnswers: reply.itemAnswers,
            format: reply.format,
            edit: reply.editRevision.map(ReplyEditRef.init),
            leaning: reply.leaning,
            ruledOut: reply.ruledOut,
            attachments: reply.attachments,
            timeout: timeout ?? submitTimeout
        )
        store.remove(caseId: reply.caseId)
        onDelivered?(reply)
        return result
    }

    /// After `send` timed out, asks the daemon whether the reply landed
    /// anyway (operator, 4 Oct: a 17.8 MB reply was delivered to the agent
    /// while the banner still said "Sending your answer"). A timeout only
    /// means the response did not arrive in time; the daemon may have
    /// stored the reply, or may still be storing it, so this checks
    /// `cases.list` a few times. When the case already holds an answer,
    /// the saved copy is dropped and this returns true. Otherwise the copy
    /// stays for Retry or the next reconnect, which reuse the same key.
    func landedAfterTimeout(
        _ reply: PendingReply, attempts: Int = 3, spacing: Duration = .seconds(2)
    ) async -> Bool {
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(for: spacing) }
            guard let cases = try? await client.casesList() else { continue }
            if let item = cases.first(where: { $0.id == reply.caseId }), isAlreadyAnswered(item) {
                store.remove(caseId: reply.caseId)
                return true
            }
        }
        return false
    }

    /// Resubmits every reply still saved locally, reusing each one's own
    /// idempotency key (so the daemon never creates a second reply for it).
    /// Called from a background task on `KnockClient` reconnect (`AppModel`),
    /// never awaited by `onConnected` itself (AC: "never blocks the list,
    /// the events or open(caseId:)").
    ///
    /// `knownCases` is `AppModel`'s own `cases.list` result from the
    /// `refreshCases()` that already ran this reconnect (empty when called
    /// without one, e.g. from a unit test): a pending reply whose case is
    /// already known to be answered is dropped without ever calling
    /// `reply.submit` again, at no extra round trip - see `isAlreadyAnswered`.
    func resubmitPending(knownCases: [Case] = []) async {
        // `uniquingKeysWith` rather than `uniqueKeysWithValues:` - `AppModel`
        // passes `needsYouCases + waitingOnAgentCases`, and this must never
        // crash even if a caller's two lists briefly overlap (they are not
        // expected to, but nothing here depends on that holding).
        let caseById = Dictionary(knownCases.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for reply in store.loadAll() {
            await resubmitOne(reply, knownCase: caseById[reply.caseId])
        }
    }

    /// Bounded to 15s (AC): this is what stopped the operator's stuck resend
    /// - see the Choices ledger entry on why `send`'s own success path
    /// (`store.remove` after `await client.replySubmit` returns) was never
    /// enough by itself. A timeout or any other non-`-32001` failure leaves
    /// the pending file queued for the next reconnect; `-32001` ("case not
    /// found") means the case is gone, so there is nothing left to resend.
    private func resubmitOne(_ reply: PendingReply, knownCase: Case?) async {
        if let knownCase, isAlreadyAnswered(knownCase) {
            store.remove(caseId: reply.caseId)
            return
        }
        do {
            _ = try await send(reply, timeout: .seconds(15))
        } catch let error as JSONRPCErrorPayload where error.code == -32001 {
            store.remove(caseId: reply.caseId)
        } catch {
            // Left queued; the next reconnect's resubmitPending() retries it.
        }
    }

    /// True when `item` already carries the answer a pending reply for it
    /// would otherwise resend: no longer `needs_you` (a reply moved it on),
    /// and a `latest_reply_id` is actually set - `needs_you` with neither is
    /// the normal "never sent yet" state, which must still resubmit.
    private func isAlreadyAnswered(_ item: Case) -> Bool {
        switch item.status {
        case .waitingOnAgent, .resolved:
            return item.latestReplyId != nil
        case .needsYou:
            return false
        }
    }
}
