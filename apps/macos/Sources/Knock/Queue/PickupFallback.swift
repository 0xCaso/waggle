import AppKit
import Darwin
import SwiftUI

/// The fallback for a reply the agent has not picked up (HAIL-76). A reply only
/// leaves `queued` when the agent calls `knock_ask` or `knock_check`, so an agent
/// that ended its turn never sees it. Two actions help the human: copy a one-line
/// prompt to paste into the agent's terminal, and bring the terminal app to the
/// front. Neither changes the reply, sends keystrokes or uses AppleScript.
enum PickupFallback {
    /// The line the human pastes in the agent's terminal.
    static let prompt = "Check Waggle for my reply"

    /// How long a reply must be queued before the actions show.
    static let threshold: TimeInterval = 120

    enum Mode: Equatable {
        /// Nothing to offer: not waiting, already picked up, or under 2 minutes.
        case none
        /// The session may be running: copy the prompt, show the terminal.
        case live
        /// The session ended: only the prompt, for a new session.
        case closed
    }

    /// Whether the fallback shows for `item` at `now`. A queued reply in a live
    /// session shows it after `threshold`. A queued reply whose session is not
    /// live (disconnected or ended) shows the closed variant at once, the same
    /// test `AgentStatus.forCase` uses for its "Closed" status, so the strip and
    /// the fallback never disagree.
    static func mode(for item: Case, now: Date) -> Mode {
        // WAG-267: a delivered answer the agent has not acted on gets the same two actions at once.
        if item.latestReplyState == .delivered, item.latestReplyApplyState == .notApplied, !item.isDone {
            if let session = item.sessionState, session != .live { return .closed }
            return .live
        }
        guard item.status == .waitingOnAgent, item.latestReplyState == .queued, !item.isDone,
              let sentAt = item.latestReplyAtDate else { return .none }
        if let session = item.sessionState, session != .live { return .closed }
        return now.timeIntervalSince(sentAt) >= threshold ? .live : .none
    }

    /// What the fallback offers for `item` (HAIL-173). A Claude app or Cowork case offers "Copy reply"
    /// (the HAIL-170 line) after the same 2 minutes; Claude Code and Codex keep "Copy prompt".
    enum Kind: Equatable {
        case none
        case copyReply
        case copyPrompt(Mode)
    }

    static func kind(for item: Case, now: Date) -> Kind {
        if item.isDesktopClient {
            return ClaudeCheck.state(for: item, now: now) == .notChecking ? .copyReply : .none
        }
        let mode = mode(for: item, now: now)
        return mode == .none ? .none : .copyPrompt(mode)
    }

    /// The help line above the prompt.
    static func helpLine(mode: Mode, runtime: String) -> String? {
        switch mode {
        case .none: nil
        case .live: "It may have stopped to wait. Paste this line in its terminal:"
        case .closed: "Start \(runtime) again in this project and paste this line:"
        }
    }

    static func copiedLine(runtime: String) -> String { "Copied. Paste it in the \(runtime) terminal." }

    static func noTerminalLine(runtime: String, project: String) -> String {
        "Waggle could not find its terminal window. Look for the \(runtime) tab in the \(project) project."
    }

    @discardableResult
    static func copyPrompt(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(prompt, forType: .string)
    }
}

/// Finds the terminal app of a session from the shim's parent pid (the agent
/// process): walks up the process tree to the first regular macOS app. A tmux
/// server or a daemonized terminal has no such ancestor, and then there is no
/// terminal to show.
enum TerminalLocator {
    static let maxDepth = 16

    /// The parent of `pid`, or nil when the process is gone.
    static func parentPid(of pid: Int) -> Int? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int(info.pbi_ppid)
    }

    /// True when `pid` is a regular (Dock) app, not a background helper.
    static func isRegularApp(_ pid: Int) -> Bool {
        NSRunningApplication(processIdentifier: pid_t(pid))?.activationPolicy == .regular
    }

    /// The pid of the first ancestor of `pid` (starting at `pid` itself) that
    /// is a regular app. Injectable so tests need no real process tree.
    static func appPid(
        startingAt pid: Int,
        parentOf: (Int) -> Int? = parentPid(of:),
        isApp: (Int) -> Bool = isRegularApp
    ) -> Int? {
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1 else { return nil }
            if isApp(current) { return current }
            guard let parent = parentOf(current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// Brings the terminal app to the front. False when there is none.
    @discardableResult
    static func show(startingAt pid: Int) -> Bool {
        guard let found = appPid(startingAt: pid),
              let app = NSRunningApplication(processIdentifier: pid_t(found)) else { return false }
        return app.activate()
    }
}

private struct SessionPidByTaskIdKey: EnvironmentKey {
    static let defaultValue: [String: Int] = [:]
}

extension EnvironmentValues {
    /// Live sessions' parent pids by task id (`AppModel.sessionPidByTaskId`), so
    /// the panes reach "Show the terminal" without a model of their own.
    var sessionPidByTaskId: [String: Int] {
        get { self[SessionPidByTaskIdKey.self] }
        set { self[SessionPidByTaskIdKey.self] = newValue }
    }
}

/// The two fallback actions for one reply, in a block (help line, the prompt,
/// buttons) for the panes and a compact strip for rows and the sessions panel.
struct PickupFallbackView: View {
    /// `block`: the panes' column. `strip`: buttons at the trailing edge of the
    /// ask pane's status strip. `link`: one blue text action ending a queue row's
    /// status line. `compact`: small pill buttons under the NOW text of the
    /// sessions panel, with the paste line above them.
    enum Style { case block, strip, link, compact }

    let item: Case
    var style: Style = .block
    /// The session's parent pid when the caller has it; else the environment's.
    var pid: Int?

    @Environment(\.sessionPidByTaskId) private var pids
    @Environment(\.nudge) private var nudge
    @State private var copied = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            // HAIL-173: the Claude app and Cowork get the HAIL-170 fallback, never "Copy prompt".
            switch PickupFallback.kind(for: item, now: context.date) {
            case .none: EmptyView()
            case .copyReply: desktopContent
            case .copyPrompt(let mode):
                content(mode: mode, phase: nudge.phase(for: item, mode: mode, now: context.date))
            }
        }
    }

    private var record: NudgeRecord? { nudge.records[item.id] }

    /// "Claude is not checking" with "Copy reply", in the style the caller asked for. The block is the
    /// HAIL-170 card itself, so the ask column and every pane show one thing.
    @ViewBuilder
    private var desktopContent: some View {
        switch style {
        case .block:
            ClaudeCheckView(item: item, state: .notChecking)
        case .link:
            HStack(spacing: 8) {
                Text(copied ? ClaudeCheck.copiedLine(for: item) : ClaudeCheck.notCheckingShort)
                    .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                    .fontWeight(.semibold)
                    .foregroundColor(copied ? Theme.Colors.ok : Theme.Colors.accent)
                    .lineLimit(1)
                Button(action: copyReply) {
                    Text(copied ? "Copied" : ClaudeCheck.copyReplyLabel)
                        .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                        .fontWeight(.semibold)
                        .foregroundColor(Theme.Colors.ds)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .fixedSize()
        case .strip, .compact:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(copied ? ClaudeCheck.copiedLine(for: item) : ClaudeCheck.notCheckingShort)
                        .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                        .foregroundColor(copied ? Theme.Colors.ok : Theme.Colors.accent)
                    fallbackButton(copied ? "Copied" : ClaudeCheck.copyReplyLabel, primary: true, action: copyReply)
                }
            }
        }
    }

    private func copyReply() {
        nudge.copiedPrompt()
        ClaudeCheck.copyReply(for: item)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(4))
            copied = false
        }
    }

    private var terminalPid: Int? {
        guard let pid = pid ?? pids[item.taskId], TerminalLocator.appPid(startingAt: pid) != nil else { return nil }
        return pid
    }

    @ViewBuilder
    private func content(mode: PickupFallback.Mode, phase: Nudge.Phase) -> some View {
        let runtime = item.runtime.displayName
        let terminal = mode == .live ? terminalPid : nil
        switch style {
        case .block:
            VStack(alignment: .leading, spacing: 8) {
                if let help = blockHelp(mode: mode, phase: phase, runtime: runtime) {
                    Text(help)
                        .knockTextStyle(Theme.Typography.recommendLine12w400)
                        .foregroundColor(Theme.Colors.ink2)
                }
                if phase == .off {
                    Text(PickupFallback.prompt)
                        .knockTextStyle(Theme.Typography.monoMeta11w400)
                        .foregroundColor(Theme.Colors.ink)
                        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Colors.side)
                        .cornerRadius(Theme.Radius.buttonSmall)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    nudgeButton(phase: phase, runtime: runtime)
                    if phase.isActive {
                        moreMenu(terminal: terminal)
                    } else {
                        copyButton(primary: true)
                        if let terminal { terminalButton(pid: terminal, primary: false) }
                    }
                    if copied {
                        Text(PickupFallback.copiedLine(runtime: runtime))
                            .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                            .foregroundColor(Theme.Colors.ok)
                    }
                }
                if let failure = Nudge.failureLine(record?.failure) {
                    Text(failure)
                        .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
                if mode == .live, terminal == nil {
                    Text(PickupFallback.noTerminalLine(runtime: runtime, project: item.project))
                        .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
            }
        case .strip:
            HStack(spacing: 8) {
                nudgeButton(phase: phase, runtime: runtime)
                if phase.isActive {
                    moreMenu(terminal: terminal)
                } else {
                    copyButton(primary: false)
                    if let terminal { terminalButton(pid: terminal, primary: false) }
                }
            }
        case .link:
            linkAction(phase: phase)
        case .compact:
            VStack(alignment: .leading, spacing: 6) {
                if let line = compactLine(mode: mode, phase: phase) {
                    Text(line)
                        .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                        .foregroundColor(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    nudgeButton(phase: phase, runtime: runtime)
                    if phase.isActive {
                        moreMenu(terminal: terminal)
                    } else {
                        copyButton(primary: mode == .live)
                        if let terminal { terminalButton(pid: terminal, primary: false) }
                    }
                }
            }
        }
    }

    private func blockHelp(mode: PickupFallback.Mode, phase: Nudge.Phase, runtime: String) -> String? {
        switch phase {
        case .ready: Nudge.readyHelp
        case .sent: Nudge.sentHelp
        case .stillAsleep: Nudge.asleepHelp
        case .off: PickupFallback.helpLine(mode: mode, runtime: runtime)
        }
    }

    private func compactLine(mode: PickupFallback.Mode, phase: Nudge.Phase) -> String? {
        switch phase {
        case .ready: "Nudge it to check Waggle for your reply."
        case .sent: "Nudged · waiting for it to wake up and check Waggle."
        case .stillAsleep: "Still asleep after the nudge."
        case .off: mode == .live ? "Paste \"\(PickupFallback.prompt)\" in its terminal." : nil
        }
    }

    /// The nudge control: "Nudge <runtime>" when ready, "Nudged · 12s" while the
    /// nudge has its minute, "Nudge again" after it. Nothing when the session
    /// cannot be nudged or a nudge failed (then "Copy prompt" shows).
    @ViewBuilder
    private func nudgeButton(phase: Nudge.Phase, runtime: String) -> some View {
        switch phase {
        case .ready:
            fallbackButton(
                style == .block ? Nudge.nudgeLabel(runtime: runtime) : "Nudge", primary: true,
                action: sendNudge)
        case .stillAsleep:
            fallbackButton(Nudge.nudgeAgainLabel, primary: true, action: sendNudge)
        case .sent:
            nudgedLabel
        case .off:
            EmptyView()
        }
    }

    /// "Nudged · 12s", ticking every second. The waiting timer elsewhere keeps
    /// counting from the send.
    private var nudgedLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Nudge.nudgedLabel(since: record?.lastAt, now: context.date))
                .knockTextStyle(
                    style == .block ? Theme.Typography.buttonSm12_5w500 : Theme.Typography.sessionsFoot11w400)
                .foregroundColor(Theme.Colors.ink2)
                .monospacedDigit()
        }
    }

    /// The small "..." menu next to the nudge: "Copy prompt" and "Show the
    /// terminal", for when the human would rather paste the line.
    private func moreMenu(terminal: Int?) -> some View {
        Menu {
            Button(copied ? "Copied" : "Copy prompt", action: copy)
            if let terminal {
                Button("Show the terminal") { TerminalLocator.show(startingAt: terminal) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Colors.ink2)
                .frame(width: style == .block ? 28 : 22, height: style == .block ? 26 : 20)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall).fill(Theme.Colors.win))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall)
                        .stroke(Theme.Colors.line2, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain).pointerCursor()
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Nudge.moreLabel)
        .accessibilityLabel(Nudge.moreLabel)
    }

    /// The queue row's one link: Nudge, "Nudged · 12s", Nudge again (each with the
    /// small menu), or Copy prompt.
    @ViewBuilder
    private func linkAction(phase: Nudge.Phase) -> some View {
        switch phase {
        case .ready:
            HStack(spacing: 6) {
                rowLink("Nudge", action: sendNudge)
                moreMenu(terminal: nil)
            }
        case .stillAsleep:
            HStack(spacing: 6) {
                rowLink(Nudge.nudgeAgainLabel, action: sendNudge)
                moreMenu(terminal: nil)
            }
        case .sent:
            HStack(spacing: 6) {
                nudgedLabel
                moreMenu(terminal: nil)
            }
        case .off: copyLink
        }
    }

    private func rowLink(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                .fontWeight(.semibold)
                .foregroundColor(Theme.Colors.ds)
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func sendNudge() { nudge.send(item.id) }

    private func copyButton(primary: Bool) -> some View {
        fallbackButton(copied ? "Copied" : "Copy prompt", primary: primary, action: copy)
    }

    /// The queue row's action: blue text at the trailing edge of the status line.
    private var copyLink: some View {
        Button(action: copy) {
            Text(copied ? "Copied" : "Copy prompt")
                .knockTextStyle(Theme.Typography.sessionsFoot11w400)
                .fontWeight(.semibold)
                .foregroundColor(Theme.Colors.ds)
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func copy() {
        nudge.copiedPrompt()
        PickupFallback.copyPrompt()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(4))
            copied = false
        }
    }

    private func terminalButton(pid: Int, primary: Bool) -> some View {
        fallbackButton("Show the terminal", primary: primary) { TerminalLocator.show(startingAt: pid) }
    }

    private func fallbackButton(_ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        let compact = style == .compact || style == .strip
        return Button(action: action) {
            Text(label)
                .knockTextStyle(compact ? Theme.Typography.sessionsFoot11w400 : Theme.Typography.buttonSm12_5w500)
                .foregroundColor(primary ? Theme.Colors.onFill : Theme.Colors.ink)
                .padding(EdgeInsets(top: compact ? 3 : 6, leading: compact ? 8 : 12, bottom: compact ? 3 : 6, trailing: compact ? 8 : 12))
                .background(RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall).fill(primary ? Theme.Colors.ink : Theme.Colors.win))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall)
                        .stroke(primary ? Color.clear : Theme.Colors.line2, lineWidth: 1))
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

/// The grey banner above a queued reply: "Sent · waiting for the agent to pick
/// it up" with a timer, or "Not picked up · the session ended" when the session
/// is not live. Shared by the ask pane and the review workspace column.
struct SentWaitingBanner: View {
    let item: Case

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            banner
        }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            if AgentStatus.forCase(item) == .closed {
                AgentStatusLine(
                    status: .closed, cell: 4, label: "Not picked up · the session ended",
                    labelFont: .labelStrong, spacing: 8)
            } else {
                AgentStatusLine(
                    status: .waitingForPickup, cell: 4,
                    label: item.isWaitingOnMoreDetail
                        ? "Asked for more detail · waiting for the agent"
                        : "Sent · waiting for the agent to pick it up",
                    since: item.latestReplyAtDate,
                    labelFont: .labelStrong, spacing: 8)
            }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.deliveryBanner)
    }
}
