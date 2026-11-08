import Combine
import SwiftUI

/// Holds the Connection section's state: the daemon's `sessions.list`,
/// polled every 5s while Settings is open so the list stays "live" without
/// wiring a second consumer onto the app's single `events.subscribe` stream
/// (`AppModel` already owns that one, and `KnockClient.events` is a plain
/// `AsyncStream` - only one iterator ever sees each element).
@MainActor
final class ConnectionModel: ObservableObject {
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var now = Date()

    /// Live sessions only.
    var liveSessions: [SessionInfo] { Self.live(sessions) }

    nonisolated static func live(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.filter { $0.state == .live }
    }

    /// The last `sessions.list` failed (daemon restarting, connection dropped).
    /// `sessions` then holds the last good list, and the next try comes after
    /// `retryInterval`, not a full poll (HAIL-105).
    @Published private(set) var lastRefreshFailed = false

    private let client: KnockClient
    private let pollInterval: Duration
    private let retryInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var layoutWatch: AnyCancellable?

    init(
        client: KnockClient, pollInterval: Duration = .seconds(5), retryInterval: Duration = .seconds(1)
    ) {
        self.client = client
        self.pollInterval = pollInterval
        self.retryInterval = retryInterval
        layoutWatch = EvidenceLayoutLog.watch(self, as: "send.sessions")
    }

    /// Idempotent: `.task` re-runs this on every view re-appearance, but a
    /// poll loop already running should not be duplicated.
    func start() async {
        guard pollTask == nil else { return }
        await refresh()
        pollTask = Task { [weak self, pollInterval, retryInterval] in
            while !Task.isCancelled {
                guard let model = self else { return }
                let wait = model.lastRefreshFailed ? retryInterval : pollInterval
                try? await Task.sleep(for: wait)
                await model.refresh()
            }
        }
    }

    deinit { pollTask?.cancel() }

    /// Reads `sessions.list` now. Also called when the client reconnects, so a
    /// restarted daemon shows at once instead of on the next poll (HAIL-105).
    /// Writes only what changed, all after the await: a `@Published` write sends even when the value is
    /// equal, and each send re-renders every view that reads this model (WAG-363).
    func refresh() async {
        let list: [SessionInfo]
        do {
            list = try await client.sessionsList()
        } catch {
            // The clock keeps moving while the daemon is down, so the footer count and the durations do not freeze.
            now = Date()
            if !lastRefreshFailed { lastRefreshFailed = true }
            return
        }
        now = Date()
        if lastRefreshFailed { lastRefreshFailed = false }
        if sessions != list { sessions = list }
    }
}
