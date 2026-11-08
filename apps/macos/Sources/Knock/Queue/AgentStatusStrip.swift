import SwiftUI

/// The words on the ask pane's status strip (HAIL-66). Pure, so the copy is
/// unit-tested. Plain and friendly, no em-dashes.
enum AgentStatusCopy {
    /// The strip's label; nil for a status that has no strip (an ask that
    /// still needs you, a connected session).
    static func headline(status: AgentStatus, runtime: String, item: Case?) -> String? {
        if status == .closed, let item { return SessionClosedCopy.stripHeadline(for: item) }
        if status == .working, item?.isFeedbackReply == true { return "\(runtime) is working on your feedback" }
        return headline(status: status, runtime: runtime)
    }

    static func headline(status: AgentStatus, runtime: String) -> String? {
        switch status {
        case .working: "\(runtime) is working on your reply"
        case .waitingForPickup: "\(runtime) has not picked up your reply yet"
        case .writingToYou: "\(runtime) is writing the detail you asked for"
        case .closed: "The session closed before it read your reply"
        case .needsYou, .connected: nil
        }
    }

    /// "16:05" in the given zone.
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The settled line of an answered ask (HAIL-104): no timer, no live status.
    static func settledLine(pickedUpAt: Date?, timeZone: TimeZone = .current) -> String {
        guard let pickedUpAt else { return "Not picked up" }
        return "Picked up at \(clock(pickedUpAt, timeZone: timeZone))"
    }

    /// "Followed up: <title>", the link under the settled line.
    static func followUpLine(_ followUp: AnswerGrouping.Settled.FollowUp) -> String {
        "Followed up: \(AgentMarkdown.singleLine(followUp.title))"
    }

    /// The mono text on the right of the strip: "read at 16:05" once the agent
    /// read the reply. Nothing while it has not.
    static func readLine(readAt: Date?, afterNudge: Bool = false, timeZone: TimeZone = .current) -> String? {
        guard let readAt else { return nil }
        let read = "read at \(clock(readAt, timeZone: timeZone))"
        return afterNudge ? "\(Nudge.wokeReadPrefix) · \(read)" : read
    }
}

/// The settled status of an answered ask (HAIL-104): a still grid, "Picked up at 21:05" and,
/// when a follow-up ask exists, a link that opens it. No timer, no shimmer.
struct SettledAnswerLine: View {
    let settled: AnswerGrouping.Settled
    var onOpenCase: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentStatusLine(
                status: .closed, cell: 5, label: AgentStatusCopy.settledLine(pickedUpAt: settled.pickedUpAt),
                since: nil, labelFont: .sans(12.5), spacing: 10)
            if let followUp = settled.followUp {
                Button { onOpenCase(followUp.id) } label: {
                    Text(AgentStatusCopy.followUpLine(followUp))
                        .knockTextStyle(Theme.Typography.recommendLine12w400)
                        .foregroundColor(Theme.Colors.ds)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
    }
}

/// The one-line status strip under the ask pane's header when the open ask
/// waits on the agent (HAIL-66): a 5 pt grid, a shimmering label, a timer since
/// the pickup (or the send) and "read at HH:mm" on the right.
struct AgentStatusStrip: View {
    let status: AgentStatus
    let runtime: String
    /// Starts the timer: the pickup time, else the send time.
    let since: Date?
    let readAt: Date?
    /// The ask, for the pickup fallback buttons (HAIL-76).
    var item: Case?
    /// Non-nil when the ask is answered (`AnswerGrouping.staysWaiting` is false): the strip
    /// shows the settled line instead of the live status.
    var settled: AnswerGrouping.Settled?
    var onOpenCase: (String) -> Void = { _ in }

    @Environment(\.nudge) private var nudge

    private func statusLine(_ headline: String, since: Date?) -> some View {
        AgentStatusLine(
            status: status, cell: 5, label: headline, since: since,
            labelFont: .sans(12.5), spacing: 10)
    }

    private var woke: Bool { item.map { Nudge.wokeUp(item: $0, record: nudge.records[$0.id]) } ?? false }

    @ViewBuilder private var readText: some View {
        if let readLine = AgentStatusCopy.readLine(readAt: readAt, afterNudge: woke) {
            Text(readLine)
                .knockTextStyle(Theme.Typography.monoMeta11w400)
                .foregroundColor(Theme.Colors.ink3)
        }
    }

    /// The pickup fallback buttons, only while the reply waits for pickup.
    @ViewBuilder private var fallback: some View {
        if status == .waitingForPickup, let item {
            PickupFallbackView(item: item, style: .strip)
        }
    }

    @ViewBuilder private var trailing: some View {
        readText
        fallback
    }

    var body: some View {
        if let settled, AgentStatusCopy.headline(status: status, runtime: runtime) != nil {
            SettledAnswerLine(settled: settled, onOpenCase: onOpenCase)
                .padding(EdgeInsets(top: 10, leading: 32, bottom: 10, trailing: 32))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AgentStatus.closed.color.opacity(0.04))
                .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { context in strip(now: context.date) }
        }
    }

    /// The strip's headline and timer start. A nudge does not change them: the
    /// waiting timer keeps counting from the send (HAIL-129).
    private func copy(now: Date) -> (headline: String, since: Date?)? {
        guard let headline = AgentStatusCopy.headline(status: status, runtime: runtime, item: item) else { return nil }
        return (headline, since)
    }

    @ViewBuilder private func strip(now: Date) -> some View {
        if let (headline, since) = copy(now: now) {
            ViewThatFits(in: .horizontal) {
                // One line when the whole headline and the buttons fit; else the
                // buttons drop under the headline so it is never cut short.
                HStack(alignment: .center, spacing: 10) {
                    statusLine(headline, since: since).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    trailing
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        statusLine(headline, since: since)
                        Spacer(minLength: 8)
                        readText
                    }
                    fallback
                }
            }
            .padding(EdgeInsets(top: 10, leading: 32, bottom: 10, trailing: 32))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(status.color.opacity(status == .closed ? 0.04 : 0.07))
            .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
        }
    }
}
