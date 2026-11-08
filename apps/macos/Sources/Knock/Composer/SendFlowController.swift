import AppKit
import Combine
import Foundation

/// Orchestrates one case's send action end to end: decides whether Send
/// needs the review-before-send step first (docs/design/mvp-values.md §M6 -
/// "With comments present, Send first shows the review step"), builds the
/// reply payload, and hands it to `SendCoordinator`.
///
/// Owned by `ReviewWorkspaceView` (one instance per case, alongside
/// `ComposerViewModel` and `CommentsSessionStore`).
@MainActor
final class SendFlowController: ObservableObject {
    @Published private(set) var isReviewingBeforeSend = false
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    /// One capture that will be sent, with its own annotated thumbnail and
    /// comments (HAIL-35 fold: the review step must summarize EVERY capture
    /// the payload sends, not only the one currently selected on the stage).
    struct CaptureReviewSummary: Identifiable {
        let capture: CaptureRecord
        let comments: [Comment]
        let thumbnail: NSImage?
        var id: String { capture.id }
    }
    /// Built once, when the review step opens (docs/design/mvp-values.md
    /// §M6 thumbnail) - not recomputed on every SwiftUI body pass. Every
    /// capture that has at least one comment, oldest first, same set
    /// `ReplyPayloadBuilder` sends an image for.
    @Published private(set) var capturesForReview: [CaptureReviewSummary] = []
    /// "Change answer" (docs/stories/HAIL-34.md, operator decision on case
    /// c_c548e66e…): true once the operator has asked to edit an already-
    /// queued reply, put back by `beginChangingAnswer()`. While true, the
    /// case pane and the review workspace both show the normal composer/
    /// options again (unlocked) even though the case itself is still
    /// answer-locked - `confirmSend` reads `replaceReplyId` to send through
    /// `reply.replace` instead of `reply.submit`.
    @Published private(set) var isEditingLockedAnswer = false

    /// The person's in-place edit of the document, attached to the reply (HAIL-168). Remove drops
    /// it from the reply; the revision stays in the case's history.
    struct AttachedEdit: Equatable {
        let revision: Int
        let baseRevision: Int
        let passagesChanged: Int
    }
    @Published private(set) var attachedEdit: AttachedEdit?

    func attachEdit(_ edit: AttachedEdit) { attachedEdit = edit }
    func removeEdit() { attachedEdit = nil }

    let composer: ComposerViewModel
    private(set) var knockCase: Case
    /// The case's replies so far (docs/stories/HAIL-34.md, operator decision
    /// via Knock on case c_656dc5ce…): `beginChangingAnswer()` looks the
    /// current one up here by id to restore its comments/captures. Empty for
    /// the case pane's own `SendFlowController` (Non-goal: the pane never
    /// comments), which never calls `beginChangingAnswer()` for a review-kind
    /// ask anyway (docs/stories/HAIL-34.md: "opens the workspace instead").
    private let replies: [Reply]
    /// The M8 delivery banner (docs/design/mvp-values.md §M8 `Egyj0`):
    /// sending/delivered/offline/failed, replacing the composer once Send is
    /// pressed. `client` is optional so existing call sites (and every
    /// pre-KNOCK-13 test) that construct a `SendFlowController` without one
    /// keep compiling; a nil client only means a failed reply's Retry cannot
    /// call `reply.retry` (the offline re-submit path does not need it).
    let deliveryState: DeliveryStateViewModel

    private let usage: UsageReporter?
    private let commentsStore: CommentsSessionStore
    private var commentsObserver: AnyCancellable?
    private let coordinator: SendCoordinator
    private let onSent: () -> Void
    /// `AppModel.advanceAfterSend` (Contract "Next ask"), called only where
    /// a successful send is an actual decision reply going out for the
    /// first time this round: `confirmSend`'s `.sent` case and `retryDelivery`'s
    /// success (a composer-level offline/failed retry that finally lands).
    /// Never called from `confirmReplace` ("Change answer" on an
    /// already-queued reply - by the time that can run, the case already
    /// left `needsYouCases`, so `AppModel`'s own guard would no-op it
    /// anyway, but this keeps the intent explicit) or from
    /// `confirmAskForMoreDetail` (Contract: "Not after 'Ask for more
    /// detail' - stay on the same ask").
    private let onAnswerSent: (String) -> Void

    private var pendingChoice: String?
    /// The ticked ids of a select "many" ask (HAIL-123); `nil` for a single choice.
    private var pendingChoices: [String]?
    private var pendingOptionsSet: String?
    private var pendingMessage: String?
    /// The answers of a multi-question ask (WAG-257); `nil` for any other reply.
    private var pendingAnswers: [PointAnswer]?
    /// The answers by item id (WAG-315): a request with items, or a single item with a pick.
    private var pendingItemAnswers: [ItemAnswer]?
    /// Set while a discuss reply is the one in flight (WAG-301): the ids leaned to and ruled out.
    private var pendingDiscuss: (leaning: [String], ruledOut: [String])?
    /// Set while an "Ask for more detail" request is the reply in flight (HAIL-147).
    private var pendingMoreDetail: (format: ReplyFormat?, message: String?)?
    /// Non-nil while `send`/`acceptRecommendation` should replace an
    /// existing queued reply rather than submit a new one - set by
    /// `beginChangingAnswer()`, cleared once that replace succeeds.
    private var replaceReplyId: String?

    /// Where "Change answer" fetches capture images from (PERF-2); nil in tests with no client.
    private let captureClient: KnockClient?

    init(
        knockCase: Case,
        commentsStore: CommentsSessionStore,
        coordinator: SendCoordinator,
        client: KnockClient? = nil,
        revisionArrival: RevisionArrival? = nil,
        replies: [Reply] = [],
        /// Shared with the case pane (docs/stories/HAIL-25.md: "the pane and
        /// the review share one draft per case") - `.shared` by default so a
        /// selection made in the pane is already applied the moment this
        /// controller's own `ComposerViewModel` is built.
        draftStore: ComposerDraftStore = .shared,
        usage: UsageReporter? = nil,
        onSent: @escaping () -> Void,
        onAnswerSent: @escaping (String) -> Void = { _ in },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.knockCase = knockCase
        self.replies = replies
        self.composer = ComposerViewModel(
            knockCase: knockCase, revisionArrival: revisionArrival, draftStore: draftStore, usage: usage)
        self.usage = usage
        self.commentsStore = commentsStore
        self.coordinator = coordinator
        // WAG-358: comments an earlier reply already carried are answered, not pending.
        commentsStore.dropSent(commentIds: Set(replies.filter { $0.state == .delivered }.flatMap { $0.comments.map(\.id) }))
        self.captureClient = client
        self.deliveryState = DeliveryStateViewModel(coordinator: coordinator, client: client)
        self.onSent = onSent
        self.onAnswerSent = onAnswerSent
        // The answers bar counts the pinned comments (WAG-285), so a pin or a removal redraws it.
        commentsObserver = commentsStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // `KNOCK_REVIEW_STEP=send` (Amendments): opens the review-before-send
        // step directly, since the orchestrator cannot send the Send action
        // itself. A seeded draft/comments is fine to skip per the
        // amendment - this only needs the screen to render, the operator's
        // own manual run covers a real reply.
        if environment["KNOCK_REVIEW_STEP"] == "send" {
            isReviewingBeforeSend = true
        }
    }

    /// An update changed the case under the open pane (HAIL-108): the composer
    /// must offer the newest options, not the ones it was built with.
    func refreshCase(_ updated: Case) {
        guard updated != knockCase else { return }
        knockCase = updated
        composer.refresh(updated)
    }

    private var hasComments: Bool { !commentsStore.model.comments.isEmpty }

    /// How many comments are pinned on the artifact now; they go with the reply.
    var pinnedCommentCount: Int { commentsStore.model.comments.count }

    /// True while the operator has something typed or open that an auto move would
    /// cost them (HAIL-118): a note, a "Something else" detail, a comment being written
    /// or already added, or a Change answer edit.
    var hasUnsentWork: Bool {
        !composer.draftText.isEmpty || composer.isAskingForDetail || !composer.detailQuestionText.isEmpty
            || isEditingLockedAnswer || commentsStore.draftPin != nil || hasComments || attachedEdit != nil || composer.hasFiles
    }

    /// "Accept recommendation ⌘D" / "Send recommended answer ⌘D"
    /// (docs/design/mvp-values.md §M7 panels A/B): the recommendation
    /// itself, bypassing whatever the free-text field holds.
    func acceptRecommendation(via source: AcceptSource = .button) {
        usage?.record(.recommendationAccepted, source: source.rawValue)
        begin(
            choice: composer.recommendationChoice, choices: composer.recommendationChoices, optionsSet: nil,
            message: composer.recommendationMessage,
            itemAnswers: ReplyPayloadBuilder.itemAnswers(for: knockCase, choice: composer.recommendationChoice, choices: composer.recommendationChoices))
    }

    /// True for a single-choice ask with comments pinned and no row picked or leaned to. A plan round's
    /// pre-pick is no pick (WAG-328), so comments over it keep the talk going.
    var sendsReviewComments: Bool { composer.supportsDiscuss && !composer.hasPick && !composer.isDiscussing && hasComments }

    /// The composer's own Send action: the selected option (if any) plus
    /// whatever is typed.
    func send() {
        // Nothing but a pre-pick is nothing to send: Enter and ⌘↵ never decide for the person (WAG-328).
        if composer.isOptionsCase, !composer.hasPick, !composer.isDiscussing, composer.currentMessage == nil,
           !hasComments, attachedEdit == nil, !isEditingLockedAnswer, !composer.hasFiles { return }
        // Leans, rule-outs, or a note with no pick: the human has not decided (WAG-301).
        // A review with comments and no row picked is Keep talking too: the review stays open (WAG-316, Q3).
        if composer.sendsDiscuss || sendsReviewComments {
            begin(
                choice: nil, optionsSet: nil, message: composer.currentMessage,
                discuss: (composer.leaningIds, composer.ruledOutIds))
            return
        }
        // A pick-many ask with nothing ticked is not an answer, not even "none of these": a note or comments keep
        // the talk going (WAG-329).
        if composer.talksOnMany {
            begin(choice: nil, optionsSet: nil, message: composer.currentMessage, discuss: ([], []))
            return
        }
        begin(
            choice: composer.currentChoice, choices: composer.currentChoices, optionsSet: composer.currentOptionsSet,
            message: composer.currentMessage,
            itemAnswers: ReplyPayloadBuilder.itemAnswers(for: knockCase, choice: composer.currentChoice, choices: composer.currentChoices))
    }

    /// "Send N answers" on an ask with questions: the answers, and the free note with them.
    func sendAnswers(_ answers: [PointAnswer], message: String?) {
        guard !answers.isEmpty else { return }
        begin(choice: nil, optionsSet: nil, message: message, answers: answers)
    }

    /// "Send N answers" on a request with items (WAG-315): the answers by item id, and the free note with them.
    func sendItemAnswers(_ answers: [ItemAnswer], message: String?) {
        guard !answers.isEmpty else { return }
        begin(choice: nil, optionsSet: nil, message: message, itemAnswers: answers)
    }

    /// Leans and rule-outs on a request with several items (WAG-326): the person has not decided every item, so this
    /// keeps talking. The ids are "<item id>/<option id>".
    func sendItemDiscuss(leaning: [String], ruledOut: [String], message: String?, itemAnswers: [ItemAnswer] = []) {
        guard !leaning.isEmpty || !ruledOut.isEmpty || message != nil || composer.hasFiles else { return }
        begin(
            choice: nil, optionsSet: nil, message: message, itemAnswers: itemAnswers.isEmpty ? nil : itemAnswers,
            discuss: (leaning, ruledOut))
    }

    /// Feedback on the page with no point answered (WAG-285): the note goes out as a plain message with no
    /// choice, so the agent revises the page and sends a new round.
    func sendFeedback(message: String?) {
        guard let message, !message.isEmpty else { return }
        begin(choice: nil, choices: nil, optionsSet: nil, message: message)
    }

    /// "Change" / "Request changes" on a plan round (HAIL-151): the typed note goes out as a plain
    /// message with no choice, worded so the agent reads it as a change request.
    func sendPlanChange() {
        guard let stage = composer.planStage, let note = composer.currentMessage else { return }
        begin(choice: nil, choices: nil, optionsSet: nil, message: PlanText.changeMessage(stage: stage, note: note))
    }

    private func begin(
        choice: String?, choices: [String]? = nil, optionsSet: String?, message: String?, answers: [PointAnswer]? = nil,
        itemAnswers: [ItemAnswer]? = nil, discuss: (leaning: [String], ruledOut: [String])? = nil
    ) {
        guard !isSending else { return }
        pendingItemAnswers = itemAnswers
        pendingDiscuss = discuss
        pendingAnswers = answers
        pendingChoice = choice
        pendingChoices = choices
        pendingOptionsSet = optionsSet
        pendingMessage = message
        pendingMoreDetail = nil
        // Send sends, comments included - no second "You're sending"
        // confirmation (operator, 29 Sep: "after sending, it should go back
        // to the list view, and not asking me to send"; the extra step left
        // a commented reply unsent). The review screen still opens with
        // KNOCK_REVIEW_STEP=send for evidence only.
        Task { await confirmSend() }
    }

    /// M6's "Keep editing": returns to the composer without sending.
    func keepEditing() {
        isReviewingBeforeSend = false
    }

    /// "Ask" ⌘↵ (HAIL-33): sends a `more_detail` reply with the optional
    /// question from the inline field, straight through - no review-before-
    /// send step, since a detail request carries no comments to review.
    /// `format` (HAIL-139) is set by the one-tap format rows; `nil` for the
    /// quick-ask rows and the typed question.
    /// `about` (WAG-304) names the question of a step: the message starts with "About: <title>".
    func askForMoreDetail(format: ReplyFormat? = nil, about: String? = nil) {
        guard !isSending, deliveryState.state == .idle else { return }
        Task { await confirmAskForMoreDetail(format: format, about: about) }
    }

    /// A quick reply of the chip row (WAG-411). "Let's discuss" keeps talking: the agent answers in a new round and does
    /// not act yet. "Look at my comments" is a plain reply with the pinned comments that asks the agent to act on each.
    /// "Show me more" is a detail request, the same path as the "Ask for" chips. A typed draft goes with the first two.
    func quickReply(_ reply: QuickReply) {
        guard !isSending, deliveryState.state == .idle else { return }
        reply.report()
        switch reply {
        case .letsDiscuss:
            begin(
                choice: nil, optionsSet: nil, message: QuickReply.message(draft: composer.currentMessage, reply: reply),
                discuss: (composer.leaningIds, composer.ruledOutIds))
        case .lookAtMyComments:
            begin(
                choice: nil, choices: nil, optionsSet: nil,
                message: QuickReply.message(draft: composer.currentMessage, reply: reply))
        case .showMeMore:
            composer.fillDetailChip(reply.label)
            askForMoreDetail()
        }
    }

    /// The "Explain" button or the E key on a text selection (WAG-384): the same Keep talking path as the
    /// "Ask for" pills, with the quote in the request.
    func explain(selection: String) {
        composer.fillDetailChip(ExplainRequest.text(forSelection: selection))
        askForMoreDetail()
    }

    /// "About: Who sees a flag first?" then the typed question, when there is one.
    nonisolated static func detailMessage(about: String?, typed: String?) -> String? {
        guard let about, !about.isEmpty else { return typed }
        let head = "About: \(about)"
        return typed.map { "\(head)\n\($0)" } ?? head
    }

    private func confirmAskForMoreDetail(format: ReplyFormat? = nil, about: String? = nil) async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        let message = Self.detailMessage(about: about, typed: format == nil ? composer.detailQuestion : nil)
        // The banner reads this while the send is shown (HAIL-147).
        pendingMoreDetail = (format, message)
        let reply = PendingReply(
            caseId: knockCase.id,
            idempotencyKey: coordinator.idempotencyKey(for: knockCase.id),
            choice: nil,
            message: message,
            comments: [],
            captures: [],
            intent: .moreDetail,
            format: format
        )
        switch await deliveryState.send(reply) {
        case .sent:
            composer.cancelAskingForDetail()
            isReviewingBeforeSend = false
            clearAfterSend()
            onSent()
        case .offline:
            errorMessage = "Not sent · Waggle service is offline. Your reply is saved on this Mac and will send when it reconnects."
        case .refused(let reason):
            errorMessage = "Not sent · Waggle refused the reply. \(reason)"
        case .failed, .idle, .sending, .delivered:
            break
        }
    }

    /// M6's own Send action: the review step's final confirmation. Also the
    /// direct path when there are no comments to review first. A no-op once
    /// `deliveryState` has already left `.idle` for this attempt - the M8
    /// offline/failed banners replace the composer with a Retry action
    /// instead, and `⌘↵`'s hidden button stays wired the whole time
    /// (`ComposerFooterView`/`ReviewBeforeSendColumnView`), so this guard is
    /// what stops that shortcut from starting a second, distinct send while
    /// one is already showing its outcome.
    func confirmSend() async {
        guard deliveryState.state == .idle else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        // HAIL-112: a comment saved a moment ago may still be waiting for its picture.
        await commentsStore.settleCaptures()
        let (comments, captures) = ReplyPayloadBuilder.build(
            model: commentsStore.model,
            imagesByCaptureId: commentsStore.imagesByCaptureId,
            screenLabel: { [commentsStore] in commentsStore.screenLabel(for: $0) }
        )

        if let replaceReplyId {
            await confirmReplace(replyId: replaceReplyId, comments: comments, captures: captures)
            return
        }

        let reply = PendingReply(
            caseId: knockCase.id,
            idempotencyKey: coordinator.idempotencyKey(for: knockCase.id),
            choice: pendingChoice,
            message: pendingMessage,
            comments: comments,
            captures: captures,
            intent: pendingDiscuss == nil ? .decision : .discuss,
            optionsSet: pendingOptionsSet,
            choices: pendingChoices,
            editRevision: attachedEdit?.revision,
            answers: pendingAnswers,
            leaning: pendingDiscuss.map { $0.leaning.isEmpty ? nil : $0.leaning } ?? nil,
            ruledOut: pendingDiscuss.map { $0.ruledOut.isEmpty ? nil : $0.ruledOut } ?? nil,
            itemAnswers: pendingItemAnswers,
            attachments: composer.files.wireInputs()
        )
        switch await deliveryState.send(reply) {
        case .sent:
            isReviewingBeforeSend = false
            clearAfterSend()
            onSent()
            onAnswerSent(deliveryReplySummary)
        case .offline:
            // AC: "kept locally ... and re-submitted on reconnect with the
            // same key" - `coordinator.send` already saved it before trying
            // the socket. `errorMessage` is kept for `SendFlowControllerTests`
            // (`#expect(flow.errorMessage == nil)` on the success path); the
            // M8 offline banner (`deliveryState`) is what the UI shows now.
            errorMessage = "Not sent · Waggle service is offline. Your reply is saved on this Mac and will send when it reconnects."
        case .refused(let reason):
            errorMessage = "Not sent · Waggle refused the reply. \(reason)"
        case .failed, .idle, .sending, .delivered:
            break
        }
    }

    /// `confirmSend`'s "Change answer" branch (docs/stories/HAIL-34.md,
    /// operator decision on case c_c548e66e…): `reply.replace` under the
    /// existing id, never `reply.submit` - there is no offline-durable
    /// pending copy for an edit the way a first send has, so a thrown error
    /// (most notably the daemon's own "already delivered" rejection) just
    /// surfaces as `errorMessage`, leaving `isEditingLockedAnswer` set so the
    /// composer stays open to retry or to notice the case has moved on.
    private func confirmReplace(replyId: String, comments: [Comment], captures: [Capture]) async {
        do {
            let outcome = try await deliveryState.replace(
                replyId: replyId, choice: pendingChoice, optionsSet: pendingOptionsSet, message: pendingMessage,
                comments: comments, captures: captures, choices: pendingChoices, answers: pendingAnswers, itemAnswers: pendingItemAnswers,
                editRevision: attachedEdit?.revision, attachments: composer.files.wireInputs() ?? []
            )
            if case .sent = outcome {
                isReviewingBeforeSend = false
                isEditingLockedAnswer = false
                self.replaceReplyId = nil
                clearAfterSend()
                onSent()
            }
        } catch {
            errorMessage = "Could not change your answer · \(error)"
        }
    }

    /// "Change answer" (docs/stories/HAIL-34.md): re-opens the composer and
    /// options for a still-queued reply, prefilled with what was actually
    /// sent - not whatever the shared draft store happens to hold, which may
    /// already have moved on to a different pick. Also restores that reply's
    /// own comments/captures (operator decision via Knock, case c_656dc5ce…,
    /// choice "restore") so they are editable/removable again, not lost the
    /// moment the operator wants to change something else about the answer.
    func beginChangingAnswer() {
        guard let replyId = knockCase.latestReplyId else { return }
        usage?.record(.changeAnswerStarted)
        reopenSharedPage(true)
        replaceReplyId = replyId
        isEditingLockedAnswer = true
        errorMessage = nil
        deliveryState.reset()
        composer.selectedOptionId = knockCase.latestReplyChoice
        composer.selectedFromFirstOptions = knockCase.latestReplyFromFirstOptions
        if composer.isMultiSelect, !knockCase.latestReplyFromFirstOptions { composer.setPicks(knockCase.latestReplyChoices) }
        composer.draftText = knockCase.latestReplyMessage ?? ""
        if let reply = replies.first(where: { $0.id == replyId }) {
            attachedEdit = reply.edit.map {
                AttachedEdit(revision: $0.revision, baseRevision: $0.baseRevision, passagesChanged: $0.passagesChanged)
            }
            composer.files.restore(reply.attachments ?? [])
            // `cases.get` carries no capture images (PERF-2): fetch the pinned ones first.
            if CommentsSessionStore.restoreNeedsImages(for: reply), let client = captureClient {
                Task { [commentsStore] in await commentsStore.restore(from: reply, loadingImagesWith: client) }
            } else {
                commentsStore.restore(from: reply)
            }
        }
    }

    /// Leaves "Change answer" without sending (HAIL-74): the prefilled text
    /// and restored comments go away, so they never carry into a later round.
    func cancelChangingAnswer() {
        guard isEditingLockedAnswer else { return }
        isEditingLockedAnswer = false
        replaceReplyId = nil
        reopenSharedPage(false)
        clearAfterSend()
    }

    /// WAG-401: while the answer is being changed, the shared page shows the case as open (no Decided block). On
    /// cancel the page shows the old decision again. A new answer needs no call: the daemon sends it as the new
    /// decision. Quiet when it fails: the case works without the page.
    private func reopenSharedPage(_ reopened: Bool) {
        let caseId = knockCase.id
        guard let client = captureClient, SharingModels.isShared(caseId: caseId) else { return }
        Task { _ = try? await client.sharingReopen(caseId: caseId, reopened: reopened) }
    }

    /// A new round of the ask began (the case is back in needs_you after a
    /// `knock_update`, HAIL-74): an empty composer, no comments.
    func startNewRound() {
        isEditingLockedAnswer = false
        replaceReplyId = nil
        deliveryState.reset()
        clearAfterSend()
    }

    /// Empties the composer, its shared draft and the pinned comments. A sent
    /// reply is on the daemon now; none of it belongs to the next round.
    private func clearAfterSend() {
        composer.reset()
        commentsStore.clearComments()
        attachedEdit = nil
    }

    /// M8's Retry action (docs/design/mvp-values.md §M8 panels 3/4): re-sends
    /// an offline reply with its same idempotency key, or calls `reply.retry`
    /// for one the daemon already marked failed
    /// (`DeliveryStateViewModel.retry`). On success this finishes the send
    /// exactly as `confirmSend` does - the case has already moved to
    /// `waiting_on_agent` on the daemon by the time a reply exists at all.
    func retryDelivery() async {
        if case .sent = await deliveryState.retry() {
            isReviewingBeforeSend = false
            clearAfterSend()
            onSent()
            onAnswerSent(deliveryReplySummary)
        }
    }

    /// The REPLY block's value in the review-before-send step
    /// (docs/design/mvp-values.md §M6 "Reply block"): the pending choice's
    /// option label when one is selected, else the pending free-text
    /// message itself.
    var pendingReplyValue: String {
        if let pendingChoices, !pendingChoices.isEmpty {
            let titles = pendingChoices.map { id in
                knockCase.options.first(where: { $0.id == id })?.displayTitle ?? id
            }
            return titles.joined(separator: ", ")
        }
        if let pendingAnswers, !pendingAnswers.isEmpty {
            return "\(pendingAnswers.count) answer\(pendingAnswers.count == 1 ? "" : "s")"
        }
        if let pendingChoice {
            let pool = pendingOptionsSet == "first" ? knockCase.firstOptions : knockCase.options
            return pool.first(where: { $0.id == pendingChoice })?.label ?? pendingChoice
        }
        return pendingMessage ?? ""
    }

    /// The REPLY block's note line, shown only alongside a chosen option -
    /// a free-text reply has nothing left to say beyond its own value.
    var pendingReplyNote: String? {
        pendingChoice != nil || !(pendingChoices ?? []).isEmpty ? pendingMessage : nil
    }

    /// The M8 delivery banner's locked reply bubble text (docs/design/mvp-
    /// values.md §M8: "You: Go with A. Two fixes:") - the same value/note
    /// pair as the review-before-send REPLY block, joined into one line
    /// since the bubble has no separate label row.
    var deliveryReplySummary: String {
        if let pendingMoreDetail {
            return MoreDetailCopy.banner(format: pendingMoreDetail.format, message: pendingMoreDetail.message)
        }
        if let pendingDiscuss {
            return DiscussCopy.banner(
                leaning: titles(of: pendingDiscuss.leaning), ruledOut: titles(of: pendingDiscuss.ruledOut), message: pendingMessage)
        }
        guard let note = pendingReplyNote, !note.isEmpty else { return pendingReplyValue }
        return "\(pendingReplyValue). \(note)"
    }

    private func titles(of ids: [String]) -> [String] {
        ids.map { id in
            if let found = knockCase.options.first(where: { $0.id == id }) { return found.displayTitle }
            // With several items the wire names an option "<item id>/<option id>" (WAG-326).
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2,
               let title = knockCase.items.first(where: { $0.id == parts[0] })?.options.first(where: { $0.id == parts[1] })?.displayTitle {
                return title
            }
            return id
        }
    }

    // MARK: - Review-before-send display (docs/design/mvp-values.md §M6)

    /// Every comment across every capture that will be sent (HAIL-35 fold:
    /// "Send reply + N comments" must count ALL of them, same as the
    /// Comment column's footer and Interact mode's `commentCount`).
    var totalCommentCountForReview: Int { capturesForReview.reduce(0) { $0 + $1.comments.count } }

    /// The review-before-send section heading's "on ..." phrase (HAIL-40):
    /// `commentsStore.screenLabel(for:)` for a screenshots case ("Screen N[ ·
    /// caption]"), else the pre-HAIL-40 "Capture N (vM)" - the single place
    /// `ReviewBeforeSendColumnView`/`CommentsColumnView` both read this label
    /// from, so the wording is never duplicated a third time.
    func captureLabel(for capture: CaptureRecord) -> String {
        commentsStore.screenLabel(for: capture) ?? "Capture \(capture.n) (v\(capture.revision))"
    }
}
