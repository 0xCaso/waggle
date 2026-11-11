import AppKit
import SwiftUI

/// Shared chrome for every O1-O3/O5/O6 screen of the "Onboarding v2
/// (immersive)" setup window (docs/stories/HAIL-29.md): the header (mark,
/// title, subtitle, step label) and the footer (Back/primary action row).
/// Kept as one file so the five screens read from one visual source instead
/// of five near-duplicates drifting apart.

/// One screen's header (design: `Header`/`RYOb5` and its siblings across
/// O1-O3/O5/O6). `markSize` differs only for O3 (48pt vs the usual 40pt).
struct OnboardingHeaderView: View {
    let title: String
    let subtitle: String
    /// `nil` on step 1: the title names the step once.
    var stepLabel: String?
    var markSize: CGFloat = 40
    var titleStyle: Theme.TextStyle = Theme.Typography.screenTitle19w400

    var body: some View {
        HStack(spacing: 14) {
            WordmarkLockup(markSize: markSize, textSize: markSize * 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .knockTextStyle(titleStyle)
                    .foregroundColor(Theme.Colors.ink)
                Text(subtitle)
                    .knockTextStyle(Theme.Typography.setupSubtitle13w400)
                    .foregroundColor(Theme.Colors.ink2)
            }
            Spacer()
            if let stepLabel {
                Text(stepLabel)
                    .knockTextStyle(Theme.Typography.monoMeta11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
        }
    }
}

/// The ghost button (Pen `j8RXN6`): no fill, label ink-2 13.5 medium. "Back" and "Copy prompt" use it.
struct OnboardingGhostButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .knockTextStyle(Theme.Typography.button13_5w500)
                .foregroundColor(Theme.Colors.ink2)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

/// A card you pick: white with a hairline, honey stroke and soft fill when picked (the look of the
/// pick in `CompactOptionRow`). The project tiles and the first-job cards use it.
struct OnboardingChoiceCard<Content: View>: View {
    let isSelected: Bool
    var padding = EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13)
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .padding(padding)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.threadCard).fill(isSelected ? Theme.Colors.honeySoft : Theme.Colors.win))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.threadCard)
                        .stroke(isSelected ? Theme.Colors.honey500 : Theme.Colors.line, lineWidth: isSelected ? 1.5 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The footer's shared shape: an optional ghost "Back", a spacer, and one
/// trailing primary/secondary action. Each screen supplies its own trailing
/// content since O2's "Waiting…" pill and O3's caption+button differ from
/// the plain primary-button shape O1 uses.
struct OnboardingFooterRow<Trailing: View>: View {
    var onBack: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                OnboardingGhostButton(title: "Back", action: onBack)
            } else {
                // O1's disabled ghost Back (no action - there is nowhere to go back to).
                OnboardingGhostButton(title: "Back", action: {}).disabled(true).opacity(0.4)
            }
            Spacer()
            trailing()
        }
        .padding(.top, 18)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .top)
    }
}

/// The dark primary button shape shared by every screen's main CTA
/// ("Continue", "Open it", "Send me a test ask", "Done").
struct OnboardingPrimaryButton: View {
    let title: String
    var systemImage: String?
    var trailing = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage, !trailing {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .knockTextStyle(Theme.Typography.button13_5w500)
                if let systemImage, trailing {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundColor(Theme.Colors.win)
            .padding(.vertical, 9)
            .padding(.horizontal, 16)
            .background(isEnabled ? Theme.Colors.ink : Theme.Colors.line2)
            .cornerRadius(Theme.Radius.buttonPrimary)
        }
        .buttonStyle(.pressable).pointerCursor()
    }
}

/// The dark small button shape shared by "Send me a test ask" (O2/O6) and
/// "Allow notifications" (O2), and (before HAIL-29) the old M1 steps.
struct OnboardingSmallButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .knockTextStyle(Theme.Typography.buttonSm12_5w500)
            }
            .foregroundColor(Theme.Colors.win)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(Theme.Colors.ink)
            .cornerRadius(Theme.Radius.buttonSmall)
        }
        .buttonStyle(.pressable).pointerCursor()
    }
}

/// The small status pill beside a runtime's name.
struct RuntimeStatusChip: View {
    let text: String
    let fg: Color
    let bg: Color

    var body: some View {
        Text(text)
            .knockTextStyle(Theme.Typography.buttonSm12_5w600)
            .foregroundColor(fg)
            .padding(EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7))
            .background(bg)
            .cornerRadius(Theme.Radius.chip)
    }
}

/// One runtime row (O1 "Connect rows" - KNOCK-20/HAIL-24, unchanged).
struct OnboardingRuntimeRowView: View {
    let row: OnboardingModel.RuntimeRow
    let onConnect: () -> Void
    /// The last row draws no divider: the footer's own top border follows
    /// it, and two lines stacked read as one thick line (operator,
    /// 2026-09-28).
    var showsDivider: Bool = true
    /// The Settings window's Agents page (HAIL-52 contract): a connected
    /// row also gets a "Reconnect" button, calling the same `onConnect`
    /// closure a not-yet-connected row's "Connect" already runs (`knock
    /// install <runtime>` then a refresh). `false` for onboarding's O1,
    /// which never shows one for a connected row - onboarding's own
    /// behaviour stays exactly as it was.
    var showsReconnectWhenConnected: Bool = false
    /// "Retry" beside "Couldn't check"; probes again.
    var onRetry: (() -> Void)?
    /// HAIL-134: "Remove old entry", shown when the plugin and a `knock install`
    /// entry both run Knock.
    var onRemoveOldEntry: (() -> Void)?
    /// HAIL-164: a place under the Claude group row. Indented 16pt, medium title,
    /// no icon (the group header carries it).
    var isNested = false
    /// Setup step 1: one action per row (`ConnectStepRules`), no Retry, Reconnect or note beside it.
    var oneAction = false

    var body: some View {
        HStack(spacing: 10) {
            if !isNested {
                Image(systemName: "terminal")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Colors.ink2)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(row.runtime.displayName)
                        .knockTextStyle(isNested ? Theme.Typography.button13_5w500 : Theme.Typography.rowTitle13_5w600)
                        .foregroundColor(Theme.Colors.ink)
                    statusChip
                }
                if let error = row.error, row.status == .notConnected {
                    Text(error)
                        .knockTextStyle(Theme.Typography.monoMeta11_5w400)
                        .foregroundColor(Theme.Colors.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // HAIL-134: how Claude Code reaches Knock, under the name.
                if !oneAction, row.plugin != .none, row.status == .connected {
                    Text("Installed as \(row.runtime.displayName) plugin")
                        .knockTextStyle(Theme.Typography.monoMeta11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    // HAIL-137: Codex skips a plugin's hooks until the user trusts them.
                    if row.runtime == .codex {
                        Text("Trust the Waggle hooks once: type /hooks in Codex")
                            .knockTextStyle(Theme.Typography.monoMeta11_5w400)
                            .foregroundColor(Theme.Colors.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            // The trailing button keeps its natural size; the text column wraps instead.
            trailing
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(EdgeInsets(top: 0, leading: isNested ? 16 : 0, bottom: showsDivider ? 14 : 0, trailing: 0))
        .overlay(
            Rectangle().fill(showsDivider ? Theme.Colors.line : .clear).frame(height: 1),
            alignment: .bottom
        )
    }

    @ViewBuilder private var statusChip: some View {
        switch row.status {
        case .connected:
            chip("Connected", fg: Theme.Colors.ok, bg: Theme.Colors.ok.opacity(0.1))
        case .probing, .connecting:
            chip("Checking…", fg: Theme.Colors.ink3, bg: .clear)
        case .couldNotCheck:
            chip("Couldn't check", fg: Theme.Colors.ink2, bg: Theme.Colors.side)
        case .notInstalled:
            chip("Not installed", fg: Theme.Colors.ink2, bg: Theme.Colors.side)
        case .notConnected:
            chip("Not connected", fg: Theme.Colors.ink2, bg: Theme.Colors.side)
        }
    }

    private func chip(_ text: String, fg: Color, bg: Color) -> some View {
        RuntimeStatusChip(text: text, fg: fg, bg: bg)
    }

    @ViewBuilder private var trailing: some View {
        if oneAction { oneActionTrailing } else { fullTrailing }
    }

    @ViewBuilder private var oneActionTrailing: some View {
        switch ConnectStepRules.action(for: row.runtime, status: row.status) {
        case .connect: OnboardingSmallButton(icon: "bolt.fill", title: "Connect", action: onConnect)
        case .get(let url):
            OnboardingSmallButton(icon: "arrow.up.right", title: "Get", action: { NSWorkspace.shared.open(url) })
        case .working: if row.status == .connecting { LoadingStatus(label: "Connecting") }
        case .connected, .none: EmptyView()
        }
    }

    @ViewBuilder private var fullTrailing: some View {
        switch row.status {
        case .notConnected:
            OnboardingSmallButton(icon: "bolt.fill", title: "Connect", action: onConnect)
        case .connecting:
            LoadingStatus(label: "Connecting")
        case .couldNotCheck:
            if let onRetry {
                OnboardingSmallButton(icon: "arrow.clockwise", title: "Retry", action: onRetry)
            } else {
                Text("Could not check")
                    .knockTextStyle(Theme.Typography.monoMeta11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
        case .connected where row.plugin == .pluginWithOldEntry && onRemoveOldEntry != nil:
            OnboardingSmallButton(icon: "trash", title: "Remove old entry", action: onRemoveOldEntry ?? {})
                .fixedSize()
        case .connected where row.plugin == .plugin:
            // The plugin serves Knock: there is no entry to reconnect.
            EmptyView()
        case .connected:
            if showsReconnectWhenConnected {
                OnboardingSmallButton(icon: "arrow.triangle.2.circlepath", title: "Reconnect", action: onConnect)
            } else {
                Text("MCP server active")
                    .knockTextStyle(Theme.Typography.monoMeta11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
        case .probing, .notInstalled:
            EmptyView()
        }
    }
}
