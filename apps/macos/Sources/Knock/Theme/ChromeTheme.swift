import SwiftUI

// MARK: - The window chrome around the decision column (sidebar, top bar, page header, artifact card)

extension Theme.AskDoc {
    /// The sidebar, the top bar, the page header and the artifact card of the request page, from the CSS of mockup B
    /// (`design/mockups/2026-11-09-request-page/index.html`: `.side`, `.side-head`, `.sec`, `.row`, `.side-foot`,
    /// `.ctx`, `h1`) and of the case map (`design/mockups/2026-11-09-request-page-cases/index.html`: `.needs`,
    /// `.count`, `.top`, `.pill`, `.ico`, `.art`, `.card`, `.card-h`, `.tab-a`, `.ver`, `.btn-s`). 1 CSS px = 1 pt.
    /// Rows and choices: STYLE-AUDIT.md §6.
    enum Chrome {
        private typealias C = Column

        // `.side`: 300 wide (B), `--side` fill, 1 pt `--line` on the right.
        static let sidebarWidth: CGFloat = 300
        static let sidebarFill = Theme.Colors.side
        /// Every sidebar edge: `.side-head`, `.sec`, `.row` and `.side-foot` all pad 16 at the sides.
        static let sideInset: CGFloat = 16

        // `.side-head` (B: padding 40 16 12), `.brand` (500 15, −0.03 em, gap 7), `.mark` 16.
        static let headTop: CGFloat = 40
        static let headBottom: CGFloat = 12
        static let brand = C.css(15, .medium, tracking: -0.45)
        static let markSize: CGFloat = 16
        static let brandGap: CGFloat = 7
        // Case map `.needs` (600 14, gap 6) and `.count` (700 11, padding 1 6, radius 9).
        static let needsLabel = C.css(14, .semibold)
        static let needsGap: CGFloat = 6
        static let countPill = C.css(11, .bold)
        static let countPillInset = EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6)

        // `.sec`: 600 10.5/1, 0.06 em, caps, quiet, padding 14 16 6. `.sec button`: 500 12/1, ink3, no caps.
        static let section = C.css(10.5, .semibold, lineHeight: 1, tracking: 0.63)
        static let sectionInset = EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16)
        static let sectionButton = C.css(12, .medium, lineHeight: 1)

        // `.row`: gap 9, padding 9 16, the dot on the title's first baseline, 1 up. `.row-t` 600 13.5/1.3 ink;
        // `.row.done .row-t` 500 ink2; `.row-m` quiet 12 (/1.45), 2 under the title.
        static let rowInset = EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
        static let rowGap: CGFloat = 9
        static let rowTitle = C.css(13.5, .semibold, lineHeight: 1.3)
        static let rowTitleDone = C.css(13.5, .medium, lineHeight: 1.3)
        static let rowMeta = C.css(12)
        static let rowMetaGap: CGFloat = 2
        static let dotSize: CGFloat = 7
        /// `.row .dot { transform: translateY(-1px) }`: the dot's bottom sits 1 pt over the baseline.
        static let dotLift: CGFloat = 1
        /// `.row.sel`: white with a 3 pt honey bar on the left (`box-shadow: inset 3px 0 0 --honey500`).
        static let selectedFill = Theme.Colors.win
        static let selectedBar = Theme.Colors.honey500
        static let selectedBarWidth: CGFloat = 3

        // `.side-foot`: padding 12 16, `--line` on top, ink3 12, gap 7.
        static let footer = C.css(12)
        static let footerInset = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        static let footerGap: CGFloat = 7

        // Case map `.top`: 46 high, padding 0 18, gap 10, `--line` under it, mono 400 11.5/1 ink3, the project ink.
        static let topBarHeight: CGFloat = 46
        static let topBarSide: CGFloat = 18
        static let topBarGap: CGFloat = 10
        static let crumb = C.css(11.5, lineHeight: 1, mono: true)
        // `.pill`: 500 12/1, padding 4 10, round; `.pill.waiting`: honey soft, need label. `.r`: gap 12.
        static let pill = C.css(12, .medium, lineHeight: 1)
        static let pillInset = EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        static let rightGap: CGFloat = 12
        /// `.ico`: ink3 14.
        static let iconSize: CGFloat = 14

        // Mockup B, no artifact: no top bar line and no crumb in it, the page starts 44 down; `.ctx` (mono 400
        // 11.5/1, quiet, caps, 10 under it) then `h1` 600 28/1.15, −0.03 em.
        static let pageTopBarHeight: CGFloat = 44
        static let pageTitle = C.css(28, .semibold, lineHeight: 1.15, tracking: -0.84)
        static let eyebrowGap: CGFloat = 10

        // `.art` padding 14 14 14 18; `.card` 1 pt `--line`, radius 10; `.card-h` 40 high, padding 0 10, gap 6.
        static let artInset = EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 14)
        static let cardRadius: CGFloat = 10
        static let cardHeaderHeight: CGFloat = 40
        static let cardHeaderSide: CGFloat = 10
        static let cardHeaderGap: CGFloat = 6
        // `.tab-a` 12.5, padding 5 9, radius 6, ink3; `.tab-a.on`: side fill, ink, 500.
        static let artTab = C.css(12.5)
        static let artTabOn = C.css(12.5, .medium)
        static let artTabInset = EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9)
        static let artTabRadius: CGFloat = 6
        // `.ver` mono 11/1 quiet; `.btn-s` 12, padding 4 9, radius 7, 1 pt `--line2`, white.
        static let version = C.css(11, lineHeight: 1, mono: true)
        static let smallButton = C.css(12)
        static let smallButtonInset = EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
        static let smallButtonRadius: CGFloat = 7
    }
}

/// The sidebar's caps header in the mockup's `.sec` look: "NEEDS YOU · 2".
struct ChromeSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .knockTextStyle(Theme.AskDoc.Chrome.section)
            .foregroundColor(Theme.AskDoc.Colors.quiet)
            .lineLimit(1)
    }
}

/// The top bar's header meta, split as the case map's `.top` shows it: the times in the crumb line ("arrived 15:24"),
/// the wait as a pill on the right ("Waiting 7m"). `eyebrowTimes` is the same for mockup B's eyebrow ("Round 2 · 15:24").
struct TopBarMeta: Equatable {
    let line: String
    let waiting: String?
    let eyebrowTimes: String

    init(_ label: String) {
        var rest = label
        var waiting: String?
        if let range = label.range(of: " · waiting ") {
            waiting = "Waiting " + label[range.upperBound...]
            rest = String(label[..<range.lowerBound])
        }
        self.waiting = waiting
        line = rest.hasPrefix("Arrived ") ? "arrived " + rest.dropFirst("Arrived ".count) : rest
        eyebrowTimes = rest.replacingOccurrences(of: "Arrived ", with: "").replacingOccurrences(of: " · arrived ", with: " · ")
    }
}

/// `.pill.waiting`: 500 12/1 need label on honey soft, round.
struct TopBarPill: View {
    let text: String

    var body: some View {
        Text(text)
            .knockTextStyle(Theme.AskDoc.Chrome.pill)
            .foregroundColor(Theme.AskDoc.Colors.needLabel)
            .lineLimit(1)
            .fixedSize()
            .padding(Theme.AskDoc.Chrome.pillInset)
            .background(Capsule().fill(Theme.Colors.honeySoft))
    }
}

/// Mockup B's `.ctx` over the title of a page with no artifact: "SAMPLE BLOG · IMAGE HOSTING · ROUND 2 · 15:00"
/// (mono 400 11.5/1, quiet, caps). The project name opens the project page, as the top bar crumb does.
struct PageEyebrow: View {
    let task: KnockTask
    let sessionTitle: String?
    let meta: String
    var onOpenProject: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if let onOpenProject {
                Button(action: onOpenProject) { project.contentShape(Rectangle()) }
                    .buttonStyle(.plain).pointerCursor()
                    .help("Open the project page")
            } else {
                project.help(AskCrumbs.folderHelp(task))
            }
            let rest = [AskCrumbs.titlePart(task: task, sessionTitle: sessionTitle), meta.isEmpty ? nil : meta].compactMap { $0 }
            if !rest.isEmpty {
                Text(" · " + rest.joined(separator: " · ").uppercased())
                    .knockTextStyle(Theme.AskDoc.Column.eyebrow)
                    .foregroundColor(Theme.AskDoc.Colors.quiet)
                    .lineLimit(1).truncationMode(.tail)
                    .help(AskCrumbs.folderHelp(task))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var project: some View {
        Text(AskCrumbs.projectName(task).uppercased())
            .knockTextStyle(Theme.AskDoc.Column.eyebrow)
            .foregroundColor(Theme.AskDoc.Colors.quiet)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct RoundTagInEyebrowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True on the page with no artifact: the round ("ROUND 2") is in the page eyebrow, so the title does not repeat it.
    var roundTagInEyebrow: Bool {
        get { self[RoundTagInEyebrowKey.self] }
        set { self[RoundTagInEyebrowKey.self] = newValue }
    }
}

/// A sidebar row's state dot on the title's first baseline, as `.row { align-items: baseline }` places it.
extension View {
    func sidebarDotOnBaseline() -> some View {
        alignmentGuide(.firstTextBaseline) { $0[.bottom] + Theme.AskDoc.Chrome.dotLift }
    }
}
