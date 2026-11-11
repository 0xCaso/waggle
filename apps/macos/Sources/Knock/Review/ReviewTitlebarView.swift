import SwiftUI

/// The review workspace titlebar (docs/design/mvp-values.md §2.2, §M4
/// `MYn95` → `Ykt5S`): back chevron, case title, project meta, a spacer, and
/// the Deadline chip.
///
/// The window uses `.windowStyle(.hiddenTitleBar)` (`KnockApp`), so the real
/// system traffic-light buttons already float over this bar's leading edge.
/// This view does not draw its own (Amendments: KNOCK-11's build showed two
/// sets); it only reserves the same leading space the queue header does
/// (KNOCK-08's `QueueListView`) so its own content starts clear of them.
struct ReviewTitlebarView: View {
    let knockCase: Case
    let task: KnockTask
    /// The session title, for the crumb (WAG-302).
    var sessionTitle: String? = nil
    /// Fed from `AppModel.now`, which ticks once a minute, so the idle
    /// label in `deadlineChip` stays current the same way a queue row's
    /// idle-time does (docs/design/mvp-values.md §M3/§M4).
    let now: Date
    /// The current round's reply, if `reply.replace` has changed it
    /// (docs/stories/HAIL-34.md 21:38: "shows 'changed 21:33' after it") -
    /// `CaseDetail.latestReplyChangedAtDate`, read by the caller since this
    /// view only ever carried a bare `Case`, not the full detail.
    var changedAt: Date? = nil
    /// When the newest plan round arrived (`CaseDetail.roundArrivedAtDate`); an update round carries its own time.
    var roundArrivedAt: Date? = nil
    let onBack: () -> Void
    /// The one-page layout's fold controls (HAIL-84). When set, `leadingControl` takes the
    /// back chevron's place, `trailingControls` follow the idle chip, and `leadingReserve`
    /// is the space kept clear of the traffic lights (they float over this bar's left edge
    /// once the queue is folded away).
    var leadingControl: AnyView? = nil
    var trailingControls: AnyView? = nil
    /// The Share button (WAG-387), before the trailing controls. `nil` shows none.
    var shareControl: AnyView? = nil
    var leadingReserve: CGFloat = Theme.Spacing.listHeaderLeadingReserve
    /// The title shows once per screen (WAG-333): the ask column carries it, so the bar shows it only
    /// when that column is folded away.
    var showsTitle = false

    /// The one crumb of the workspace (WAG-302): the pane's crumb builder, joined with a dot. The titlebar
    /// shows it as `TopBarCrumb` (C2); the ask column no longer repeats it.
    static func crumbText(task: KnockTask, sessionTitle: String?) -> String {
        AskCrumbs.breadcrumb(task: task, sessionTitle: sessionTitle, separator: " · ")
    }

    var body: some View {
        HStack(spacing: 14) {
            if let leadingControl {
                leadingControl
            } else {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Colors.ink2)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            // The title has priority (HAIL-91): when the bar is tight the times drop, whole,
            // before the title shortens. The last row is the title alone, which may truncate.
            ViewThatFits(in: .horizontal) {
                titleRow(showsTimes: true)
                titleRow(showsTimes: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            deadlineChip
            if let shareControl { shareControl }
            if let trailingControls { trailingControls }
        }
        .padding(EdgeInsets(top: 13, leading: leadingReserve, bottom: 13, trailing: 16))
        .background(Theme.Colors.side)
        .overlay(
            Rectangle().fill(Theme.Colors.line).frame(height: 1),
            alignment: .bottom
        )
    }

    private func titleRow(showsTimes: Bool) -> some View {
        HStack(spacing: 14) {
            // The project crumb, as in the case pane's top bar (C2): the decision column no longer repeats it.
            TopBarCrumb(task: task, sessionTitle: sessionTitle)
            if showsTitle {
                Text(knockCase.rowTitle)
                    .knockTextStyle(Theme.Typography.titlebarTitle13w600)
                    .foregroundColor(Theme.Colors.ink)
                    .lineLimit(1)
            }
            // "Arrived 21:14 · answered 21:30 · took 16m" (docs/stories/HAIL-34.md 21:38): the
            // same header meta the case pane's toolbar shows, beside the idle chip below.
            if showsTimes {
                Text(knockCase.headerMetaLabel(now: now, changedAt: changedAt, roundArrivedAt: roundArrivedAt))
                    .knockTextStyle(Theme.Typography.monoMeta12w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// "Claude Code · idle 14m" (docs/design/mvp-values.md §M4 `Ykt5S`):
    /// the same `IdleTime.label` the queue row uses, off the case's
    /// `created_at` (Choices ledger: the row itself prefers
    /// `updated_at ?? created_at`; this amendment named `created_at`
    /// specifically). The runtime name comes from the case's own `runtime`
    /// (KNOCK-20), not a hard-coded "Claude Code".
    private var deadlineChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 12))
                .foregroundColor(Theme.Colors.ink2)
            Text("\(knockCase.runtimeLabel) · \(IdleTime.label(since: knockCase.createdAtDate ?? now, now: now))")
                .knockTextStyle(Theme.Typography.deadlineChip12w600)
                .foregroundColor(Theme.Colors.ink2)
                .lineLimit(1)
        }
        .fixedSize()
        .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.chip)
    }
}
