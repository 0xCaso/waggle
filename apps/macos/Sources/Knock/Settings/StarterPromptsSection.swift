import SwiftUI

/// One starter prompt (HAIL-165). The text mirrors `daemon/src/guide/starter-prompts.md`
/// (HAIL-160); `StarterPromptsTests` fails when the two drift.
struct StarterPrompt: Equatable {
    let title: String
    let text: String
}

enum StarterRole: String, CaseIterable, Identifiable {
    case research = "Research"
    case productMarketing = "Product marketing"
    case design = "Design"

    var id: String { rawValue }

    var prompts: [StarterPrompt] {
        switch self {
        case .research:
            return [
                StarterPrompt(
                    title: "Waggle a research question",
                    text: "Waggle this question with me: <question>. Ask me which angle matters, collect what you find, and send each round as a markdown review I can comment on."),
                StarterPrompt(
                    title: "Interview guide, then a summary",
                    text: "Draft an interview guide for <topic> and send it for review. After I run the calls, I will paste notes: send back the themes with quotes."),
            ]
        case .productMarketing:
            return [
                StarterPrompt(
                    title: "Variants of a deck in Pen",
                    text: "Take <deck or slide> and draw three variants in Pen. Send them as a screenshot gallery and let me pick one or mix parts."),
                StarterPrompt(
                    title: "One message, three tones",
                    text: "Write <message> in three tones. Send them as options in Waggle with your pick and why."),
            ]
        case .design:
            return [
                StarterPrompt(
                    title: "From idea to prototype in Pen",
                    text: "Start from this idea: <idea>. Ask me two or three questions, draw the key screens in Pen, send them for review, then build a clickable prototype."),
                StarterPrompt(
                    title: "Review a screen",
                    text: "Look at <screen or frame> and send me what feels off as a review, with one fix per point."),
            ]
        }
    }
}

enum StarterPrompts {
    static let footnote = "Replace the <words> with yours. Your agent asks you in Waggle as it goes."
}

/// Optional "Starter prompts" block on Settings > Agents: role tabs, two copyable prompts each.
/// Nothing is stored and no role is asked for anywhere else.
struct StarterPromptsSection: View {
    @State private var role: StarterRole = .research

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SettingsSectionLabel("STARTER PROMPTS")
                Spacer(minLength: 12)
                roleTabs
            }
            SettingsCard {
                let prompts = role.prompts
                ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                    row(prompt, showsDivider: index < prompts.count - 1)
                }
            }
            Text(StarterPrompts.footnote)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
        }
    }

    private var roleTabs: some View {
        HStack(spacing: 0) {
            ForEach(StarterRole.allCases) { item in
                let selected = item == role
                Button(action: { role = item }) {
                    Text(item.rawValue)
                        .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                        .foregroundColor(selected ? Theme.Colors.ink : Theme.Colors.ink2)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(selected ? Theme.Colors.win : Color.clear)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain).pointerCursor()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.Colors.side)
        .cornerRadius(8)
    }

    private func row(_ prompt: StarterPrompt, showsDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title)
                        .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                        .foregroundColor(Theme.Colors.ink)
                    Text(prompt.text)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                SettingsCopyButton(text: prompt.text)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            if showsDivider {
                Rectangle().fill(Theme.Colors.line).frame(height: 1)
            }
        }
    }
}
