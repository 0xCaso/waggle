import AppKit
import SwiftUI

/// Abbreviates a data path against a home directory with `~`, the way
/// Finder and most Mac tools show a path under the user's home. A small
/// pure function (rather than calling `NSString.abbreviatingWithTildeInPath`
/// straight from the view) so the Data & privacy page's path display is
/// unit-testable without depending on the real login `HOME` (contract test:
/// "data path abbreviation").
enum DataFolderPath {
    static func abbreviated(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// The "Answered decisions" row's label (HAIL-52 contract: "the count and disk
/// size of answered/resolved asks"). Pure so the pluralization and empty-set
/// wording are testable without a live `cases.resolved_stats` call.
enum AnsweredAsksLabel {
    static func text(count: Int, bytes: Int) -> String {
        guard count > 0 else { return "No answered decisions yet" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: Int64(bytes))
        return "\(count) answered decision\(count == 1 ? "" : "s") · \(size)"
    }
}

/// The "Clear answered decisions?" alert text (HAIL-236): says how many asks go
/// and that open and waiting asks stay.
enum ClearAnsweredMessage {
    static func text(count: Int) -> String {
        let noun = count == 1 ? "1 finished decision" : "\(count) finished decisions"
        return "Removes \(noun), with their bundles and screenshots. Decisions that still need you or are waiting on the agent stay."
    }
}

/// Holds the "Answered requests" row's live count/size and drives "Clear
/// answered…" (HAIL-52 contract). Polls every few seconds while the page is
/// open, the same resilience pattern `ConnectionModel` uses: the socket may
/// still be reconnecting (or the daemon still starting on demand) the
/// instant this page's `.task` first fires, so a single one-shot `load()`
/// can silently stay at zero forever with no later retry - polling means the
/// first successful call, whenever it lands, still reaches the row.
@MainActor
final class DataPrivacySettingsModel: ObservableObject {
    @Published private(set) var count = 0
    @Published private(set) var bytes = 0
    @Published private(set) var isClearing = false

    private let client: KnockClient
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?

    init(client: KnockClient, pollInterval: Duration = .seconds(5)) {
        self.client = client
        self.pollInterval = pollInterval
    }

    /// Idempotent: `.task` re-runs this on every view re-appearance, but a
    /// poll loop already running should not be duplicated.
    func start() async {
        guard pollTask == nil else { return }
        await load()
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                await self?.load()
            }
        }
    }

    func load() async {
        guard let stats = try? await client.casesResolvedStats() else { return }
        count = stats.count
        bytes = stats.bytes
    }

    /// "Clear answered…", confirmed (contract): purges every resolved case,
    /// then reloads the row from the daemon's own post-purge count - never
    /// just zeroing it locally, in case another purge ran concurrently.
    func clearAnswered() async {
        isClearing = true
        _ = try? await client.casesPurgeResolved()
        await load()
        isClearing = false
    }
}

/// The Data & privacy page (HAIL-50 contract, extended HAIL-52): data folder
/// path (`KnockClient.defaultDataRoot`, `~`-abbreviated) with Show in Finder;
/// Logs with Show logs (the folder `UpdaterLogDelegate` writes to); "Answered
/// asks" with its count and disk size, and "Clear answered…" behind a
/// confirmation.
struct DataPrivacySettingsView: View {
    let client: KnockClient

    @StateObject private var model: DataPrivacySettingsModel
    @State private var showsConfirmation = false

    init(client: KnockClient) {
        self.client = client
        _model = StateObject(wrappedValue: DataPrivacySettingsModel(client: client))
    }

    var body: some View {
        SettingsPageChrome(title: SettingsPage.data.title, subtitle: SettingsPage.data.subtitle) {
            SettingsCard {
                SettingsCardRow(
                    title: "Data folder",
                    subtitle: DataFolderPath.abbreviated(KnockClient.defaultDataRoot()),
                    showsDivider: false
                ) {
                    SettingsSecondaryButton(title: "Show in Finder") {
                        reveal(URL(fileURLWithPath: KnockClient.defaultDataRoot()))
                    }
                }
            }
            SettingsCard {
                SettingsCardRow(
                    title: "Logs",
                    subtitle: "Update and service logs, for troubleshooting",
                    showsDivider: false
                ) {
                    SettingsSecondaryButton(title: "Show logs") {
                        reveal(UpdaterLogDelegate.logDirectory())
                    }
                }
            }
            SettingsCard {
                SettingsCardRow(
                    title: "Answered requests",
                    subtitle: AnsweredAsksLabel.text(count: model.count, bytes: model.bytes),
                    showsDivider: false
                ) {
                    SettingsSecondaryButton(title: "Clear answered…") { showsConfirmation = true }
                        .disabled(model.count == 0 || model.isClearing)
                }
            }
            UsageSettingsSection(client: client)
        }
        .task { await model.start() }
        .alert("Clear answered decisions?", isPresented: $showsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { Task { await model.clearAnswered() } }
        } message: {
            Text(ClearAnsweredMessage.text(count: model.count))
        }
    }

    /// The data folder always exists by the time Settings can open (the
    /// daemon creates it); the logs folder may not, if no update or service
    /// log has been written yet this profile - created here so the button
    /// always opens somewhere instead of silently doing nothing.
    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
