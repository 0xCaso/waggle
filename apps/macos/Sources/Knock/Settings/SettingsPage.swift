import Combine
import Foundation

/// One page of the Settings sidebar window (HAIL-50). Seven pages, existing
/// behaviour only - see the story's Contract for what each page shows and,
/// just as deliberately, what it leaves out for a later release.
enum SettingsPage: String, CaseIterable, Identifiable, Equatable {
    case agents
    case notifications
    case previews
    case artifacts
    case asks
    case phone
    case askLess
    case screenshots
    case sharing
    case account
    case updates
    case data
    case help

    var id: String { rawValue }

    /// The pages the sidebar shows. Sharing and Account belong to the Sharing feature: hidden while the daemon
    /// says it is not available (operator decision 8 Nov).
    static func visible(sharingAvailable: Bool) -> [SettingsPage] {
        sharingAvailable ? allCases : allCases.filter { $0 != .sharing && $0 != .account }
    }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .notifications: "Notifications"
        case .previews: "Previews"
        case .screenshots: "Screenshots"
        case .artifacts: "Artifacts"
        case .asks: "Requests"
        case .askLess: "Ask less"
        case .phone: "Phone"
        case .sharing: "Sharing"
        case .account: "Account"
        case .updates: "Updates"
        case .data: "Data & privacy"
        case .help: "Help"
        }
    }

    var subtitle: String {
        switch self {
        case .agents: "Waggle works with Claude Code and Codex on this Mac. Your agents ask you here instead of in the terminal."
        case .notifications: "Waggle tells you the moment an agent has a decision for you, even when it isn't in front."
        case .previews: "How prototypes, plans and screenshots from your agents show in a decision."
        case .screenshots: "Send a screenshot you took to an agent that is running. Optional, and off until you turn it on."
        case .artifacts: "How your agents build the pages and screenshots they send you."
        case .asks: "What your agents bring you in Waggle, and how often."
        case .askLess: "Let Waggle answer small choices for you, by rules you pick. Off until you turn it on."
        case .phone: "Get new decisions on your phone and answer them there. Optional, and off until you connect it."
        case .sharing: "Share a case with your team so they can read it and comment. Off until you turn it on."
        case .account: "Your Waggle account. Only sharing a case needs it. Local use never does."
        case .updates: "Waggle checks for a new version every hour."
        case .data: "Everything stays on this Mac. The exceptions are Telegram or Slack, if you connect one on the Phone page, and a case you share, if you turn on Sharing."
        case .help: "Something not working? Start here."
        }
    }

    /// A 15pt SF Symbol for the sidebar row (contract: "15 pt SF Symbol").
    var symbolName: String {
        switch self {
        case .agents: "terminal"
        case .notifications: "bell"
        case .previews: "photo"
        case .screenshots: "camera.viewfinder"
        case .artifacts: "square.stack"
        case .asks: "bubble.left.and.bubble.right"
        case .askLess: "checkmark.bubble"
        case .phone: "iphone"
        case .sharing: "person.2"
        case .account: "person.crop.circle"
        case .updates: "arrow.down.circle"
        case .data: "folder"
        case .help: "questionmark.circle"
        }
    }

    /// `KNOCK_SETTINGS_PAGE=<agents|notifications|previews|screenshots|artifacts|asks|askLess|phone|sharing|account|updates|data|help>`
    /// (contract): an evidence hook so the orchestrator can open a page
    /// without a click. An unset or unrecognised value falls back to
    /// `.agents`, the first row.
    static func initial(environment: [String: String] = ProcessInfo.processInfo.environment) -> SettingsPage {
        guard let raw = environment["KNOCK_SETTINGS_PAGE"], let page = SettingsPage(rawValue: raw) else {
            return .agents
        }
        return page
    }
}

/// Holds the sidebar's current selection. A separate `ObservableObject`
/// rather than plain `@State` on `SettingsView` so `SettingsPage.initial`'s
/// environment read has one obvious, testable seam.
@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selected: SettingsPage {
        didSet { if selected != oldValue { reportPage() } }
    }

    /// One `settings_page_opened` for the page that shows (WAG-366): on a change, and when the window opens.
    func reportPage() {
        UsageReporter.current?.record(.settingsPageOpened, variantName: selected.rawValue)
    }

    /// Hidden until the daemon says Sharing is available, so the pages never flash in and out.
    @Published private(set) var sharingAvailable = false {
        didSet { if !visiblePages.contains(selected) { selected = .agents } }
    }

    var visiblePages: [SettingsPage] { SettingsPage.visible(sharingAvailable: sharingAvailable) }

    /// Asks the daemon once. With no answer the pages stay hidden.
    func loadSharing(_ get: () async throws -> SharingState) async {
        if let state = try? await get() { sharingAvailable = state.available }
    }

    private var showAgents: AnyCancellable?
    private var showPage: AnyCancellable?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        selected = SettingsPage.initial(environment: environment)
        // The queue's "All sessions in Settings" (HAIL-59) lands on Agents even
        // when the window is already open on another page.
        showAgents = NotificationCenter.default.publisher(for: .knockShowAgentsSettings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.selected = .agents }
        // The getting started list opens a page by name (WAG-338).
        showPage = NotificationCenter.default.publisher(for: .knockShowSettingsPage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in if let page = note.object as? SettingsPage { self?.selected = page } }
    }
}

extension Notification.Name {
    static let knockShowAgentsSettings = Notification.Name("knockShowAgentsSettings")
}
