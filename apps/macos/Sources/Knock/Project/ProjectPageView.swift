import SwiftUI

/// The project page (WAG-260, Pen frame `dR3q0`): the decision log on the left, the operator's
/// themes on the right. Light look in dark mode: every colour is explicit.
struct ProjectPageView: View {
    @StateObject private var page: ProjectPageModel
    let now: Date
    let onBack: () -> Void
    let onOpenCase: (String) -> Void

    init(project: String, client: KnockClient, now: Date, onBack: @escaping () -> Void, onOpenCase: @escaping (String) -> Void) {
        _page = StateObject(wrappedValue: ProjectPageModel(project: project, client: client))
        self.now = now
        self.onBack = onBack
        self.onOpenCase = onOpenCase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            HStack(alignment: .top, spacing: 28) {
                decisionLog
                themes.frame(width: 320)
            }
            .padding(EdgeInsets(top: 8, leading: 28, bottom: 24, trailing: 28))
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.win)
        .environment(\.colorScheme, .light)
        .task { await page.load() }
    }

    // MARK: Header

    private var top: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onBack) {
                Text("← Back")
                    .font(.custom(Theme.FontFamily.sans, size: 12).weight(.medium))
                    .foregroundColor(Theme.Colors.ink3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .padding(.bottom, 4)
            label("PROJECT")
            Text(page.name)
                .font(.custom(Theme.FontFamily.sans, size: 28).weight(.semibold))
                .tracking(-0.8)
                .foregroundColor(Theme.Colors.ink)
                .lineLimit(1)
            if let info = page.info {
                Text(ProjectPageLogic.statsLine(
                    decisions: info.decisions, comments: info.comments,
                    lastDecisionAt: info.lastDecisionAt.flatMap(KnockDateFormat.date(from:)), now: now))
                    .font(.custom(Theme.FontFamily.sans, size: 13))
                    .foregroundColor(Theme.Colors.ink3)
            }
        }
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 14, trailing: 28))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.custom(Theme.FontFamily.mono, size: 10.5))
            .tracking(0.6)
            .foregroundColor(Theme.AskDoc.Colors.quiet)
    }

    // MARK: Decision log

    private var decisionLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                label("DECISION LOG")
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ProjectSwitch(isOn: page.info?.repoRecords ?? false, label: ProjectPageLogic.repoSwitchLabel) { on in
                        Task { await page.setRepoRecords(on) }
                    }
                    Text(ProjectPageLogic.repoSwitchLabel)
                        .font(.custom(Theme.FontFamily.sans, size: 12))
                        .foregroundColor(Theme.Colors.ink2)
                }
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(page.decisions) { decision in
                        DecisionRecordRow(decision: decision, now: now) { onOpenCase(decision.caseId) }
                    }
                    if page.hasMore {
                        Button {
                            Task { await page.loadMore() }
                        } label: {
                            Text(page.loadingMore ? "Loading" : "Show more")
                                .font(.custom(Theme.FontFamily.sans, size: 12).weight(.medium))
                                .foregroundColor(Theme.Colors.ink2)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointerCursor()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Themes

    private var themes: some View {
        VStack(alignment: .leading, spacing: 8) {
            label(ProjectPageLogic.themesLabel(comments: page.info?.comments ?? 0))
            if let info = page.info, !info.themes.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(info.themes) { theme in
                            ThemeCard(theme: theme) { on in Task { await page.setTheme(theme, enabled: on) } }
                        }
                    }
                }
            } else if page.loaded {
                Text(ProjectPageLogic.themesEmpty)
                    .font(.custom(Theme.FontFamily.sans, size: 12))
                    .foregroundColor(Theme.Colors.ink3)
            }
            Text(ProjectPageLogic.themesHint)
                .font(.custom(Theme.FontFamily.sans, size: 12))
                .foregroundColor(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DecisionRecordRow: View {
    let decision: ProjectDecision
    let now: Date
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 14) {
                Text(KnockDateFormat.date(from: decision.decidedAt).map { ProjectPageLogic.dateLabel($0, now: now) } ?? "")
                    .font(.custom(Theme.FontFamily.sans, size: 12))
                    .foregroundColor(Theme.AskDoc.Colors.quiet)
                    .frame(width: 86, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AgentMarkdown.plainText(decision.question))
                        .font(.custom(Theme.FontFamily.sans, size: 14).weight(.semibold))
                        .foregroundColor(Theme.Colors.ink)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.Colors.ok)
                        Text(AgentMarkdown.plainText(decision.pick))
                            .font(.custom(Theme.FontFamily.sans, size: 13).weight(.medium))
                            .foregroundColor(Theme.Colors.ink)
                            .multilineTextAlignment(.leading)
                    }
                    if !decision.why.isEmpty {
                        Text(AgentMarkdown.plainText(decision.why))
                            .font(.custom(Theme.FontFamily.sans, size: 12.5))
                            .foregroundColor(Theme.Colors.ink3)
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(ProjectPageLogic.tag(optionCount: decision.optionCount, artifactKind: decision.artifactKind))
                    .font(.custom(Theme.FontFamily.sans, size: 11.5))
                    .foregroundColor(Theme.AskDoc.Colors.quiet)
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .background(Theme.Colors.win)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Colors.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

private struct ThemeCard: View {
    let theme: ProjectTheme
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(theme.text)
                    .font(.custom(Theme.FontFamily.sans, size: 13.5).weight(.semibold))
                    .foregroundColor(theme.enabled ? Theme.Colors.ink : Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                ProjectSwitch(isOn: theme.enabled, label: theme.text, action: onToggle)
            }
            Text(ProjectPageLogic.evidenceLine(count: theme.evidenceCount, quote: theme.quotes.first))
                .font(.custom(Theme.FontFamily.sans, size: 12))
                .foregroundColor(Theme.AskDoc.Colors.quiet)
                .lineLimit(2)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.enabled ? Theme.Colors.win : Theme.Colors.list)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Colors.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: theme.enabled)
    }
}

/// The 26 x 15 switch of the Pen frame: ink track when on, grey when off, a 11 pt white knob.
struct ProjectSwitch: View {
    let isOn: Bool
    let label: String
    let action: (Bool) -> Void

    var body: some View {
        Button { action(!isOn) } label: {
            Capsule()
                .fill(isOn ? Theme.Colors.ink : Theme.Colors.switchOff)
                .frame(width: 26, height: 15)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(isOn ? Theme.Colors.onFill : Theme.Colors.switchOffKnob).frame(width: 11, height: 11).padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: isOn)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
