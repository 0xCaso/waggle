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
    /// M11's whole-list "cached, read-only while offline" treatment: dims
    /// the row and swaps its fill for `$sel` (docs/design/mvp-values.md
    /// §2.3 "Cached/offline variant").
    let isOfflineCached: Bool
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

    /// Dims the row's text (M11 cached rows, the waiting group).
    private var rowOpacity: Double { (isOfflineCached || (isDimmed && !item.isDone)) ? 0.5 : 1 }

    /// A failed delivery or a reply stuck after its session ended still needs you, so its notice takes the
    /// meta line. Every other row shows the plain "project · agent · time" line.
    private var hasNotice: Bool {
        if item.showsSessionClosedMark { return true }
        if case .failed? = deliveryStatus { return true }
        return false
    }

    private var metaLine: some View {
        Text(row.meta)
            .knockTextStyle(Theme.Typography.caption11_5w400)
            .foregroundColor(Theme.Colors.ink3)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(optional: timeTooltip)
    }

    private var gotItButton: some View {
        Button(action: onGotIt) {
            Text("Got it")
                .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                .foregroundColor(Theme.Colors.ink)
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                .background(Theme.Colors.win)
                .cornerRadius(Theme.Radius.buttonSmall)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall).stroke(Theme.Colors.line2, lineWidth: 1))
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityLabel("Got it")
    }

    /// A small honey dot for a case with unseen team comments (WAG-394).
    private var unreadMark: some View {
        Circle()
            .fill(Theme.Colors.honey500)
            .frame(width: 8, height: 8)
            .help(unreadComments == 1 ? "1 new comment from your team" : "\(unreadComments) new comments from your team")
            .accessibilityLabel(unreadComments == 1 ? "1 new comment" : "\(unreadComments) new comments")
            .opacity(rowOpacity)
    }

    private var iconTile: some View {
        Image(systemName: row.icon?.systemImage ?? "")
            .font(.system(size: 12))
            .foregroundColor(Theme.Colors.ink3)
            .frame(width: 28, height: 28)
            .background(Theme.Colors.side)
            .cornerRadius(7)
            .help(row.icon?.label ?? "")
            .accessibilityLabel(row.icon?.label ?? "")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isSelected {
                Rectangle()
                    .fill(Theme.Colors.ink)
                    .frame(width: Theme.Spacing.selectionBarWidth)
                    .frame(maxHeight: .infinity)
            }
            HStack(alignment: .center, spacing: 10) {
                // The dot sits level with the title's first line, whether the title takes one line or two.
                HStack(alignment: .top, spacing: 10) {
                    RowDot(color: dotColor, pulses: row.dot == .working && !isOfflineCached)
                        .padding(.top, 6)
                        .opacity(isOfflineCached ? 0.5 : 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .knockTextStyle(Theme.AskDoc.Typography.sidebarRow14w600)
                            .foregroundColor(Theme.Colors.ink)
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
                .opacity(rowOpacity)
                if unreadComments > 0 { unreadMark }
                if item.isDone { gotItButton }
                if row.icon != nil {
                    iconTile.opacity(rowOpacity)
                }
            }
            .padding(EdgeInsets(top: 11, leading: isFollowUp ? 32 : 18, bottom: 11, trailing: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isOfflineCached ? Theme.Colors.sel : (isSelected ? Theme.Colors.honeySoft : Color.clear))
        .overlay(
            Rectangle()
                .fill(isSelected ? Theme.Colors.line2 : Theme.Colors.line)
                .frame(height: 1),
            alignment: .bottom
        )
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
                    .knockTextStyle(Theme.Typography.keyHint10_5w400)
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
                .foregroundColor(Theme.Colors.ink3)
            Text(SessionClosedCopy.mark)
                .knockTextStyle(Theme.Typography.keyHint10_5w400)
                .foregroundColor(Theme.Colors.ink3)
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
/// (same padding, same title and meta styles, same hairline). "Your agent is on it" uses it (WAG-341).
struct QueueStatusRow: View {
    let dotColor: Color
    var pulses = false
    let title: String
    let meta: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RowDot(color: dotColor, pulses: pulses)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .knockTextStyle(Theme.AskDoc.Typography.sidebarRow14w600)
                    .foregroundColor(Theme.Colors.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(meta)
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
        .accessibilityElement(children: .combine)
    }
}
