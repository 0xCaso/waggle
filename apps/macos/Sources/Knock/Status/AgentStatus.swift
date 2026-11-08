import Foundation
import SwiftUI

/// The six states an ask or a session can show (HAIL-62 named them, HAIL-66
/// draws them as a pixel grid, a shimmering label and a live timer).
enum AgentStatus: String, CaseIterable, Sendable {
    case needsYou
    case waitingForPickup
    case working
    case writingToYou
    case connected
    case closed
}

// MARK: - Mapping

extension AgentStatus {
    /// The status of one ask (HAIL-62). A case that needs you is `needsYou`.
    /// A case waiting on the agent depends on where its reply is: session gone
    /// -> `closed`; reply delivered -> `working`, or `writingToYou` when the
    /// delivered reply asked for more detail; otherwise the reply is still
    /// queued (or failed, or replaced) -> `waitingForPickup`. A resolved ask
    /// is `closed`. `deliveryStatus` is the app's live event view: it can know
    /// about a delivery before the case row does.
    static func forCase(_ item: Case, deliveryStatus: DeliveryState? = nil) -> AgentStatus {
        switch item.status {
        case .needsYou:
            return .needsYou
        case .resolved:
            return .closed
        case .waitingOnAgent:
            if item.isDone { return .closed }
            if let session = item.sessionState, session != .live { return .closed }
            var delivered = item.latestReplyState == .delivered
            if case .delivered? = deliveryStatus { delivered = true }
            guard delivered else { return .waitingForPickup }
            return item.isTalkingItOver ? .writingToYou : .working
        }
    }

    /// The status of one session. A session with an ask that needs you is
    /// `needsYou`. Else, with asks waiting on it, the status of the newest of
    /// those asks. Else `working` when live with a transcript that is still growing
    /// (HAIL-124: busy, no asks), `connected` when live, `closed` when not.
    static func forSession(_ session: SessionInfo, cases: [Case]) -> AgentStatus {
        let asks = SessionActivity.asks(for: session, in: cases)
        if asks.contains(where: { $0.status == .needsYou }) { return .needsYou }
        if let newest = newestWaitingAsk(asks) { return forCase(newest) }
        guard session.state == .live else { return .closed }
        return isBusyWithoutAsk(session) ? .working : .connected
    }

    /// A live session with no ask waiting whose transcript is still growing.
    static func isBusyWithoutAsk(_ session: SessionInfo) -> Bool {
        session.state == .live && session.context?.growing == true
    }

    /// True when `forSession` gave `working` only because the session is busy, with no ask behind it.
    static func isBusy(_ session: SessionInfo, cases: [Case]) -> Bool {
        let asks = SessionActivity.asks(for: session, in: cases)
        return isBusyWithoutAsk(session) && !asks.contains { $0.status == .needsYou || ($0.status == .waitingOnAgent && !$0.isDone) }
    }

    private static func newestWaitingAsk(_ asks: [Case]) -> Case? {
        asks.filter { $0.status == .waitingOnAgent && !$0.isDone }.max(by: { $0.createdAt < $1.createdAt })
    }

    /// HAIL-178: the latest sign that a session did something: its last ask, your last reply, the
    /// agent's last check, the last action the transcript shows and the last event the plugin hooks
    /// reported. A heartbeat (`lastSeenAt`) is not activity. Nil when there is none.
    static func lastActivity(_ session: SessionInfo, cases: [Case]) -> Date? {
        var dates: [Date] = []
        for ask in SessionActivity.asks(for: session, in: cases) {
            dates.append(contentsOf: [ask.createdAtDate, ask.latestReplyAtDate, ask.lastCheckAtDate].compactMap { $0 })
        }
        if let at = session.context?.lastActionAt.flatMap(KnockDateFormat.date(from:)) { dates.append(at) }
        if let at = session.context?.live?.lastEventAt, let date = KnockDateFormat.date(from: at) { dates.append(date) }
        return dates.max()
    }

    /// When the timer of a session's status starts: the timer start of the ask
    /// that decides the status. Nil when no ask waits on the agent.
    static func sessionTimerStart(_ session: SessionInfo, cases: [Case]) -> Date? {
        let asks = SessionActivity.asks(for: session, in: cases)
        guard !asks.contains(where: { $0.status == .needsYou }), let newest = newestWaitingAsk(asks) else { return nil }
        return timerStart(newest, status: forCase(newest), deliveryStatus: nil)
    }

    /// When the timer of this status starts: the pickup time once the agent
    /// read the reply, else the send time. Nil for a status with no timer.
    static func timerStart(_ item: Case, status: AgentStatus, deliveryStatus: DeliveryState?) -> Date? {
        switch status {
        case .working, .writingToYou:
            if case .delivered(let at)? = deliveryStatus { return at }
            return item.latestReplyDeliveredAtDate ?? item.latestReplyAtDate
        case .waitingForPickup:
            return item.latestReplyAtDate
        case .needsYou, .connected, .closed:
            return nil
        }
    }

    /// The status the footer shows for a set of sessions: the busiest one.
    /// working > writing > pickup > idle. A session that needs you, is idle
    /// or is closed reads as idle here: the footer shows what agents do.
    static func busiest(_ statuses: [AgentStatus]) -> AgentStatus {
        for status in [AgentStatus.working, .writingToYou, .waitingForPickup] where statuses.contains(status) {
            return status
        }
        return .connected
    }

    /// Sessions whose agent is busy for you (working or writing).
    static func workingCount(_ statuses: [AgentStatus]) -> Int {
        statuses.filter { $0 == .working || $0 == .writingToYou }.count
    }
}

// MARK: - Look and copy

extension AgentStatus {
    /// Grid pattern, colour and label of the status (Pen `ROZvW`).
    var pattern: PixelPattern {
        switch self {
        case .needsYou: .still(0.9)
        case .waitingForPickup: .dots(duration: 1.3)
        case .working: .drive
        case .writingToYou: .orbit
        case .connected: .still(0.28)
        case .closed: .still(0.12)
        }
    }

    var color: Color {
        switch self {
        case .needsYou: Theme.Colors.accent
        case .waitingForPickup: Theme.Colors.ink3
        case .working: Theme.Colors.ink
        case .writingToYou: Theme.Colors.writing
        case .connected: Theme.Colors.ok
        case .closed: Theme.Colors.ink3
        }
    }

    /// The short label next to the grid.
    var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .waitingForPickup: "Not picked up yet"
        case .working: "Working"
        case .writingToYou: "Writing the detail you asked for"
        case .connected: "Idle"
        case .closed: "Closed"
        }
    }

    /// The label where the row leaves little room (sessions panel, Settings).
    var shortLabel: String {
        switch self {
        case .waitingForPickup: "Not picked up"
        case .writingToYou: "Writing the detail"
        default: label
        }
    }

    /// Only an agent at work shimmers its label.
    var shimmers: Bool { self == .working || self == .writingToYou }

    /// Colour of the label text when it does not shimmer.
    var labelColor: Color { self == .needsYou ? Theme.Colors.accent : Theme.Colors.ink2 }
}
