import Foundation

/// The queue sidebar's footer label (HAIL-50 contract: "status dot +
/// 'Connected · N sessions' (or the offline state it already knows)"). A
/// pure function of the two inputs `QueueListView` already tracks, so it is
/// unit-testable without a running daemon.
enum QueueFooterStatus {
    static func label(isOffline: Bool, phase: PausedCopy.Phase = .paused, sessionCount: Int) -> String {
        guard !isOffline else { return PausedCopy.footer(phase) }
        return "Connected · \(sessionCount) session\(sessionCount == 1 ? "" : "s")"
    }

    /// Only live sessions count. `sessions.list` also returns every
    /// disconnected and ended session the daemon has ever seen, which once
    /// made the footer read "92 sessions" with one agent open.
    static func liveCount(_ sessions: [SessionInfo]) -> Int {
        sessions.filter { $0.state == .live }.count
    }
}
