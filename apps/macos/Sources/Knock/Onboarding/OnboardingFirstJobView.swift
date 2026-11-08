import SwiftUI

/// Step 2 "What are you working on?" (WAG-338): a project, a first job, and where the job goes.
struct OnboardingFirstJobView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingHeaderView(
                title: "What are you working on?",
                subtitle: "Pick a project and a first job. Your agent scouts the options and brings them to Waggle.",
                stepLabel: OnboardingStep.firstJob.label
            )
            sectionLabel("PROJECT")
            projectRow
            sectionLabel("FIRST JOB").padding(.top, 2)
            jobCards
            if model.jobSelection == .own { ownField }
            routeLine
            Spacer(minLength: 0)
            footer
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .knockTextStyle(Theme.Typography.labelCaps10_5w600)
            .foregroundColor(Theme.Colors.ink3)
    }

    // MARK: Project

    private var projectRow: some View {
        WrapLayout(spacing: 8) {
            ForEach(model.projects) { project in
                OnboardingChoiceCard(isSelected: isPicked(project), padding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12), action: { model.select(project) }) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .knockTextStyle(Theme.Typography.button13_5w600)
                            .foregroundColor(Theme.Colors.ink)
                            .lineLimit(1)
                        Text(project.detail)
                            .knockTextStyle(Theme.Typography.caption11_5w400)
                            .foregroundColor(Theme.Colors.ink3)
                            .lineLimit(1)
                    }
                }
                .help(project.folder ?? "")
            }
        }
    }

    /// The tile of the project in use. A folder picked by hand lives on the "Something else" tile.
    private func isPicked(_ project: OnboardingProject) -> Bool {
        guard let selected = model.selectedProject else { return false }
        return project.id == selected.id
    }

    // MARK: Jobs

    private var projectName: String { model.selectedProject?.name ?? "the folder" }

    private var jobCards: some View {
        VStack(spacing: 6) {
            jobCard(
                .findDecision, title: "Let the agent find a real decision",
                detail: "It looks at \(projectName) (recent commits, open TODOs) and brings one open decision with options.",
                tag: "✦ Default", tagColor: Theme.Colors.recommendedTagText)
            ForEach(Array(model.suggestions.enumerated()), id: \.offset) { index, suggestion in
                jobCard(.suggestion(index), title: suggestion.title, detail: suggestion.source, tag: "Suggested", tagColor: Theme.Colors.recommendedTagText)
            }
            jobCard(.own, title: "Type your own", detail: "What are you deciding right now?", tag: nil, tagColor: .clear)
        }
    }

    private func jobCard(_ selection: OnboardingModel.JobSelection, title: String, detail: String, tag: String?, tagColor: Color) -> some View {
        let isSelected = model.jobSelection == selection
        return OnboardingChoiceCard(isSelected: isSelected, action: { model.selectJob(selection) }) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(isSelected ? Theme.Colors.ink : Theme.Colors.line2, lineWidth: 1.5)
                    if isSelected { Circle().fill(Theme.Colors.ink).padding(2) }
                }
                .frame(width: Theme.Spacing.radioSize, height: Theme.Spacing.radioSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .knockTextStyle(Theme.Typography.button13_5w600)
                        .foregroundColor(Theme.Colors.ink)
                        .lineLimit(1)
                    Text(detail)
                        .knockTextStyle(Theme.Typography.caption11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let tag {
                    Text(tag)
                        .knockTextStyle(Theme.Typography.tagLabel10_5w500)
                        .foregroundColor(tagColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var ownField: some View {
        TextField("What are you deciding right now?", text: $model.ownJobText)
            .textFieldStyle(.plain)
            .knockTextStyle(Theme.Typography.body13w400)
            .foregroundColor(Theme.Colors.ink)
            .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
            .background(RoundedRectangle(cornerRadius: Theme.Radius.composer).fill(Theme.Colors.win))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.composer).stroke(Theme.Colors.line, lineWidth: 1))
            .accessibilityLabel("Your own job")
            .onSubmit { Task { await model.startFirstJob() } }
    }

    // MARK: Where it goes

    @ViewBuilder private var routeLine: some View {
        if model.selectedProject != nil {
            HStack(spacing: 8) {
                Circle().fill(model.routing.usesOpenSession ? Theme.Colors.ok : Theme.Colors.ink3).frame(width: Theme.Spacing.regionHandleSize, height: Theme.Spacing.regionHandleSize)
                Text(model.routing.line(projectName: projectName))
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if model.routing.canChange {
                    SettingsSecondaryButton(title: "Change", action: model.changeRoute)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
            .background(RoundedRectangle(cornerRadius: Theme.Radius.threadCard).fill(Theme.Colors.list))
        }
        switch model.startPhase {
        case .failed(let text):
            Text(text)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.accent)
                .fixedSize(horizontal: false, vertical: true)
        case .copied:
            Text("Prompt copied. Paste it in Codex or the Claude app.")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ok)
        default:
            EmptyView()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            OnboardingGhostButton(title: "Back", action: model.backToConnect)
            Spacer()
            OnboardingGhostButton(title: "Copy prompt", action: model.copyPrompt)
                .disabled(model.firstJobPrompt == nil)
            OnboardingPrimaryButton(title: model.startPhase == .starting ? "Starting…" : model.routing.startLabel, action: { Task { await model.startFirstJob() } })
                .disabled(!model.canStart)
        }
    }
}

/// Lays children out left to right and wraps to the next row when the width runs out.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
