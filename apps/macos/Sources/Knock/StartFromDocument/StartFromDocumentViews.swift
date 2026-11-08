import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Theme.Typography {
    static let docFileName13_5w600 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 13.5).weight(.semibold), size: 13.5, lineHeight: nil, letterSpacing: nil)
    static let docDropTitle16w600 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 16).weight(.semibold), size: 16, lineHeight: nil, letterSpacing: nil)

    // WAG-254: the "Start a new session" split button and its menu, Pen band "Start from a PRD:
    // choose the agent and where it opens", column C, node `Y4c8NB`.
    static let startSplitMain13_5w600 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 13.5).weight(.semibold), size: 13.5, lineHeight: nil, letterSpacing: nil)
    static let startMenuAgent13w600 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 13).weight(.semibold), size: 13, lineHeight: nil, letterSpacing: nil)
    static let startMenuWhere13w400 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 13), size: 13, lineHeight: nil, letterSpacing: nil)
    static let startMenuFooter12w400 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 12), size: 12, lineHeight: nil, letterSpacing: nil)
}


// MARK: - Start session split button and menu (WAG-254)

/// The footer's primary action. Where the idea goes is the agent chip's job (WAG-274), so this is one button.
struct StartSessionButton: View {
    let title: String
    let busy: Bool
    var disabled = false
    var shortcut = KeyboardShortcut.defaultAction
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .knockTextStyle(Theme.Typography.startSplitMain13_5w600)
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Theme.Colors.ink)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).pointerCursor()
        .keyboardShortcut(shortcut)
        .disabled(busy || disabled)
        .opacity(busy ? 0.85 : disabled ? 0.55 : 1)
    }
}

/// The chip after the folder chip: which agent, and where, for this run. Plain when it is the default,
/// honey when this run differs. It opens the one target list.
struct AgentChip: View {
    @ObservedObject var launcher: SessionLauncher
    let folder: URL
    let label: String
    let differs: Bool
    let sessionOptions: [DocumentSendOption]
    let selectedSession: DocumentSendOption.Target
    let isDefault: Bool
    let canUseAsDefault: Bool
    let onPickLaunch: () -> Void
    let onPickSession: (DocumentSendOption.Target) -> Void
    let onUseAsDefault: () -> Void
    @State private var showMenu = false

    var body: some View {
        Button { showMenu = true } label: {
            HStack(spacing: 5) {
                Text(label)
                    .knockTextStyle(differs ? Theme.Typography.ideaChip12_5w600 : Theme.Typography.ideaChip12_5)
                    .foregroundColor(Theme.Colors.ink)
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.Colors.ink2)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(differs ? Theme.Colors.honeySoft : Theme.Colors.win)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(differs ? Theme.Colors.honey500 : Theme.Colors.line, lineWidth: differs ? 1.5 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).pointerCursor()
        .animation(.easeOut(duration: 0.15), value: differs)
        .accessibilityLabel("Agent for this idea: \(label)")
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            LaunchTargetMenu(
                launcher: launcher, folder: folder, sessionOptions: sessionOptions, selectedSession: selectedSession,
                isDefault: isDefault, canUseAsDefault: canUseAsDefault,
                onPickLaunch: { onPickLaunch(); showMenu = false },
                onSwitchAgent: onPickLaunch,
                onPickSession: { onPickSession($0); showMenu = false },
                onUseAsDefault: onUseAsDefault)
        }
    }
}

/// The chip's menu (WAG-278): a Claude Code | Codex switch, one row per place with the usable ones
/// first, places to set up folded into one line, and the running sessions in a submenu.
private struct LaunchTargetMenu: View {
    @ObservedObject var launcher: SessionLauncher
    let folder: URL
    let sessionOptions: [DocumentSendOption]
    let selectedSession: DocumentSendOption.Target
    let isDefault: Bool
    let canUseAsDefault: Bool
    let onPickLaunch: () -> Void
    let onSwitchAgent: () -> Void
    let onPickSession: (DocumentSendOption.Target) -> Void
    let onUseAsDefault: () -> Void
    @Environment(\.openSettings) private var openSettings
    @State private var appeared = false
    @State private var agent: LaunchAgent?
    @State private var showsSetup = false
    @State private var showsSessions = false

    /// The agent the switch shows: the person's tap, else the one this run uses.
    private var shownAgent: LaunchAgent { agent ?? launcher.launchTarget.agent ?? .claude }

    var body: some View {
        let layout = StartMenuLayout.make(agent: shownAgent, availability: launcher.availability)
        VStack(spacing: 2) {
            agentSwitch
            ForEach(layout.usable) { placeRow($0) }
            if !sessionOptions.isEmpty { sessionsRow }
            if let fold = layout.foldTitle { setupFold(fold, rows: layout.setup) }
            Rectangle().fill(Theme.Colors.line).frame(height: 1).padding(.vertical, 2)
            settingsLink
            defaultCheckbox
        }
        .padding(6)
        .frame(width: 300)
        .background(Theme.Colors.win)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Colors.line, lineWidth: 1))
        .shadow(color: Color.black.opacity(Double(0x24) / 255.0), radius: 15, x: 0, y: 10)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -4)
        .onAppear { withAnimation(.easeOut(duration: 0.2)) { appeared = true } }
        .animation(.easeOut(duration: 0.2), value: showsSetup)
        .task {
            await launcher.refreshT3Availability()
            await launcher.refreshSupersetAvailability(folder: folder)
        }
    }

    private var agentSwitch: some View {
        HStack(spacing: 0) {
            ForEach(LaunchAgent.allCases) { option in
                let on = shownAgent == option
                Button { switchAgent(to: option) } label: {
                    Text(option.title)
                        .knockTextStyle(Theme.Typography.startMenuAgent13w600)
                        .foregroundColor(on ? Theme.Colors.ink : Theme.Colors.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(on ? Theme.Colors.win : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: Color.black.opacity(on ? 0.08 : 0), radius: 1, x: 0, y: 1)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).pointerCursor()
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.Colors.side)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.2), value: shownAgent)
        .padding(EdgeInsets(top: 4, leading: 4, bottom: 6, trailing: 4))
    }

    /// Keeps the place when it works for the new agent, else Terminal.
    private func switchAgent(to option: LaunchAgent) {
        guard option != shownAgent else { return }
        agent = option
        launcher.chooseLaunchTarget(launcher.launchTarget.switching(to: option, availability: launcher.availability))
        onSwitchAgent()
    }

    private var defaultCheckbox: some View {
        Button(action: onUseAsDefault) {
            HStack(spacing: 8) {
                Image(systemName: isDefault ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(isDefault ? Theme.Colors.ink : Theme.Colors.ink3)
                    .frame(width: 14, height: 14)
                Text("Use as my default")
                    .knockTextStyle(Theme.Typography.startMenuAgent13w600)
                    .foregroundColor(Theme.Colors.ink)
                Spacer(minLength: 4)
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .disabled(isDefault || !canUseAsDefault)
        .opacity(canUseAsDefault ? 1 : 0.55)
        .accessibilityAddTraits(isDefault ? .isSelected : [])
    }

    private var settingsLink: some View {
        Button { openCard(nil) } label: {
            HStack {
                Text("\(StartMenuSettingsRoute.footerTitle) ›")
                    .knockTextStyle(Theme.Typography.startMenuFooter12w400)
                    .foregroundColor(Theme.Colors.ds)
                Spacer(minLength: 4)
            }
            .padding(EdgeInsets(top: 6, leading: 32, bottom: 6, trailing: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func openCard(_ place: LaunchPlace?) {
        SettingsRouter.shared.show(StartMenuSettingsRoute.card(for: place, agent: shownAgent))
        openSettings()
    }

    private func rowChrome<Content: View>(selected: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .background(selected ? Theme.Colors.side : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func check(_ on: Bool) -> some View {
        ZStack {
            if on {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.Colors.ink)
            }
        }
        .frame(width: 14, height: 14)
    }

    private func placeRow(_ row: StartMenuRow) -> some View {
        let selected = launcher.launchTarget.place == row.place && selectedSession == .newSession
            && (row.place == .conductor || launcher.launchTarget.agent == shownAgent)
        return Button {
            launcher.chooseLaunchTarget(LaunchTarget.target(agent: shownAgent, place: row.place))
            onPickLaunch()
        } label: {
            rowChrome(selected: selected) {
                check(selected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).knockTextStyle(Theme.Typography.startMenuAgent13w600).foregroundColor(Theme.Colors.ink)
                    if let subtitle = row.subtitle {
                        Text(subtitle).knockTextStyle(Theme.Typography.startMenuWhere13w400).foregroundColor(Theme.Colors.ink3)
                    }
                }
                Spacer(minLength: 4)
            }
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sessionsRow: some View {
        let sessionPicked: Bool = { if case .session = selectedSession { return true } else { return false } }()
        return Button { showsSessions.toggle() } label: {
            rowChrome(selected: sessionPicked) {
                check(sessionPicked)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Send to a running session")
                        .knockTextStyle(Theme.Typography.startMenuAgent13w600).foregroundColor(Theme.Colors.ink)
                    Text(StartMenuSessions.countText(sessionOptions.count))
                        .knockTextStyle(Theme.Typography.startMenuWhere13w400).foregroundColor(Theme.Colors.ink3)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.Colors.ink3)
            }
        }
        .buttonStyle(.plain).pointerCursor()
        .popover(isPresented: $showsSessions, arrowEdge: .trailing) { sessionsSubmenu }
    }

    private var sessionsSubmenu: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(StartMenuSessions.ordered(sessionOptions)) { sessionRow($0) }
            }
            .padding(6)
        }
        .frame(width: 240)
        .frame(maxHeight: 240)
        .background(Theme.Colors.win)
    }

    private func sessionRow(_ option: DocumentSendOption) -> some View {
        let selected = selectedSession == option.target
        return Button { onPickSession(option.target) } label: {
            rowChrome(selected: selected) {
                ZStack {
                    if option.isWorking {
                        Circle().fill(Theme.Colors.ds).frame(width: 7, height: 7)
                    } else if selected {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.Colors.ink)
                    }
                }
                .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name)
                        .knockTextStyle(Theme.Typography.startMenuAgent13w600).foregroundColor(Theme.Colors.ink)
                        .lineLimit(1).truncationMode(.tail)
                    Text(option.statusWord)
                        .knockTextStyle(Theme.Typography.startMenuWhere13w400).foregroundColor(Theme.Colors.ink3)
                }
                Spacer(minLength: 4)
            }
        }
        .buttonStyle(.plain).pointerCursor()
        .help(option.folder ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func setupFold(_ title: String, rows: [StartMenuRow]) -> some View {
        VStack(spacing: 2) {
            Button { showsSetup.toggle() } label: {
                HStack(spacing: 4) {
                    Text("\(title) ·").knockTextStyle(Theme.Typography.startMenuFooter12w400).foregroundColor(Theme.Colors.ink3)
                    Text(showsSetup ? "Hide" : "Show")
                        .knockTextStyle(Theme.Typography.startMenuFooter12w400).foregroundColor(Theme.Colors.ds)
                    Spacer(minLength: 4)
                }
                .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            if showsSetup {
                ForEach(rows) { row in
                    rowChrome {
                        check(false)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).knockTextStyle(Theme.Typography.startMenuAgent13w600).foregroundColor(Theme.Colors.ink3)
                            Text(row.reason ?? "")
                                .knockTextStyle(Theme.Typography.startMenuWhere13w400).foregroundColor(Theme.Colors.ink3)
                        }
                        Spacer(minLength: 4)
                        Button { openCard(row.place) } label: {
                            Text("Set up ›").knockTextStyle(Theme.Typography.startMenuFooter12w400).foregroundColor(Theme.Colors.ds)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointerCursor()
                    }
                }
            }
        }
    }
}
