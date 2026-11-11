import SwiftUI

/// One row in the Needs you / Waiting on agent queue
/// (docs/design/mvp-values.md §2.3 "Queue row", §M3 `aWM03` →
/// `YuTyu`/`m4nqBm`/`puoVO`, and the dimmed M11 variant `SyfHH` →
/// `TjolE`/`kCROx`).
struct QueueRowView: View {
    let item: Case
    /// `AppModel.now`, for the update line's age.
    var now: Date = Date()
    let sessionLabel: String
    /// The descriptive title of the ask's session (WAG-279), nil when only the folder name is known.
    var sessionTitle: String? = nil
    /// The row header's time: how long ago a pending ask arrived ("5m ago")
    /// or how long ago you answered it ("answered 2h ago").
    let timeLabel: String
    /// The full date and time behind `timeLabel`, shown as a native tooltip
    /// on hover (the "ago" form loses the exact moment).
    let timeTooltip: String?
    let isSelected: Bool
    let isUrgent: Bool
    /// The `waiting_on_agent` group's own dimming (KNOCK-08 AC): opacity
    /// only, no `$sel` fill swap - the row stays selectable and keeps its
    /// normal selected/unselected fill.
    let isDimmed: Bool
    let artifactKind: ArtifactKind?
    /// The compact Delivered/Failed/Waiting state (docs/design/mvp-values.md
    /// §M8 panel 2's "QUEUE ROW" mockup, Amendment 2 KNOCK-13 fold; waiting
    /// added in docs/stories/HAIL-32.md) - nil until a `reply.state_changed`
    /// event names this case as delivered or failed. A `waiting_on_agent`
    /// case with a nil status here shows the "Waiting for pickup" spinner
    /// (`deliveryBadge`); every other status/kind combination is blank, same
    /// as the row's other optional metadata.
    let deliveryStatus: DeliveryState?
    /// True when this row is a follow-up grouped directly under its earlier
    /// ask (HAIL-33 amendment): a small extra leading indent, nothing else.
    var isFollowUp: Bool = false
    /// Unseen team comments on this case (WAG-394). 0 shows nothing.
    var unreadComments: Int = 0
    let onRetryDelivery: () -> Void
    /// The row's context-menu Dismiss action (HAIL-32).
    let onDismiss: () -> Void
    /// The Got it button of a done row (HAIL-152): closes the ask, sends nothing to the agent.
    var onGotIt: () -> Void = {}

    private var row: RequestRowModel { RequestRowModel(item: item, timeLabel: timeLabel, artifactKind: artifactKind, sessionTitle: sessionTitle) }

    private var dotColor: Color {
        switch row.dot {
        case .needsYou: Theme.Colors.accent
        case .working: Theme.Colors.ds
        case .done: Theme.Colors.ok
        }
    }

    /// Mockup B `.row.done`: an answered row (still held by the agent, or done) has a 500 ink2 title.
    private var isAnsweredLook: Bool { isDimmed || item.isDone }

    /// A failed delivery or a reply stuck after its session ended still needs you, so its notice takes the
    /// meta line. Every other row shows the plain "project · agent · time" line.
    private var hasNotice: Bool {
        if item.showsSessionClosedMark { return true }
        if case .failed? = deliveryStatus { return true }
        return false
    }

    private var metaLine: some View {
        Text(row.meta)
            .knockTextStyle(Theme.AskDoc.Chrome.rowMeta)
            .foregroundColor(Theme.AskDoc.Colors.quiet)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(optional: timeTooltip)
    }

    private var gotItButton: some View {
        Button(action: onGotIt) {
            // The case map's `.btn-s`.
            Text("Got it")
                .knockTextStyle(Theme.AskDoc.Chrome.smallButton)
                .foregroundColor(Theme.Colors.ink)
                .padding(Theme.AskDoc.Chrome.smallButtonInset)
                .background(Theme.Colors.win)
                .cornerRadius(Theme.AskDoc.Chrome.smallButtonRadius)
                .overlay(RoundedRectangle(cornerRadius: Theme.AskDoc.Chrome.smallButtonRadius).stroke(Theme.Colors.line2, lineWidth: 1))
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityLabel("Got it")
    }

    /// A small honey dot for a case with unseen team comments (WAG-394).
    private var unreadMark: some View {
        Circle()
            .fill(Theme.Colors.honey500)
            .frame(width: Theme.AskDoc.Chrome.dotSize, height: Theme.AskDoc.Chrome.dotSize)
            .help(unreadComments == 1 ? "1 new comment from your team" : "\(unreadComments) new comments from your team")
            .accessibilityLabel(unreadComments == 1 ? "1 new comment" : "\(unreadComments) new comments")
    }

    /// The artifact kind (no mockup counterpart): a plain quiet glyph, as quiet as the meta line.
    private var iconTile: some View {
        Image(systemName: row.icon?.systemImage ?? "")
            .font(.system(size: 12))
            .foregroundColor(Theme.AskDoc.Colors.quiet)
            .frame(width: 18, height: 18)
            .help(row.icon?.label ?? "")
            .accessibilityLabel(row.icon?.label ?? "")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // `.row`: the dot on the title's first baseline, 9 to the text; the title wraps to two lines.
            HStack(alignment: .firstTextBaseline, spacing: Theme.AskDoc.Chrome.rowGap) {
                RowDot(color: dotColor, pulses: row.dot == .working)
                    .sidebarDotOnBaseline()
                VStack(alignment: .leading, spacing: Theme.AskDoc.Chrome.rowMetaGap) {
                    Text(row.title)
                        .knockTextStyle(isAnsweredLook ? Theme.AskDoc.Chrome.rowTitleDone : Theme.AskDoc.Chrome.rowTitle)
                        .foregroundColor(isAnsweredLook ? Theme.Colors.ink2 : Theme.Colors.ink)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if hasNotice {
                        notice
                    } else {
                        metaLine
                    }
                }
            }
            if unreadComments > 0 { unreadMark }
            if item.isDone { gotItButton }
            if row.icon != nil {
                iconTile
            }
        }
        .padding(EdgeInsets(
            top: Theme.AskDoc.Chrome.rowInset.top, leading: Theme.AskDoc.Chrome.rowInset.leading + (isFollowUp ? 14 : 0),
            bottom: Theme.AskDoc.Chrome.rowInset.bottom, trailing: Theme.AskDoc.Chrome.rowInset.trailing))
        .frame(maxWidth: .infinity, alignment: .leading)
        // `.row.sel`: white, a 3 pt honey bar on the left, no line between rows.
        .background(isSelected ? Theme.AskDoc.Chrome.selectedFill : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Theme.AskDoc.Chrome.selectedBar).frame(width: Theme.AskDoc.Chrome.selectedBarWidth)
            }
        }
        .contextMenu {
            Button(item.isDone ? "Got it" : "Dismiss", action: item.isDone ? onGotIt : onDismiss)
        }
    }

    @ViewBuilder
    private var notice: some View {
        // One mark for every case the closed session holds up (WAG-258): an open ask, an answer saved for
        // it, a failed reply. A failed reply on a session that is not ended keeps its Retry.
        if item.showsSessionClosedMark {
            sessionClosedBadge
        } else if case .failed? = deliveryStatus {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                Text("Delivery failed · Retry")
                    .knockTextStyle(Theme.AskDoc.Chrome.rowMeta)
            }
            .foregroundColor(Theme.Colors.accent)
            .contentShape(Rectangle())
            .onTapGesture(perform: onRetryDelivery).pointerCursor()
        }
    }

    /// The small "Session closed" mark (WAG-258). It replaces the HAIL-44 "Not picked up" badge: the
    /// session ended, the answer is saved, and nothing here asks the person to act.
    private var sessionClosedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 10))
                .foregroundColor(Theme.AskDoc.Colors.quiet)
            Text(SessionClosedCopy.mark)
                .knockTextStyle(Theme.AskDoc.Chrome.rowMeta)
                .foregroundColor(Theme.AskDoc.Colors.quiet)
        }
        .accessibilityElement(children: .combine)
    }
}


/// The row's state dot. A row an agent is working on pulses: a ring grows out of the dot and fades,
/// so it reads as "in progress" at a glance. Still when Reduce Motion is on.
struct RowDot: View {
    let color: Color
    let pulses: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay {
                if pulses && !reduceMotion {
                    PulseRing(color: color, lineWidth: 1.5, opacity: 0.8, scale: 2.4)
                }
            }
    }
}

/// A queue row that is not a case: a state dot, a title and one meta line, drawn exactly like `QueueRowView`
/// (same padding, same title and meta styles). "Your agent is on it" uses it (WAG-341).
struct QueueStatusRow: View {
    let dotColor: Color
    var pulses = false
    let title: String
    let meta: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.AskDoc.Chrome.rowGap) {
            RowDot(color: dotColor, pulses: pulses)
                .sidebarDotOnBaseline()
            VStack(alignment: .leading, spacing: Theme.AskDoc.Chrome.rowMetaGap) {
                Text(title)
                    .knockTextStyle(Theme.AskDoc.Chrome.rowTitle)
                    .foregroundColor(Theme.Colors.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(meta)
                    .knockTextStyle(Theme.AskDoc.Chrome.rowMeta)
                    .foregroundColor(Theme.AskDoc.Colors.quiet)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(Theme.AskDoc.Chrome.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
