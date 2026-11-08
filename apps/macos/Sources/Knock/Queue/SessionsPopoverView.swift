import AppKit
import SwiftUI

extension Theme.Typography {
    // Sessions popover (HAIL-59), Pen frames `bnDby` (list) and `wMdeP` (detail).
    static let sessionsTitle13w600 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 13).weight(.semibold), size: 13, lineHeight: nil, letterSpacing: nil
    )
    static let sessionsRowTitle12_5w600 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 12.5).weight(.semibold), size: 12.5, lineHeight: nil, letterSpacing: nil
    )
    static let sessionsBody12w400 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 12), size: 12, lineHeight: nil, letterSpacing: nil
    )
    static let sessionsBody12w600 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 12).weight(.semibold), size: 12, lineHeight: nil, letterSpacing: nil
    )
    static let sessionsFoot11w400 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 11), size: 11, lineHeight: nil, letterSpacing: nil
    )
    static let sessionsMono10_5 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.mono, size: 10.5), size: 10.5, lineHeight: nil, letterSpacing: nil
    )
}

extension SessionActivity.Kind {
    var dotColor: Color {
        switch self {
        case .needsYou: Theme.Colors.accent
        case .waitingForPickup, .working: Theme.Colors.ds
        case .idle: Theme.Colors.ok
        }
    }

    var tint: Color {
        switch self {
        case .needsYou: Theme.Colors.accentSoft
        case .waitingForPickup, .working: Theme.Colors.dsSoft
        case .idle: Theme.Colors.okSoft
        }
    }
}

/// The panel behind the footer's "Connected · N sessions" (HAIL-59). A list of
/// live sessions, and a detail view for one. Reads the same 5 s
/// `ConnectionModel` poll the footer already runs, so it stays live while open.
struct SessionsPopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var connection: ConnectionModel
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    /// The window's height, for the panel's height cap (HAIL-69).
    var windowHeight: CGFloat = 600

    /// Evidence hook (`KNOCK_SESSIONS_PANEL=detail:<n>`): open the n-th
    /// session's detail as soon as the list has loaded.
    var initialDetailIndex: Int?

    @State private var selectedSessionId: String?
    @State private var pendingDetailIndex: Int?
    @State private var copied = false

    private var openCases: [Case] { model.activeCases }
    private var live: [SessionInfo] { connection.liveSessions }

    var body: some View {
        CappedHeight(cap: SessionsPanelLayout.maxHeight(windowHeight: windowHeight)) {
            if let id = selectedSessionId, let session = live.first(where: { $0.id == id }) {
                detail(session)
            } else {
                list
            }
        }
        .onAppear { pendingDetailIndex = initialDetailIndex }
        .task { await Self.writeWindowShotIfAsked() }
        .onChange(of: live.map(\.id), initial: true) { _, ids in
            guard let index = pendingDetailIndex, index < ids.count else { return }
            selectedSessionId = ids[index]
            pendingDetailIndex = nil
        }
        .frame(width: 360)
        .background(Theme.Colors.win)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.Colors.line, lineWidth: 1))
        .shadow(color: Theme.Colors.shadowBlack.opacity(0.16), radius: 15, x: 0, y: 8)
    }

    /// Evidence hook (`KNOCK_EVIDENCE_WINDOW_SHOT=<png path>`): a few seconds
    /// after the panel opens, writes this app's own window to a PNG through
    /// `cacheDisplay`. It needs no screen-recording permission and captures
    /// nothing outside the app.
    private static func writeWindowShotIfAsked() async {
        guard let path = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_WINDOW_SHOT"] else { return }
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        guard let content = NSApp.windows.filter({ $0.isVisible || $0.contentView != nil })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })?.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions")
                    .knockTextStyle(Theme.Typography.sessionsTitle13w600)
                    .foregroundColor(Theme.Colors.ink)
                Spacer(minLength: 8)
                Text("\(live.count) running")
                    .knockTextStyle(Theme.Typography.monoMeta11w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
            FadingScroll {
                VStack(spacing: 0) {
                    ForEach(live) { session in
                        Rectangle().fill(Theme.Colors.line).frame(height: 1)
                        row(session)
                    }
                }
            }
            Rectangle().fill(Theme.Colors.line).frame(height: 1)
            HStack {
                Text("\(SessionActivity.closedInLastHour(connection.sessions, now: connection.now)) closed in the last hour")
                    .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                    .foregroundColor(Theme.Colors.ink3)
                Spacer(minLength: 8)
                Button(action: onOpenSettings) {
                    Text("All sessions in Settings")
                        .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                        .foregroundColor(Theme.Colors.ink2)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
        }
    }

    private func row(_ session: SessionInfo) -> some View {
        let activity = SessionActivity.make(session: session, cases: openCases, now: connection.now)
        let status = AgentStatus.forSession(session, cases: openCases)
        return Button(action: {
            selectedSessionId = session.id
            model.usage.record(.sessionDetailOpened)
        }) {
            HStack(alignment: SessionRowLayout.rowAlignment, spacing: 10) {
                PixelStatusGrid(pattern: status.pattern, color: status.color, cell: 4)
                    .padding(.top, SessionRowLayout.gridTopInset)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(SessionActivity.title(session))
                            .knockTextStyle(Theme.Typography.sessionsRowTitle12_5w600)
                            .foregroundColor(Theme.Colors.ink)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(session.runtimeLabel)
                            .knockTextStyle(Theme.Typography.sessionsMono10_5)
                            .foregroundColor(Theme.Colors.ink3)
                            .lineLimit(1)
                    }
                    if let title = SessionContextDisplay.rowTitle(session) {
                        Text(title)
                            .knockTextStyle(Theme.Typography.sessionsBody12w400)
                            .foregroundColor(Theme.Colors.ink2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    rowLine3(session: session, status: status, activity: activity)
                }
                Spacer(minLength: 4)
                VStack(alignment: SessionRowLayout.trailingAlignment, spacing: 2) {
                    Text(activity.lastSeenLabel)
                        .knockTextStyle(Theme.Typography.sessionsMono10_5)
                        .foregroundColor(Theme.Colors.ink3)
                    if let count = Self.countLabel(activity) {
                        Text(count.text)
                            .knockTextStyle(Theme.Typography.sessionsMono10_5)
                            .foregroundColor(count.urgent ? Theme.Colors.accent : Theme.Colors.ink3)
                    }
                }
                .padding(.top, SessionRowLayout.timeTopInset)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.Colors.ink3)
                    .padding(.top, SessionRowLayout.timeTopInset)
            }
            .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    /// Line 3 of a row (HAIL-72): today's status line when an ask needs you or
    /// a reply waits for pickup; else the plan step or the last action.
    @ViewBuilder
    private func rowLine3(session: SessionInfo, status: AgentStatus, activity: SessionActivity) -> some View {
        switch SessionContextDisplay.rowLine(activity: activity, context: session.context) {
        case .status:
            nowContent(session: session, status: status, activity: activity, bold: false)
        case .lastAction(let action):
            Text(action)
                .knockTextStyle(Theme.Typography.sessionsBody12w400)
                .foregroundColor(Theme.Colors.ink3)
                .lineLimit(1)
        case .plan(let done, let total, let text):
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .knockTextStyle(Theme.Typography.sessionsBody12w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.Colors.line)
                        Capsule().fill(Theme.Colors.ds)
                            .frame(width: proxy.size.width * CGFloat(done) / CGFloat(max(total, 1)))
                    }
                }
                .frame(height: SessionRowLayout.progressBarHeight)
            }
        }
    }

    /// "1 needs you" (hail) or "1 waiting on it" (ink-3); nothing when neither.
    static func countLabel(_ activity: SessionActivity) -> (text: String, urgent: Bool)? {
        if activity.needsYouCount > 0 { return ("\(activity.needsYouCount) needs you", true) }
        if activity.waitingCount > 0 { return ("\(activity.waitingCount) waiting on it", false) }
        return nil
    }

    // MARK: Detail

    private func detail(_ session: SessionInfo) -> some View {
        let activity = SessionActivity.make(session: session, cases: openCases, now: connection.now)
        let groups = SessionActivity.askGroups(
            open: SessionActivity.asks(for: session, in: openCases),
            answered: SessionActivity.asks(for: session, in: model.answeredCases), now: connection.now)
        let sections = SessionContextDisplay.sections(session: session, now: connection.now)
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: { selectedSessionId = nil }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Sessions").knockTextStyle(Theme.Typography.sessionsBody12w400)
                }
                .foregroundColor(Theme.Colors.ink2)
            }
            .buttonStyle(.plain).pointerCursor()
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 8, trailing: 14))

            HStack(spacing: 12) {
                PixelStatusGrid(
                    pattern: AgentStatus.forSession(session, cases: openCases).pattern,
                    color: AgentStatus.forSession(session, cases: openCases).color, cell: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SessionContextDisplay.headerTitle(session: session))
                        .knockTextStyle(Theme.Typography.sessionsTitle13w600)
                        .foregroundColor(Theme.Colors.ink)
                        .lineLimit(1)
                    Text(SessionContextDisplay.headerSubtitle(session: session, now: connection.now))
                        .knockTextStyle(Theme.Typography.sessionsMono10_5)
                        .foregroundColor(Theme.Colors.ink3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(EdgeInsets(top: 0, leading: 14, bottom: 12, trailing: 14))

            if let goal = sections.goal {
                sectionLabel("GOAL")
                Text(goal)
                    .knockTextStyle(Theme.Typography.sessionsBody12w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .lineLimit(2)
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 10, trailing: 14))
            }

            sectionLabel("NOW")
            VStack(alignment: .leading, spacing: 8) {
                nowCard(session: session, activity: activity, sections: sections)
                if let ask = SessionActivity.asks(for: session, in: openCases)
                    .filter({ $0.status == .waitingOnAgent }).max(by: { $0.createdAt < $1.createdAt }) {
                    PickupFallbackView(item: ask, style: .compact, pid: session.pid)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
                .background(RoundedRectangle(cornerRadius: Theme.Radius.recommendedBlock).fill(activity.kind.tint))
                .padding(.horizontal, 14)

            if !sections.recent.isEmpty {
                sectionLabel("RECENT").padding(.top, 10)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(sections.recent.enumerated()), id: \.offset) { _, action in
                        Text(action)
                            .knockTextStyle(Theme.Typography.sessionsBody12w400)
                            .foregroundColor(Theme.Colors.ink2)
                            .lineLimit(1)
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 4, trailing: 14))
            }

            if let changes = sections.changes {
                sectionLabel("CHANGES").padding(.top, 6)
                Text(changes)
                    .knockTextStyle(Theme.Typography.sessionsBody12w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .lineLimit(1)
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 4, trailing: 14))
            }

            sectionLabel("ITS REQUESTS TODAY · \(groups.total)").padding(.top, 6)
            FadingScroll(maxHeight: SessionsPanelLayout.askListHeight(
                rowCount: groups.total, dividerCount: groups.answered.isEmpty ? 0 : 1)) {
                VStack(spacing: 0) {
                    ForEach(groups.open) { row in
                        Rectangle().fill(Theme.Colors.line).frame(height: 1)
                        askRow(row)
                    }
                    if !groups.answered.isEmpty {
                        Rectangle().fill(Theme.Colors.line).frame(height: 1)
                        Text("Answered · \(groups.answered.count)")
                            .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                            .foregroundColor(Theme.Colors.ink3)
                            .frame(maxWidth: .infinity, minHeight: SessionsPanelLayout.dividerHeight - 1, alignment: .leading)
                    }
                    ForEach(groups.answered) { row in
                        Rectangle().fill(Theme.Colors.line).frame(height: 1)
                        askRow(row)
                    }
                    Rectangle().fill(Theme.Colors.line).frame(height: 1)
                }
                .padding(.horizontal, 14)
            }

            HStack(spacing: 8) {
                Button(action: {
                    model.sessionFilter = SessionFilter(taskId: session.taskId, label: SessionActivity.title(session))
                    onClose()
                }) {
                    Text("Show its decisions in the list")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                        .foregroundColor(Theme.Colors.onFill)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall).fill(Theme.Colors.ink))
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(session.taskId.isEmpty)
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.cwd, forType: .string)
                    copied = true
                }) {
                    Text(copied ? "Copied" : "Copy folder path")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                        .foregroundColor(Theme.Colors.ink)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall).fill(Theme.Colors.win))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall).stroke(Theme.Colors.line2, lineWidth: 1))
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(session.cwd.isEmpty)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        }
    }

    /// The NOW card. An ask that needs you, or a reply waiting for pickup, keeps
    /// today's status line (HAIL-72). Otherwise the first sentence of the
    /// agent's last message, with "Last: <action> · <time>" under it. With no
    /// context it is today's line.
    @ViewBuilder
    private func nowCard(
        session: SessionInfo, activity: SessionActivity, sections: SessionContextDisplay.Sections
    ) -> some View {
        if SessionContextDisplay.statusWins(activity) || !sections.hasNowContext {
            nowContent(
                session: session, status: AgentStatus.forSession(session, cases: openCases), activity: activity,
                bold: true, textColor: activity.kind == .idle ? Theme.Colors.ink2 : activity.kind.dotColor)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if let said = sections.said {
                    Text(said)
                        .knockTextStyle(Theme.Typography.sessionsBody12w600)
                        .foregroundColor(Theme.Colors.ink)
                        .lineLimit(2)
                }
                if let last = sections.lastLine {
                    Text(last)
                        .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The session's "now" line. While an agent works for you it is the
    /// status label and a live timer (HAIL-66); else the plain line of text.
    @ViewBuilder
    private func nowContent(
        session: SessionInfo, status: AgentStatus, activity: SessionActivity,
        bold: Bool, textColor: Color = Theme.Colors.ink2
    ) -> some View {
        if let since = AgentStatus.sessionTimerStart(session, cases: openCases), status != .closed {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ShimmerLabel(
                    text: status.shortLabel, font: .sans(12, bold ? .semibold : .regular), shimmers: status.shimmers,
                    base: status.shimmers ? Theme.Colors.ink3 : Theme.Colors.ink2)
                ElapsedTimer(since: since)
            }
        } else {
            Text(activity.nowLine)
                .knockTextStyle(bold ? Theme.Typography.sessionsBody12w600 : Theme.Typography.sessionsBody12w400)
                .foregroundColor(textColor)
                .lineLimit(1)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .knockTextStyle(Theme.Typography.labelCaps10_5w600)
            .foregroundColor(Theme.Colors.ink3)
            .padding(EdgeInsets(top: 0, leading: 14, bottom: 6, trailing: 14))
    }

    private func askRow(_ row: SessionAskRow) -> some View {
        let ask = row.ask
        let dot: Color = row.isAnswered ? Theme.Colors.ink3.opacity(0.5) : row.status.color
        let age = KnockDateFormat.date(from: ask.createdAt).map {
            CaseTimes.compactDuration(connection.now.timeIntervalSince($0))
        } ?? ""
        return Button(action: {
            Task { await model.open(caseId: ask.id, source: .sessionsPanel) }
            onClose()
        }) {
            HStack(alignment: .center, spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ask.rowTitle)
                        .knockTextStyle(Theme.Typography.sessionsBody12w400)
                        .foregroundColor(Theme.Colors.ink)
                        .lineLimit(1)
                    Text(row.stateLine)
                        .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                        .foregroundColor(row.status == .needsYou && !row.isAnswered ? Theme.Colors.accent : Theme.Colors.ink3)
                }
                Spacer(minLength: 4)
                Text(age)
                    .knockTextStyle(Theme.Typography.sessionsMono10_5)
                    .foregroundColor(Theme.Colors.ink3)
            }
            .frame(height: SessionsPanelLayout.askRowHeight - 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

/// Sizes its one child to its own height, but never proposes more than `cap`
/// (HAIL-69). `.frame(maxHeight:)` would fill the cap instead of hugging.
struct CappedHeight: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: proposal.width, height: min(cap, proposal.height ?? cap)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A vertical scroll view with a subtle fade at an edge that has more content
/// beyond it (HAIL-69). Takes the height its content needs, up to `maxHeight`.
struct FadingScroll<Content: View>: View {
    var maxHeight: CGFloat = .infinity
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    private let space = "fadingScroll"
    private let fade: CGFloat = 14

    /// The content's height, at most `maxHeight`. It gives way when the panel's own cap is lower.
    private var fitted: CGFloat { min(contentHeight, maxHeight) }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    content()
                    Color.clear.frame(height: 0).id("fadingScrollEnd")
                }
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { report(proxy) }
                        .onChange(of: proxy.frame(in: .named(space))) { _, _ in report(proxy) }
                })
            }
            .task {
                // Evidence hook (`KNOCK_SESSIONS_SCROLL=end`): a capture run cannot scroll the panel.
                guard ProcessInfo.processInfo.environment["KNOCK_SESSIONS_SCROLL"] == "end" else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                scroller.scrollTo("fadingScrollEnd", anchor: .bottom)
            }
        }
        .coordinateSpace(name: space)
        .frame(minHeight: 0, idealHeight: fitted, maxHeight: fitted)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { viewportHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, h in viewportHeight = h }
        })
        .overlay(alignment: .top) { edge(top: true).opacity(offset < -1 ? 1 : 0) }
        .overlay(alignment: .bottom) {
            edge(top: false).opacity(contentHeight + offset > viewportHeight + 1 ? 1 : 0)
        }
    }

    private func report(_ proxy: GeometryProxy) {
        let frame = proxy.frame(in: .named(space))
        offset = frame.minY
        contentHeight = frame.height
    }

    private func edge(top: Bool) -> some View {
        LinearGradient(
            colors: [Theme.Colors.win, Theme.Colors.win.opacity(0)],
            startPoint: top ? .top : .bottom, endPoint: top ? .bottom : .top)
            .frame(height: fade)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: offset)
    }
}

/// The "Showing <project> · <branch> · Clear" chip at the top of the queue.
struct SessionFilterChip: View {
    let filter: SessionFilter
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Showing \(filter.label)")
                .knockTextStyle(Theme.Typography.sessionsBody12w400)
                .foregroundColor(Theme.Colors.ink2)
                .lineLimit(1)
            Text("·").foregroundColor(Theme.Colors.ink3)
            Button(action: onClear) {
                Text("Clear")
                    .knockTextStyle(Theme.Typography.sessionsBody12w600)
                    .foregroundColor(Theme.Colors.ink)
            }
            .buttonStyle(.plain).pointerCursor()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.Colors.side))
        .overlay(Capsule().stroke(Theme.Colors.line, lineWidth: 1))
        .padding(EdgeInsets(top: 0, leading: 18, bottom: 8, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Closes the sessions panel on Esc or a click outside it (HAIL-59). A local
/// event monitor, because the panel is an in-window overlay and a click in the
/// detail pane never reaches the queue column's own views.
@MainActor
final class SessionsPopoverDismissMonitor {
    private var monitor: Any?

    /// `insideFrames` are in the window content's top-left coordinates.
    func start(insideFrames: @escaping () -> [CGRect], onClose: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { // Esc
                    onClose()
                    return nil
                }
                return event
            }
            guard let content = event.window?.contentView else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if !insideFrames().contains(where: { $0.contains(point) }) {
                onClose()
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
