import SwiftUI

/// The one-page layout's header (HAIL-84, HAIL-88): the review titlebar with the expand button
/// at its trailing edge (HAIL-96). The queue and the question column fold from their own chevrons.
struct SplitFoldHeaderView: View {
    @ObservedObject var fold: SplitFoldState
    let knockCase: Case
    let task: KnockTask
    var sessionTitle: String? = nil
    let now: Date
    let changedAt: Date?
    var roundArrivedAt: Date? = nil
    /// The question column's current width, for the header segment above it (HAIL-91).
    var askColumnWidth: CGFloat = 430
    /// "← Home" at the left of the header, for an ask that is not in Needs you (HAIL-121).
    var onHome: (() -> Void)? = nil
    /// The Share button of the case (WAG-387).
    var shareControl: AnyView? = nil

    /// The traffic lights float over this bar's left edge when no queue sits there. A folded
    /// queue leaves a rail, which covers part of that space; the open queue covers all of it.
    static func leadingReserve(queueOpen: Bool, railShown: Bool) -> CGFloat {
        if queueOpen { return 16 }
        return railShown ? Theme.Spacing.listHeaderLeadingReserve - QueueFoldedRailView.width : Theme.Spacing.listHeaderLeadingReserve
    }

    var body: some View {
        HStack(spacing: 0) {
            titlebar
            if !fold.isAskFolded {
                ColumnFoldHeaderSegment(
                    width: askColumnWidth, help: "Hide the decision (⌘])", background: Theme.Colors.side, onFold: fold.toggleAsk)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var titlebar: some View {
        ReviewTitlebarView(
            knockCase: knockCase, task: task, sessionTitle: sessionTitle, now: now, changedAt: changedAt, roundArrivedAt: roundArrivedAt, onBack: {},
            leadingControl: AnyView(
                Group {
                    if let onHome { HStack(spacing: 6) { HomeLinkButton(action: onHome) }.fixedSize() }
                }),
            trailingControls: AnyView(
                FoldIconButton(
                    symbol: BothFoldedCopy.symbol(isBothFolded: fold.isBothFolded),
                    isActive: fold.isBothFolded,
                    help: BothFoldedCopy.help(isBothFolded: fold.isBothFolded),
                    action: fold.toggleBothFolded)),
            shareControl: shareControl,
            leadingReserve: Self.leadingReserve(queueOpen: !fold.isQueueFolded, railShown: fold.isQueueFolded),
            showsTitle: fold.isAskFolded)
    }
}

/// A 24 pt icon button for the header's expand. `isActive` marks it while it is on.
struct FoldIconButton: View {
    let symbol: String
    let isActive: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundColor(isActive ? Theme.Colors.ink : Theme.Colors.ink3)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(help)
    }
}

/// The rounded square and the divider of a "panel toggle" icon (Lucide panel-left / panel-right).
/// The divider sits near `edge`, the side of the panel the icon controls.
struct PanelFrameShape: Shape {
    let edge: HorizontalEdge
    static let size = CGSize(width: 16, height: 14)
    static let stroke: CGFloat = 1.4
    static let corner: CGFloat = 3

    /// The divider's x, measured in the icon's own box.
    static func dividerX(edge: HorizontalEdge) -> CGFloat {
        edge == .leading ? 5.5 : size.width - 5.5
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: Self.stroke / 2, dy: Self.stroke / 2)
        var path = Path(roundedRect: box, cornerRadius: Self.corner, style: .continuous)
        let x = rect.minX + Self.dividerX(edge: edge)
        path.move(to: CGPoint(x: x, y: box.minY))
        path.addLine(to: CGPoint(x: x, y: box.maxY))
        return path
    }
}

/// The small chevron in the larger part of a panel toggle icon. It points right or left.
struct PanelChevronShape: Shape {
    let edge: HorizontalEdge
    let pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        let divider = PanelFrameShape.dividerX(edge: edge)
        let (from, to) = edge == .leading ? (divider, rect.width) : (0, divider)
        let centre = rect.minX + (from + to) / 2
        let half: CGFloat = 1.75
        let tip = pointsRight ? centre + half : centre - half
        let back = pointsRight ? centre - half : centre + half
        var path = Path()
        path.move(to: CGPoint(x: back, y: rect.midY - 3))
        path.addLine(to: CGPoint(x: tip, y: rect.midY))
        path.addLine(to: CGPoint(x: back, y: rect.midY + 3))
        return path
    }
}

/// A panel toggle icon: the frame at rest, the chevron too on hover (or when `forceHover`).
struct PanelToggleIcon: View {
    let edge: HorizontalEdge
    let pointsRight: Bool
    let hovering: Bool

    var body: some View {
        let colour = hovering ? Theme.Colors.ink : Theme.Colors.ink2
        ZStack {
            PanelFrameShape(edge: edge)
                .stroke(colour, style: StrokeStyle(lineWidth: PanelFrameShape.stroke, lineCap: .round, lineJoin: .round))
            PanelChevronShape(edge: edge, pointsRight: pointsRight)
                .stroke(colour, style: StrokeStyle(lineWidth: PanelFrameShape.stroke, lineCap: .round, lineJoin: .round))
                .opacity(hovering ? 1 : 0)
        }
        .frame(width: PanelFrameShape.size.width, height: PanelFrameShape.size.height)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// `KNOCK_PANEL_HOVER=1` (HAIL-88 evidence hook): draws every panel toggle as hovered.
enum PanelToggleEvidence {
    static let forceHover = ProcessInfo.processInfo.environment["KNOCK_PANEL_HOVER"] == "1"
}

/// The button on a panel itself that folds it (HAIL-88).
struct PanelFoldButton: View {
    let edge: HorizontalEdge
    let pointsRight: Bool
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            PanelToggleIcon(edge: edge, pointsRight: pointsRight, hovering: hovered || PanelToggleEvidence.forceHover)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// The part of the page header that sits above a right column (HAIL-91): exactly the column's
/// width, split off by the column's own border line, with the button that folds the column.
struct ColumnFoldHeaderSegment: View {
    let width: CGFloat
    let help: String
    var background: Color = .clear
    let onFold: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            PanelFoldButton(edge: .trailing, pointsRight: true, help: help, action: onFold)
        }
        .padding(.trailing, 10)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(background)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(width: 1), alignment: .leading)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
    }
}

/// What a folded queue leaves behind on the left edge: a slim rail with a chevron to reopen,
/// the Needs you count, and "Needs you" running down it. Click anywhere to reopen (HAIL-88).
struct QueueFoldedRailView: View {
    let count: Int
    let onUnfold: () -> Void
    static let width: CGFloat = 40
    @State private var hovered = false

    var body: some View {
        Button(action: onUnfold) {
            VStack(spacing: 10) {
                PanelToggleIcon(edge: .leading, pointsRight: true, hovering: hovered || PanelToggleEvidence.forceHover)
                Text("\(count)")
                    .knockTextStyle(Theme.Typography.countBadge10_5w600)
                    .foregroundColor(Theme.Colors.onFill)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Colors.accent))
                Text("Needs you")
                    .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                    .foregroundColor(Theme.Colors.ink2)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 20)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(-1)
            }
            .padding(.top, 44)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.Colors.list)
            .overlay(Rectangle().fill(Theme.Colors.line).frame(width: 1), alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .onHover { hovered = $0 }
        .help("Show the queue (⌘[)")
    }
}

/// What a folded question column leaves behind on the right edge: a slim rail with the answer
/// state ("Question · 2 options"), so the operator knows it is there. Click to unfold.
struct AskFoldedStripView: View {
    let label: String
    let onUnfold: () -> Void
    var help = "Show the decision (⌘])"
    var background = Theme.Colors.win
    static let width: CGFloat = 40
    @State private var hovered = false

    var body: some View {
        Button(action: onUnfold) {
            VStack(spacing: 12) {
                PanelToggleIcon(edge: .trailing, pointsRight: false, hovering: hovered || PanelToggleEvidence.forceHover)
                    .padding(.top, 14)
                Text(label)
                    .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                    .foregroundColor(Theme.Colors.ink2)
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 20)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(-1)
            }
            .frame(width: Self.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(background)
            .overlay(Rectangle().fill(Theme.Colors.line).frame(width: 1), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .onHover { hovered = $0 }
        .help(help)
    }
}
