import SwiftUI

/// What the main window needs from the new onboarding (WAG-338): the list and working state, and the one
/// action that is not in the model, "Try a sample instead".
struct FirstRunContext {
    let model: GettingStartedModel
    let trySample: () -> Void
}

/// A soft pulse: a ring that grows and fades, 1.4 s ease-out. Only on things that are really in progress.
/// With Reduce Motion the dot stays still.
struct PulseDot: View {
    var size: CGFloat = 9
    var color: Color = Theme.Colors.honey500
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                PulseRing(color: color.opacity(0.6), lineWidth: 2, opacity: 0.8, scale: 2.2)
                    .frame(width: size, height: size)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "Your agent is on it" in the queue (screen 3): the app's own queue row, with a working dot that pulses.
struct AgentOnItRow: View {
    let working: AgentOnIt
    let now: Date

    var body: some View {
        QueueStatusRow(dotColor: Theme.Colors.ds, pulses: true, title: "Your agent is on it", meta: working.queueLine(now: now))
            .accessibilityIdentifier("agent-on-it-row")
    }
}

/// The body of the main window while the agent works (screen 3): a calm card centred in the case pane.
/// After 3 minutes with no ask it offers the built-in sample.
struct AgentOnItCard: View {
    let working: AgentOnIt
    let sample: GettingStartedModel.SamplePhase
    let onTrySample: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("\(working.projectName) · your agent is working")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
            card
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var card: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.Colors.honeySoft)
                Circle().stroke(Theme.Colors.honey500, lineWidth: 2)
            }
            .frame(width: Theme.Spacing.workingMark, height: Theme.Spacing.workingMark)
            .overlay { PulseDot(size: Theme.Spacing.workingMark, color: Theme.Colors.honey500).opacity(0.5).allowsHitTesting(false) }
            Text("Your agent is on it")
                .knockTextStyle(Theme.Typography.dialogTitle19w650)
                .foregroundColor(Theme.Colors.ink)
            Text(working.cardText)
                .knockTextStyle(Theme.Typography.body13_5w400)
                .foregroundColor(Theme.Colors.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                sampleControl(offered: working.sampleOffered(now: context.date))
            }
        }
        .padding(24)
        .frame(maxWidth: Theme.Spacing.workingCardMaxWidth)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.setupWindow).fill(Theme.Colors.list))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.setupWindow).stroke(Theme.Colors.line, lineWidth: 1))
        .padding(24)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func sampleControl(offered: Bool) -> some View {
        VStack(spacing: 6) {
            if offered {
                SettingsSecondaryButton(
                    title: sample == .running ? "Making the sample…" : "No ask after 3 minutes? Try a sample instead",
                    action: onTrySample)
                    .disabled(sample == .running)
            }
            if case .failed(let text) = sample {
                Text(text)
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.accent)
            }
        }
        .padding(.top, 4)
    }
}

/// Where the tip for the notifications line points. Published by the line, drawn by `MainWindowView`: the
/// tip sits beside the list, over the ask, and a sibling view would hide it.
struct NotificationsLineAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The getting started list under the queue (screen 7): six lines that tick themselves.
struct GettingStartedView: View {
    @ObservedObject var model: GettingStartedModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("Getting started")
                    .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                    .foregroundColor(Theme.Colors.ink)
                Spacer()
                Button("Hide", action: model.hide)
                    .buttonStyle(.plain).pointerCursor()
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
            .padding(.bottom, 4)
            ProgressBar(fraction: model.fraction)
                .padding(.bottom, 6)
            ForEach(model.items) { item in
                GettingStartedRow(
                    item: item, isHighlighted: item.line == .notifications && model.highlightsNotifications,
                    onOpen: { model.open(item.line) })
            }
        }
        .padding(14)
        .background(Theme.Colors.win)
        .cornerRadius(Theme.Radius.notePopover)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.notePopover).stroke(Theme.Colors.line, lineWidth: 1))
        .accessibilityIdentifier("getting-started-list")
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.side)
                Capsule().fill(Theme.Colors.ok).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: Theme.Spacing.progressBarHeight)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Getting started progress")
        .accessibilityValue("\(Int((fraction * 6).rounded())) of 6 done")
    }
}

private struct GettingStartedRow: View {
    let item: GettingStartedItem
    let isHighlighted: Bool
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        // The row opens its place; the small button on the right does the one thing the line says.
        HStack(alignment: .top, spacing: 8) {
            check
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(item.isDone ? Theme.Colors.ink3 : Theme.Colors.ink)
                Text(item.hint)
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let label = item.actionLabel {
                SettingsSecondaryButton(title: label, action: onOpen)
                .accessibilityLabel("\(label): \(item.title)")
            }
        }
        .padding(EdgeInsets(top: 5, leading: 4, bottom: 5, trailing: 4))
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.regionBox)
                .fill(isHighlighted ? Theme.Colors.honeySoft : isHovering ? Theme.Colors.list : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .help(item.hint)
        .anchorPreference(key: NotificationsLineAnchorKey.self, value: .bounds) { isHighlighted ? $0 : nil }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(item.isDone ? "done" : "not done")
    }

    private var check: some View {
        ZStack {
            Circle().fill(item.isDone ? Theme.Colors.ok : Color.clear)
            Circle().stroke(item.isDone ? Theme.Colors.ok : Theme.Colors.line2, lineWidth: 1.5)
            if item.isDone {
                Image(systemName: "checkmark").font(Theme.Typography.tickMark.font).foregroundColor(Theme.Colors.win)
            }
        }
        .frame(width: Theme.Spacing.tickSize, height: Theme.Spacing.tickSize)
        .padding(.top, 1)
    }
}

/// The tip beside the highlighted notifications line (screen 7).
struct NotificationsTip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(GettingStartedModel.notificationsTipTitle)
                .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                .foregroundColor(Theme.Colors.win)
            Text(GettingStartedModel.notificationsTipBody)
                .knockTextStyle(Theme.Typography.caption11_5w400)
                .foregroundColor(Theme.Colors.onInkBody)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(width: Theme.Spacing.tipWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.notePopover).fill(Theme.Colors.ink))
        .shadow(Theme.Shadow.notePopover)
        .accessibilityElement(children: .combine)
    }
}
