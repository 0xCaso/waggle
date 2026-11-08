import SwiftUI

/// The artifact cards of one ask or question, laid out by the three rules: one wide card, two or three
/// side by side, more than three in a row that scrolls.
struct ArtifactCardsView: View {
    let cards: [ArtifactCardModel]
    let selectedId: String?
    let lastTarget: (Bool) -> ArtifactOpenTarget
    let onOpen: (ArtifactCardModel, ArtifactOpenTarget) -> Void

    var body: some View {
        switch ArtifactCardsLayout.rule(count: cards.count) {
        case .none:
            EmptyView()
        case .wide:
            card(cards[0], wide: true)
        case .sideBySide(let columns):
            HStack(alignment: .top, spacing: 10) {
                ForEach(cards) { card($0, wide: false) }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(columns) artifacts")
        case .scrollingRow:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(cards) { card($0, wide: false).frame(width: Theme.AskDoc.Metrics.scrollingCardWidth) }
                }
            }
        }
    }

    private func card(_ model: ArtifactCardModel, wide: Bool) -> some View {
        ArtifactCardView(
            model: model, isWide: wide, isSelected: model.id == selectedId, lastTarget: lastTarget(model.opensFullSize),
            onOpen: { onOpen(model, $0) })
    }
}

/// One artifact card (prototype `.acard`): a 120 x 84 thumb with the type icon, the kind and version in
/// mono, the name, a meta line and a split Open button. A tap on the card opens it at the last place chosen.
struct ArtifactCardView: View {
    let model: ArtifactCardModel
    let isWide: Bool
    let isSelected: Bool
    let lastTarget: ArtifactOpenTarget
    let onOpen: (ArtifactOpenTarget) -> Void

    @State private var isHovering = false

    var body: some View {
        Group {
            if isWide {
                HStack(spacing: 14) {
                    thumb(width: Theme.AskDoc.Metrics.thumbWide.width, height: Theme.AskDoc.Metrics.thumbWide.height)
                    info
                    Spacer(minLength: 8)
                    SplitOpenButton(lastTarget: lastTarget, fullSize: model.opensFullSize, onOpen: onOpen)
                }
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 14))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    thumb(width: nil, height: 96)
                    info
                    HStack { Spacer(minLength: 0); SplitOpenButton(lastTarget: lastTarget, fullSize: model.opensFullSize, onOpen: onOpen) }
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.Colors.honeySoft : Theme.Colors.win)
        .clipShape(RoundedRectangle(cornerRadius: Theme.AskDoc.Radius.artifactCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.AskDoc.Radius.artifactCard)
                .stroke(isSelected ? Theme.Colors.honey500 : (isHovering ? Theme.Colors.line2 : Theme.Colors.line), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Theme.AskDoc.Radius.artifactCard))
        .onTapGesture { onOpen(lastTarget) }
        .onHover { isHovering = $0 }
        .pointerCursor()
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityElement(children: .contain)
    }

    private func thumb(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Theme.AskDoc.Radius.thumb)
            .fill(Theme.Colors.list)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay(
                Image(systemName: model.type.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(Theme.Colors.ink3))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: model.type.symbol)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Colors.ink2)
                Text(model.kindLine)
                    .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                    .foregroundColor(Theme.Colors.ink3)
            }
            Text(model.name)
                .knockTextStyle(Theme.AskDoc.Typography.artifactName15)
                .foregroundColor(Theme.Colors.ink)
            Text(model.meta)
                .knockTextStyle(Theme.AskDoc.Typography.artifactMeta12_5)
                .foregroundColor(Theme.Colors.ink3)
        }
    }
}

/// "Open" with a menu. A prototype lists Full size (the default), In a new window, In the browser; the
/// others list Side panel (the default), Full Waggle page, In a new window, In the browser. The tick marks
/// the last choice, which the main button uses.
struct SplitOpenButton: View {
    let lastTarget: ArtifactOpenTarget
    let fullSize: Bool
    let onOpen: (ArtifactOpenTarget) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { onOpen(lastTarget) } label: {
                Text("Open")
                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    .foregroundColor(Theme.Colors.ink)
                    .padding(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 10))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .accessibilityLabel("Open \(lastTarget.menuLabel.lowercased())")
            Rectangle().fill(Theme.Colors.line).frame(width: 1, height: 22)
            Menu {
                ForEach(ArtifactOpenTarget.menu(fullSize: fullSize), id: \.self) { target in
                    Button {
                        onOpen(target)
                    } label: {
                        if target == lastTarget {
                            Label(target.menuLabel + (target == .default(fullSize: fullSize) ? " (default)" : ""), systemImage: "checkmark")
                        } else {
                            Text(target.menuLabel + (target == .default(fullSize: fullSize) ? " (default)" : ""))
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.Colors.ink3)
                    .padding(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 9))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
            .accessibilityLabel("Choose where to open")
        }
        .background(Theme.Colors.win)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.Colors.line, lineWidth: 1))
    }
}
