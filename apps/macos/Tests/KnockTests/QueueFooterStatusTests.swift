import Testing
@testable import Knock

/// HAIL-50 contract test: "the footer label text" - the queue sidebar's
/// footer row, "Connected · N sessions" or the offline state.
struct QueueFooterStatusTests {
    @Test func offlineIgnoresTheSessionCount() {
        #expect(QueueFooterStatus.label(isOffline: true, sessionCount: 3) == "Paused")
    }

    @Test func onlineWithNoSessionsReadsSingularlyCorrect() {
        #expect(QueueFooterStatus.label(isOffline: false, sessionCount: 0) == "Connected · 0 sessions")
    }

    @Test func onlineWithOneSessionIsSingular() {
        #expect(QueueFooterStatus.label(isOffline: false, sessionCount: 1) == "Connected · 1 session")
    }

    @Test func onlineWithManySessionsIsPlural() {
        #expect(QueueFooterStatus.label(isOffline: false, sessionCount: 2) == "Connected · 2 sessions")
    }

    private func session(_ id: String, _ state: SessionState) -> SessionInfo {
        SessionInfo(
            id: id, runtime: .claude, taskName: "t", project: "p", branch: nil, state: state,
            connectedAt: "2026-09-29T10:00:00.000Z", lastSeenAt: "2026-09-29T10:00:00.000Z"
        )
    }

    @Test func liveCountIgnoresDisconnectedAndEndedSessions() {
        let sessions = [session("a", .live)] + (0..<88).map { session("d\($0)", .disconnected) }
            + (0..<5).map { session("e\($0)", .ended) }
        #expect(QueueFooterStatus.liveCount(sessions) == 1)
    }

    @Test func connectionListsLiveSessions() {
        let sessions = [session("a", .live), session("b", .live)]
            + (0..<8).map { session("d\($0)", .disconnected) }
        #expect(ConnectionModel.live(sessions).map(\.id) == ["a", "b"])
    }
}
