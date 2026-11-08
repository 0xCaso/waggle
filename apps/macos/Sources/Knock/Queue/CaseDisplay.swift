import Foundation

/// The three states an answered ask's reply can be in, once it has left
/// `needs_you` for the round (docs/stories/HAIL-34.md, operator decision on
/// case c_c548e66e…). `.editable` is everything before that: no reply yet,
/// or a fresh round after the agent's own `knock_update`.
enum ReplyLockState: Equatable, Sendable {
    case editable
    case queued
    case delivered
    case failed
}

extension Case {
    /// The "recommends → <value>" text, reused by the case pane's
    /// RECOMMENDED block (docs/design/mvp-values.md §2.3): when the
    /// recommendation matches an option id, show that option's label as
    /// the answer box shows it (`"A · Compact"` reads `"Compact"`, HAIL-54's
    /// numbered rows) and nothing else - do not also prepend the id. When no
    /// option matches, the recommendation is already free text (`"ship as is"`).
    var recommendationDisplay: String {
        guard let option = options.first(where: { $0.id == recommendation }) else { return recommendation }
        return option.displayTitle
    }

    /// The queue row's session label (docs/design/mvp-values.md §2.3):
    /// "project · task · <runtime>", collapsed to "project · <runtime>" when
    /// the task name duplicates its project - the same rule as
    /// `KnockTask.sessionLabel(runtime:)`, but reading straight off `Case`'s
    /// own denormalized `taskName`/`project` (HAIL-28) so a queue row never
    /// waits on a per-task `cases.get` to fill in its meta line.
    var sessionLabel: String {
        taskName == project ? "\(project) · \(runtimeLabel)" : "\(project) · \(taskName) · \(runtimeLabel)"
    }

    /// Whether Dismiss needs a confirmation before it fires (docs/stories/
    /// HAIL-32.md: "asks for confirmation only when the case is needs_you
    /// and the agent is live") - a live session may be blocked in
    /// `knock_ask`/`knock_check` on this exact case right now, so dismissing
    /// it silently could strand that call until its own timeout.
    var needsDismissConfirmation: Bool {
        status == .needsYou && sessionState == .live
    }

    /// Whether the queue row shows the "Waiting for pickup" mini spinner
    /// (docs/stories/HAIL-32.md state 2): the case is `waiting_on_agent` and
    /// no `reply.state_changed` has named a delivered/failed outcome for it
    /// yet - `deliveryStatus` only ever holds those two terminal states
    /// (`AppModel.deliveryStatusByCaseId`), so every other value (including
    /// `nil`, the common case right after `reply.submit`) means still
    /// waiting.
    func showsWaitingForPickup(deliveryStatus: DeliveryState?) -> Bool {
        guard status == .waitingOnAgent, !isStaleQueuedReply, !isDone else { return false }
        switch deliveryStatus {
        case .delivered, .failed: return false
        case .idle, .sending, .sent, .offline, .refused, .none: return true
        }
    }

    /// Whether a queued reply is stuck because the agent's session ended
    /// before any agent ever picked it up (HAIL-44 safety net): the row
    /// shows "Not picked up - the agent's session ended" instead of
    /// "Waiting for pickup" forever. Reads `latestReplyState`/`sessionState`,
    /// both denormalized onto `Case` (docs/protocol-mvp.md "Case fields"), so
    /// this survives a relaunch - unlike `showsWaitingForPickup`'s
    /// `deliveryStatus` parameter, which only reflects a `reply.state_changed`
    /// event seen this session and is always `nil` right after one.
    var isStaleQueuedReply: Bool {
        status == .waitingOnAgent && latestReplyState == .queued && sessionState == .ended && !isDone
    }

    /// True when the agent closed the case with a done update (HAIL-152): it finished and no
    /// answer will come. A closed case never shows pick-up, Nudge or a reply field.
    var isDone: Bool { doneAt != nil }

    /// The agent's closing note on one line, for the row ("Done · <message>").
    var doneMessage: String {
        (latestUpdateMessage ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether the ask is locked (docs/stories/HAIL-34.md, operator report
    /// 21:11 + Knock decision on case c_c548e66e…): once a reply exists for
    /// the current round and the daemon has moved the case out of
    /// `needs_you`, the pane and the review workspace stop offering actions
    /// that no longer apply - no composer, no selectable options, only the
    /// delivery line. A new round (an agent's `knock_update` returns the
    /// case to `needs_you`) unlocks it again.
    var isAnswerLocked: Bool {
        // A progress note (WAG-377) opens the free reply again, so it never locks the answer.
        isDone || (latestReplyId != nil && status != .needsYou && workingNoteText == nil)
    }

    /// `isAnswerLocked` broken into its three sub-states (docs/stories/
    /// HAIL-34.md, operator decision on case c_c548e66e…): a queued reply
    /// stays editable through "Change answer"; a delivered one is fully
    /// read-only; a failed one shows Retry. `.editable` covers both "never
    /// answered" and "a new round" - `isAnswerLocked` is false either way.
    var replyLockState: ReplyLockState {
        guard isAnswerLocked else { return .editable }
        // A done case is read-only: nothing can still be changed or retried.
        if isDone { return .delivered }
        switch latestReplyState {
        case .delivered: return .delivered
        // `.superseded` (HAIL-44) reads as `.failed`: both are terminal and
        // locked, and a withdrawn case's own pane is never opened by the app
        // (`ReplacesHeaderView`'s "Replaces:" line is not a link, unlike
        // `FollowUpHeaderView`'s - Choices ledger), so this branch exists
        // only to keep the switch exhaustive, not to be shown.
        case .failed, .superseded: return .failed
        // WAG-410: a handed over reply is not a failure. The new session has the answer.
        case .handedOver: return .delivered
        case .queued, nil: return .queued
        }
    }

    /// True while the case is waiting on the agent for a "more detail"
    /// answer rather than a decision (HAIL-33): the queued banner reads
    /// "Asked for more detail · waiting for the agent" instead of "Sent ·
    /// waiting for the agent to pick it up".
    /// The option set the latest reply's choice came from (HAIL-108): the first
    /// set when the human picked under "First options", else the newest.
    var repliedOptions: [Option] { latestReplyFromFirstOptions ? firstOptions : options }
    var repliedRecommendation: String { latestReplyFromFirstOptions ? firstRecommendation : recommendation }

    /// The titles of the options ticked in the latest reply to a select "many" ask (HAIL-123), in
    /// the order they were sent; empty for any other reply.
    var repliedChoiceTitles: [String] {
        latestReplyChoices.map { id in repliedOptions.first { $0.id == id }?.displayTitle ?? id }
    }

    /// True when the latest select "many" reply ticked exactly the recommended options.
    var repliedTookRecommendations: Bool {
        !latestReplyChoices.isEmpty && Set(latestReplyChoices) == Set(recommendations)
    }

    /// The latest reply is feedback on the page (WAG-285): a note with no choice and no answer, on an ask that
    /// offers options or points. The daemon words it to the agent the same way.
    var isFeedbackReply: Bool {
        guard latestReplyIntent == .decision, !(latestReplyMessage ?? "").isEmpty else { return false }
        guard latestReplyChoice == nil, latestReplyChoices.isEmpty, latestReplyAnswers.isEmpty else { return false }
        return !options.isEmpty || !questions.isEmpty
    }

    /// The last reply asks for more detail, or is a discuss reply (WAG-301): the agent answers, the ask stays open.
    var isTalkingItOver: Bool { latestReplyIntent == .moreDetail || latestReplyIntent == .discuss }

    var isWaitingOnMoreDetail: Bool {
        replyLockState == .queued && isTalkingItOver
    }

    /// The follow-up header's recap of the earlier ask's answer (HAIL-33
    /// amendment): "You chose: <value>[. <message>]" - the story's own
    /// example is "You chose: Change something. Why don't we make the
    /// button blue?". `nil` for a case with no reply yet.
    var followUpRecapLine: String? {
        guard latestReplyId != nil else { return nil }
        if !options.isEmpty, !latestReplyChoices.isEmpty {
            let label = repliedChoiceTitles.joined(separator: ", ")
            if let message = latestReplyMessage, !message.isEmpty { return "You chose: \(label). \(message)" }
            return "You chose: \(label)"
        }
        if !options.isEmpty, let choice = latestReplyChoice {
            let label = repliedOptions.first(where: { $0.id == choice })?.displayTitle ?? choice
            if let message = latestReplyMessage, !message.isEmpty {
                return "You chose: \(label). \(message)"
            }
            return "You chose: \(label)"
        }
        guard let message = latestReplyMessage, !message.isEmpty else { return nil }
        return "You chose: \(message)"
    }

    /// "you → <label>" (docs/stories/HAIL-34.md operator report 21:24,
    /// correction 21:36): the operator's own answer, replacing the old
    /// "recommends →" line on an answered queue row. `nil` for a case with
    /// no reply yet - a pending row shows the need line instead, never this.
    ///
    /// An options case reads `latestReplyChoice` against `options`/
    /// `recommendation` ("you → accepted: <label>" when it matches the
    /// recommendation, else "you → <label>", then "· <message>" when one was
    /// typed alongside the pick). A free-text case (no options) has no
    /// choice to report, so it reads `latestReplyMessage` instead, matching
    /// it against `recommendation` the same way (`ComposerViewModel.
    /// recommendationMessage` sends the recommendation string verbatim, so
    /// this equality check is exact, not a heuristic).
    var answeredSummaryLine: String? {
        guard latestReplyId != nil else { return nil }
        // HAIL-144: an answer from a chat connector reads "Answered from Telegram → ...".
        let answerer = latestReplySource?.chatName.map { "Answered from \($0)" } ?? "you"
        // A detail request asks a question, it does not answer one
        // (operator, 2026-09-28: "you asked: ...").
        if latestReplyIntent == .discuss {
            let note = latestReplyMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return note.isEmpty ? "you are talking it over" : "you asked: \(note)"
        }
        if latestReplyIntent == .moreDetail {
            let question = latestReplyMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return question.isEmpty ? "you asked: more detail" : "you asked: \(question)"
        }
        if !options.isEmpty, !latestReplyChoices.isEmpty {
            let label = repliedChoiceTitles.joined(separator: ", ")
            let valuePart = repliedTookRecommendations ? "accepted: \(label)" : label
            if let message = latestReplyMessage, !message.isEmpty {
                return "\(answerer) → \(valuePart) · \(message)"
            }
            return "\(answerer) → \(valuePart)"
        }
        if !options.isEmpty {
            guard let choice = latestReplyChoice else {
                return latestReplyMessage.map { "\(answerer) → \($0)" }
            }
            let label = repliedOptions.first(where: { $0.id == choice })?.displayTitle ?? choice
            // WAG-353: a choice with text reads as "Approved with changes" / "<title>, with changes".
            let valuePart = latestReplyWithChangesWords ?? (choice == repliedRecommendation ? "accepted: \(label)" : label)
            if let message = latestReplyMessage, !message.isEmpty {
                return "\(answerer) → \(valuePart) · \(message)"
            }
            return "\(answerer) → \(valuePart)"
        }
        guard let message = latestReplyMessage else { return nil }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRecommendation = recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMessage == trimmedRecommendation {
            return "\(answerer) → accepted: \(recommendation)"
        }
        return "\(answerer) → \(message)"
    }
}

extension Runtime {
    /// The runtime display map (KNOCK-20 contract): every place the app used
    /// to hard-code "Claude Code" now reads this instead, so a second
    /// connector shows its own name.
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// Which MCP client started a session (HAIL-173). The shim sends the `clientInfo.name` from MCP
/// `initialize`. The Claude app and Cowork cannot be nudged and cannot see a reply until Claude calls
/// knock_check, so Knock names them and offers "Copy reply" instead of "Copy prompt".
enum ClientName {
    /// Claude Code names itself "claude-code".
    static func isClaudeCode(_ name: String?) -> Bool {
        name?.lowercased().hasPrefix("claude-code") ?? false
    }

    /// Cowork reports `local-agent-mode-<server>` (HAIL-186); an older name may contain "cowork".
    static func isCowork(_ name: String?) -> Bool {
        guard let lower = name?.lowercased() else { return false }
        return lower.hasPrefix("local-agent-mode") || lower.contains("cowork")
    }

    /// "Cowork" when the name says so (any case), else "Claude app".
    static func desktopLabel(_ name: String) -> String {
        isCowork(name) ? "Cowork" : "Claude app"
    }

    /// The name to show for a session. A desktop client (Claude, not Claude Code, not nudgeable) with a
    /// known client name reads "Claude app" or "Cowork". Everything else keeps the runtime's name.
    static func label(runtime: Runtime, clientName: String?, canNudge: Bool?, cwd: String? = nil) -> String {
        // HAIL-178: a Claude app or Cowork chat that connected before the client name existed has no
        // name, cannot be nudged and runs from "/". It reads "Claude app", not "Claude Code".
        if runtime == .claude, canNudge == false, clientName?.isEmpty ?? true, cwd == "/" { return "Claude app" }
        guard runtime == .claude, canNudge == false, let clientName, !clientName.isEmpty,
              !isClaudeCode(clientName) else { return runtime.displayName }
        return desktopLabel(clientName)
    }
}

extension Case {
    /// The client name for rows, headers and copy: "Claude app", "Cowork", "Claude Code" or "Codex".
    var runtimeLabel: String {
        ClientName.label(runtime: runtime, clientName: sessionClientName, canNudge: sessionCanNudge)
    }

    /// A Claude session that cannot be nudged and did not start in Claude Code: the Claude app or
    /// Cowork. An unknown client name (an older shim) with `can_nudge` false counts too (HAIL-170).
    var isDesktopClient: Bool {
        runtime == .claude && sessionCanNudge == false && !ClientName.isClaudeCode(sessionClientName)
    }
}

extension SessionInfo {
    var runtimeLabel: String {
        ClientName.label(runtime: runtime, clientName: clientName, canNudge: canNudge, cwd: cwd)
    }
}

extension KnockTask {
    /// The row/pane session label (docs/design/mvp-values.md §2.3):
    /// "project · task · <runtime>", collapsed to "project · <runtime>" when
    /// the task name duplicates its project (a one-off project with no
    /// separately named task). `runtime` comes from the task's case
    /// (KNOCK-20): `KnockTask` itself carries no runtime.
    func sessionLabel(runtime: Runtime) -> String {
        name == project ? "\(project) · \(runtime.displayName)" : "\(project) · \(name) · \(runtime.displayName)"
    }

    /// The case-pane/titlebar breadcrumb (docs/design/mvp-values.md
    /// §M3/§M4): "project <separator> task", collapsed to just the project
    /// when the task name duplicates it (a one-off project with no
    /// separately named task) - the same dedup `sessionLabel` applies, with
    /// a caller-chosen separator since the case pane and the review
    /// titlebar each use their own.
    func breadcrumb(separator: String) -> String {
        name == project ? project : "\(project)\(separator)\(name)"
    }
}

extension ArtifactKind {
    /// Queue-row artifact indicator label (docs/design/mvp-values.md §2.3).
    /// "Write-up" for markdown (HAIL-33, WAG-335): the queue chip the story asks
    /// for.
    var indicatorLabel: String {
        switch self {
        case .htmlBundle: "Prototype"
        case .screenshot: "Screenshot"
        case .markdown: "Write-up"
        case .screenshots: "Screenshots"
        case .diagram: "Diagram"
        }
    }

    /// SF Symbol standing in for the node's lucide icon (`app-window` /
    /// `image`); no bundled icon set ships with this story.
    var indicatorSystemImage: String {
        switch self {
        case .htmlBundle: "macwindow"
        case .screenshot: "photo"
        case .markdown: "doc.text"
        /// A stack of images reads clearly at chip size, distinct from the
        /// single-image `photo` glyph (HAIL-40, your call).
        case .screenshots: "photo.stack"
        case .diagram: "flowchart"
        }
    }
}
