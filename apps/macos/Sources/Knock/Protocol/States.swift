import Foundation

// Case state. docs/protocol-mvp.md "Case and reply states".
enum CaseStatus: String, Codable, Sendable {
    case needsYou = "needs_you"
    case waitingOnAgent = "waiting_on_agent"
    case resolved
}

// Reply state. docs/protocol-mvp.md "Case and reply states". "superseded"
// (HAIL-44) marks a queued reply on a case that a newer knock_ask replaced:
// the human answered, but the case it answered was withdrawn before an agent
// ever picked that answer up, so it is never delivered.
enum ReplyStatus: String, Codable, Sendable {
    case queued
    case delivered
    case failed
    case superseded
    /// WAG-410: a failed reply whose case the operator continued in a new session. Terminal.
    case handedOver = "handed_over"
}

// Session state. docs/protocol-mvp.md "Socket RPC" (updated after KNOCK-01):
// "live" (shim connected), "disconnected" (connection closed, parent pid
// still alive), "ended" (parent process gone). Only "ended" makes a queued
// reply "failed".
/// WAG-267: what happened after a delivered reply. `pending`: the agent got it, nothing shows yet.
/// `applied`: the same session showed visible work. `notApplied`: the session closed, or 15 minutes
/// passed, with no visible work. A field beside `ReplyStatus`, so the old states stay as they were.
enum ReplyApplyState: String, Codable, Sendable {
    case pending
    case applied
    case notApplied = "not_applied"
}

enum SessionState: String, Codable, Sendable {
    case live
    case disconnected
    case ended
}

// Events streamed over events.subscribe. docs/protocol-mvp.md "Events".
enum EventType: String, Codable, Sendable {
    case caseCreated = "case.created"
    case caseUpdated = "case.updated"
    /// WAG-394: a team member commented on a shared case.
    case commentAdded = "comment.added"
    case revisionAdded = "revision.added"
    case replyStateChanged = "reply.state_changed"
    case sessionStateChanged = "session.state_changed"
    /// HAIL-76: the daemon posted a nudge for a queued reply.
    case sessionNudged = "session.nudged"
    /// HAIL-134: a Claude Code mod asked the app to open a case (the band's button).
    case caseOpenRequested = "case.open_requested"
}

// The kind of a staged artifact.
enum ArtifactKind: String, Codable, Sendable {
    case screenshot
    case htmlBundle = "html_bundle"
    case markdown
    /// 2 to 12 images the operator flips through one at a time (HAIL-40).
    case screenshots
    /// One .mmd (Mermaid source) or .svg file, rendered offline (HAIL-141).
    case diagram
}

// A reply's intent (HAIL-33): "decision" (default, the pre-existing
// behaviour) or "more_detail" (the human wants an explanation before
// deciding, carries no choice) or "discuss" (WAG-301: the human has not decided; they lean to some
// options, rule some out, or ask a question, and the ask stays open).
enum ReplyIntent: String, Codable, Sendable {
    case decision
    case moreDetail = "more_detail"
    case discuss
}

// Where a reply came from (HAIL-144): the Mac app or a chat connector. Slack (HAIL-145) adds a
// case. A value this app does not know decodes as nil on a Case and as .mac on a Reply, so an
// older app keeps working against a newer daemon.
enum ReplySource: String, Codable, Sendable {
    case mac
    case telegram
    case slack

    /// "Telegram" for a chat connector, nil for the Mac.
    var chatName: String? {
        switch self {
        case .mac: nil
        case .telegram: "Telegram"
        case .slack: "Slack"
        }
    }
}

// The format a "more detail" reply asks for (HAIL-139): how the human wants
// the explanation back. Optional: a detail request with no format behaves
// exactly as before.
enum ReplyFormat: String, Codable, Sendable, CaseIterable {
    case eli5
    case diagram
    case page

    /// The one-tap row label in `AskForDetailView` (amendment 2).
    var rowLabel: String {
        switch self {
        case .eli5: "Explain it like I'm five"
        case .diagram: "As a diagram"
        case .page: "As an interactive page"
        }
    }

    /// The SF Symbol standing in for the row's lucide icon (`baby` / `workflow`
    /// / `app-window`); no bundled icon set ships with the app
    /// (`CaseDisplay.indicatorSystemImage`).
    var icon: String {
        switch self {
        case .eli5: "figure.child"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .page: "macwindow"
        }
    }

    /// The thread row's suffix, e.g. "Asked for more detail · as a diagram".
    var threadLabel: String {
        switch self {
        case .eli5: "like I'm five"
        case .diagram: "as a diagram"
        case .page: "as an interactive page"
        }
    }
}

// The usage events the app reports over usage.record (KNOCK-19, HAIL-83).
// Every one is a closed enum on the wire: docs/protocol-mvp.md "usage.record".
enum UsageEvent: String, Codable, Sendable {
    case caseOpened = "case_opened"
    case commentModeStarted = "comment_mode_started"
    case artifactOpenedFull = "artifact_opened_full"
    case reviewOpened = "review_opened"
    case previewInteracted = "preview_interacted"
    case optionPicked = "option_picked"
    case recommendationAccepted = "recommendation_accepted"
    case replyTyped = "reply_typed"
    case askMoreDetailOpened = "ask_more_detail_opened"
    case changeAnswerStarted = "change_answer_started"
    case goBackClicked = "go_back_clicked"
    case sessionsPanelOpened = "sessions_panel_opened"
    case sessionDetailOpened = "session_detail_opened"
    case screenshotZoomChanged = "screenshot_zoom_changed"
    case screenshotSetViewOpened = "screenshot_set_view_opened"
    case commentAdded = "comment_added"
    case nudgeClicked = "nudge_clicked"
    case copyPromptClicked = "copy_prompt_clicked"
    // WAG-366: app use, and the screens added after HAIL-83.
    case appLaunched = "app_launched"
    case appActive = "app_active"
    case onboardingStarted = "onboarding_started"
    case onboardingAgentConnected = "onboarding_agent_connected"
    case onboardingContinued = "onboarding_continued"
    case firstJobStarted = "first_job_started"
    case firstJobFinished = "first_job_finished"
    case onboardingPromptCopied = "onboarding_prompt_copied"
    case tourStarted = "tour_started"
    case tourFinished = "tour_finished"
    case tourSkipped = "tour_skipped"
    case gettingStartedLineOpened = "getting_started_line_opened"
    case gettingStartedHidden = "getting_started_hidden"
    case settingsPageOpened = "settings_page_opened"
    case usageExported = "usage_exported"
    case newIdeaOpened = "new_idea_opened"
    case newIdeaStarted = "new_idea_started"
    case launchTargetChosen = "launch_target_chosen"
    case projectPageOpened = "project_page_opened"
    case updatePromptShown = "update_prompt_shown"
    case updateInstallClicked = "update_install_clicked"
    case updateLaterClicked = "update_later_clicked"
    case updateSkipped = "update_skipped"
    case updateRestartClicked = "update_restart_clicked"
    case whatsNewOpened = "whats_new_opened"
    case splitFoldToggled = "split_fold_toggled"
    case sourcesListOpened = "sources_list_opened"
    case sourceOpened = "source_opened"
    case artifactVariantSelected = "artifact_variant_selected"
    case detailFormatPicked = "detail_format_picked"
    case quickReplyPicked = "quick_reply_picked"
    /// WAG-413: the Compare switch of the screenshot header.
    case compareToggled = "compare_toggled"

    /// Events about one ask (WAG-366). Only these may carry `case_id`; the daemon rejects it on the others.
    var isAskBound: Bool {
        switch self {
        case .caseOpened, .commentModeStarted, .artifactOpenedFull, .reviewOpened, .previewInteracted,
             .optionPicked, .recommendationAccepted, .replyTyped, .askMoreDetailOpened, .changeAnswerStarted,
             .goBackClicked, .screenshotZoomChanged, .screenshotSetViewOpened, .commentAdded, .nudgeClicked,
             .sourcesListOpened, .sourceOpened, .artifactVariantSelected, .detailFormatPicked, .quickReplyPicked,
             .compareToggled:
            true
        default:
            false
        }
    }
}

// Where a case was opened from (the case_opened source, KNOCK-19, HAIL-83).
enum CaseOpenSource: String, Codable, Sendable {
    case notification
    case menuBar = "menu_bar"
    case queue
    case sessionsPanel = "sessions_panel"
    case autoAdvance = "auto_advance"
    case keyboard
}

// How an option was picked (option_picked source, HAIL-83).
enum OptionPickSource: String, Codable, Sendable {
    case click
    case numberKey = "number_key"
}

// How the recommendation was accepted (recommendation_accepted source, HAIL-83).
enum AcceptSource: String, Codable, Sendable {
    case button
    case shortcut
}

// Seconds since the ask was opened, in four buckets (HAIL-83). The app never
// sends a raw number.
enum UsageAfter: String, Codable, Sendable {
    case s0to2 = "0-2"
    case s3to10 = "3-10"
    case s11to60 = "11-60"
    case s60plus = "60+"

    init(seconds: Double) {
        switch seconds {
        case ..<3: self = .s0to2
        case ..<11: self = .s3to10
        case ..<61: self = .s11to60
        default: self = .s60plus
        }
    }
}

// The one extra mode of a click: the screenshot zoom level or the comment
// shape (HAIL-83).
enum UsageVariant: String, Codable, Sendable {
    case fit
    case hundred = "100"
    case zoom
    case point
    case region
    /// WAG-413: Compare switched on or off.
    case on
    case off
}

// One usage record, exactly the fields docs/protocol-mvp.md allows. Omitted
// keys are not encoded, so an event never carries a field it does not take.
struct UsageRecord: Encodable, Equatable, Sendable {
    let event: UsageEvent
    var source: String?
    var artifactKind: ArtifactKind?
    var afterS: UsageAfter?
    /// A closed word on the wire. `UsageVariant` for the HAIL-83 events; the raw value of another
    /// closed enum (a settings page, a launch target) for the WAG-366 ones.
    var variant: String?
    /// The ask the event is about (WAG-366). The daemon stores a salted hash of it, never the id.
    var caseId: String?
    /// The format of a detail request: eli5, diagram, page or none.
    var format: String?
    var n: Int?

    init(
        _ event: UsageEvent, source: String? = nil, artifactKind: ArtifactKind? = nil,
        afterS: UsageAfter? = nil, variant: UsageVariant? = nil, variantName: String? = nil,
        caseId: String? = nil, format: String? = nil, n: Int? = nil
    ) {
        self.event = event
        self.source = source
        self.artifactKind = artifactKind
        self.afterS = afterS
        self.variant = variant?.rawValue ?? variantName
        self.caseId = caseId
        self.format = format
        self.n = n
    }

    private enum CodingKeys: String, CodingKey {
        case event, source
        case artifactKind = "artifact_kind"
        case afterS = "after_s"
        case variant
        case caseId = "case_id"
        case format, n
    }
}

// The connector a session and its cases came through (KNOCK-20).
// docs/protocol-mvp.md: the shim reads KNOCK_RUNTIME and defaults an unknown
// or missing value to "claude" for a registration made before Codex support.
enum Runtime: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}
