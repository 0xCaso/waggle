import SwiftUI

extension Theme.Typography {
    // WAG-362, Pen band "WAG-362 · Simple Home", frame "A · Three pictures".
    static let homeHeadline28w600 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 28).weight(.semibold), size: 28, lineHeight: nil, letterSpacing: -0.84)
    static let homeLead14 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 14), size: 14, lineHeight: nil, letterSpacing: nil)
    static let homeStepName15w600 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 15).weight(.semibold), size: 15, lineHeight: nil, letterSpacing: -0.3)
    static let homeStepLine13 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 13), size: 13, lineHeight: 1.5, letterSpacing: nil)
    static let homeDecided12w600 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 12).weight(.semibold), size: 12, lineHeight: nil, letterSpacing: nil)
    // The launch chips of the first job (WAG-255).
    static let ideaChip12_5 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 12.5), size: 12.5, lineHeight: nil, letterSpacing: nil)
    static let ideaChip12_5w600 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 12.5).weight(.semibold), size: 12.5, lineHeight: nil, letterSpacing: nil)
}

/// What Home shows, top to bottom (WAG-362, operator, 13 Oct): three pictures of what Waggle is for.
/// Nothing on it can be clicked, and it starts nothing. A plugin card sits above them when there is one.
enum HomePage {
    enum Block: Equatable { case pluginOffer, pluginSetup, steps }

    enum Step: CaseIterable, Equatable {
        case plan, prototype, decide

        var name: String {
            switch self {
            case .plan: return "Plan"
            case .prototype: return "Prototype variants"
            case .decide: return "Decide"
            }
        }

        var line: String {
            switch self {
            case .plan: return "Your agent asks a few questions, then writes the plan."
            case .prototype: return "It builds two or three ways to do it. You click through them."
            case .decide: return "Pick one. Your agent gets the answer and builds it."
            }
        }
    }

    static func blocks(showsPluginOffer: Bool = false, showsPluginSetup: Bool = false) -> [Block] {
        var result: [Block] = []
        if showsPluginOffer { result.append(.pluginOffer) }
        if showsPluginSetup { result.append(.pluginSetup) }
        return result + [.steps]
    }

    static let headline = "Plan it. See the options. Decide."
    static let lead = "Your agent does the work in between. Waggle is where you look and choose."
    static let foot = "It starts in your agent's session. What it needs from you lands here."
}

/// Home (WAG-362): the pane when no ask is open and none needs you.
struct HomeView: View {
    @ObservedObject private var pluginOffer = PluginOfferModel.shared

    var body: some View {
        let blocks = HomePage.blocks(
            showsPluginOffer: pluginOffer.showsHomeCard,
            showsPluginSetup: pluginOffer.showsSetupCard && pluginOffer.setup != nil)
        VStack(spacing: 0) {
            ForEach(blocks, id: \.self) { block in
                switch block {
                case .pluginOffer:
                    HStack { PluginOfferCard(offer: pluginOffer); Spacer(minLength: 0) }
                        .padding(EdgeInsets(top: 24, leading: 40, bottom: 0, trailing: 40))
                case .pluginSetup:
                    if let setup = pluginOffer.setup {
                        HStack { PluginSetupCard(offer: pluginOffer, setup: setup); Spacer(minLength: 0) }
                            .padding(EdgeInsets(top: 24, leading: 40, bottom: 0, trailing: 40))
                    }
                case .steps:
                    EmptyView()
                }
            }
            HomeStepsView()
                .frame(maxWidth: 720)
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Colors.win)
        .preferredColorScheme(.light)
        .task { await pluginOffer.startIfNeeded() }
    }
}

/// The headline and the three pictures. In a row when the pane is wide, in a column when it is not.
struct HomeStepsView: View {
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(HomePage.headline)
                    .knockTextStyle(Theme.Typography.homeHeadline28w600)
                    .foregroundColor(Theme.Colors.ink)
                    .multilineTextAlignment(.center)
                Text(HomePage.lead)
                    .knockTextStyle(Theme.Typography.homeLead14)
                    .foregroundColor(Theme.Colors.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 32)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) { steps(compact: false) }
                    .frame(minWidth: 560, idealWidth: 560, maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) { steps(compact: true) }
                    .frame(maxWidth: 440)
            }
            Text(HomePage.foot)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)
        }
    }

    @ViewBuilder
    private func steps(compact: Bool) -> some View {
        ForEach(Array(HomePage.Step.allCases.enumerated()), id: \.offset) { index, step in
            if index > 0, !compact {
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.Colors.line2)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
            HomeStepCard(step: step, compact: compact)
        }
    }
}

private struct HomeStepCard: View {
    let step: HomePage.Step
    /// A narrow pane: the picture sits beside the words, so the three steps stay on one screen.
    let compact: Bool

    var body: some View {
        let layout = compact
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        layout {
            picture
                .padding(compact ? 10 : 12)
                .frame(maxWidth: compact ? 150 : .infinity, alignment: .leading)
                .frame(height: compact ? 92 : 120)
                .background(Theme.Colors.win)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.Colors.line, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.name)
                    .knockTextStyle(Theme.Typography.homeStepName15w600)
                    .foregroundColor(Theme.Colors.ink)
                Text(step.line)
                    .knockTextStyle(Theme.Typography.homeStepLine13)
                    .foregroundColor(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.list)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.Colors.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.name). \(step.line)")
    }

    @ViewBuilder
    private var picture: some View {
        switch step {
        case .plan:
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                bar(width: compact ? 50 : 70, height: 7, color: Theme.Colors.honey500)
                question(answered: true, width: compact ? 96 : 140)
                question(answered: true, width: compact ? 70 : 100)
                question(answered: false, width: compact ? 96 : 140)
            }
        case .prototype:
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { variant($0, selected: false, caption: !compact) }
            }
        case .decide:
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { variant($0, selected: $0 == 1, caption: false) }
                }
                .frame(height: compact ? 40 : 58)
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    Text("Decided").knockTextStyle(Theme.Typography.homeDecided12w600)
                }
                .foregroundColor(Theme.Colors.ok)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Theme.Colors.okSoft)
                .clipShape(Capsule())
            }
        }
    }

    private func bar(width: CGFloat?, height: CGFloat = 6, color: Color = Theme.Colors.sel) -> some View {
        RoundedRectangle(cornerRadius: height / 2).fill(color)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }

    private func question(answered: Bool, width: CGFloat) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(answered ? Theme.Colors.honey500 : Theme.Colors.win)
                .overlay(Circle().strokeBorder(answered ? Theme.Colors.honey500 : Theme.Colors.line2, lineWidth: 1.5))
                .frame(width: 11, height: 11)
            bar(width: width)
        }
    }

    private func block() -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Theme.Colors.hover).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One small screen: a full block, two stacked blocks, or a side strip with a block.
    private func variant(_ index: Int, selected: Bool, caption: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            switch index {
            case 0: block()
            case 1: VStack(spacing: 5) { block(); block() }
            default: HStack(spacing: 5) { block().frame(width: 14); block() }
            }
            if caption { bar(width: 22) }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(selected ? Theme.Colors.honeySoft : Theme.Colors.win)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(selected ? Theme.Colors.honey500 : Theme.Colors.line, lineWidth: selected ? 1.5 : 1))
    }
}
