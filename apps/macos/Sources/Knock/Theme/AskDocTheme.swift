import SwiftUI

/// Tokens of the decision doc (WAG-257). Values come from the Pen band "WAG-257 · Ask pane" (Round 2
/// "Scale plus a honey need", Round 4 "Where the artifacts sit") read with resolved variables, and from
/// the approved prototype. Pen's 650 weight maps to semibold, the nearest step SwiftUI offers.
extension Theme {
    enum AskDoc {
        enum Colors {
            /// "WHAT I NEED FROM YOU" label on honey soft.
            static let needLabel = Color(hex: 0x9A6A00)
            /// Answered rows and the crumbs line.
            static let quiet = Color(hex: 0x8A8A8A)
            /// A pro's mark and the plus beside it.
            static let pro = Color(hex: 0x0E7A43)
            /// A con's mark and the minus beside it.
            static let con = Color(hex: 0xB3261E)
            /// "Watch out" in the calm card (WAG-281): orange-red, not the con red.
            static let watch = Color(hex: 0xC2410C)
            /// The soft fill of the "Watch n" chip in the bottom bar (WAG-293).
            static let watchSoft = Color(hex: 0xFFEDE3)
            static let proSoft = Color(hex: 0xF6FCF8)
            static let proBorder = Color(hex: 0xBFE6CF)
            /// The pill count text on the honey chip of the selected variant.
            static let variantOnText = Color(hex: 0x8A5A00)
        }

        enum Radius {
            /// The need box (case map mockup `.need`, decision 2026-11-10).
            static let need: CGFloat = 10
            static let artifactCard: CGFloat = 14
            static let thumb: CGFloat = 10
            static let pointCard: CGFloat = 14
            static let optionCard: CGFloat = 10
        }

        enum Metrics {
            static let thumbWide = CGSize(width: 120, height: 84)
            static let thumbShared = CGSize(width: 120, height: 84)
            static let panelWidth: CGFloat = 520
            static let panelSlide: Double = 0.22
            static let pageMaxWidth: CGFloat = 760
            static let scrollingCardWidth: CGFloat = 300
        }

        enum Typography {
            /// The title of a wide column (WAG-302): the Waggle title scale, 28/600 with -0.03em tracking.
            static let askTitle28 = TextStyle(
                font: .custom(FontFamily.sans, size: 28).weight(.semibold),
                size: 28, lineHeight: 1.15, letterSpacing: -0.84)
            static let askTitle32 = TextStyle(
                font: .custom(FontFamily.sans, size: 32).weight(.semibold),
                size: 32, lineHeight: 1.12, letterSpacing: -0.96)
            static let crumbs12 = TextStyle(font: .custom(FontFamily.sans, size: 12), size: 12, lineHeight: nil, letterSpacing: nil)
            static let crumbs12_5 = TextStyle(font: .custom(FontFamily.sans, size: 12.5), size: 12.5, lineHeight: nil, letterSpacing: nil)
            static let earlierTitle13_5 = TextStyle(
                font: .custom(FontFamily.sans, size: 13.5).weight(.semibold), size: 13.5, lineHeight: nil, letterSpacing: nil)
            static let monoLabel10_5 = TextStyle(
                font: .custom(FontFamily.mono, size: 10.5).weight(.semibold), size: 10.5, lineHeight: nil, letterSpacing: 0.6)
            static let need17 = TextStyle(font: .custom(FontFamily.sans, size: 17), size: 17, lineHeight: 1.55, letterSpacing: nil)
            static let why13_5 = TextStyle(font: .custom(FontFamily.sans, size: 13.5), size: 13.5, lineHeight: 1.5, letterSpacing: nil)
            static let questionTitle23 = TextStyle(
                font: .custom(FontFamily.sans, size: 23).weight(.semibold), size: 23, lineHeight: 1.25, letterSpacing: -0.46)
            static let artifactName15 = TextStyle(
                font: .custom(FontFamily.sans, size: 15).weight(.semibold), size: 15, lineHeight: nil, letterSpacing: nil)
            static let artifactMeta12_5 = TextStyle(font: .custom(FontFamily.sans, size: 12.5), size: 12.5, lineHeight: nil, letterSpacing: nil)
            static let pointText14_5 = TextStyle(
                font: .custom(FontFamily.sans, size: 14.5).weight(.semibold), size: 14.5, lineHeight: 1.4, letterSpacing: nil)
            static let optionCard13 = TextStyle(font: .custom(FontFamily.sans, size: 13), size: 13, lineHeight: 1.4, letterSpacing: nil)
            static let optionLabel13w600 = TextStyle(
                font: .custom(FontFamily.sans, size: 13).weight(.semibold), size: 13, lineHeight: 1.4, letterSpacing: nil)
            static let chip12_5 = TextStyle(font: .custom(FontFamily.sans, size: 12.5), size: 12.5, lineHeight: nil, letterSpacing: nil)
            static let sidebarHeader15w650 = TextStyle(
                font: .custom(FontFamily.sans, size: 15).weight(.semibold), size: 15, lineHeight: nil, letterSpacing: nil)
            static let sidebarRow14w600 = TextStyle(
                font: .custom(FontFamily.sans, size: 14).weight(.semibold), size: 14, lineHeight: 1.35, letterSpacing: nil)
            static let answeredRow12_5 = TextStyle(font: .custom(FontFamily.sans, size: 12.5), size: 12.5, lineHeight: nil, letterSpacing: nil)
            static let countPill11_5w700 = TextStyle(
                font: .custom(FontFamily.sans, size: 11.5).weight(.bold), size: 11.5, lineHeight: nil, letterSpacing: nil)
        }
    }
}

// MARK: - The decision column, as the case map mockup draws it (decision 2026-11-10, STYLE-AUDIT.md)

extension Theme.AskDoc {
    /// Type and metrics of the request page's decision column, from the CSS of
    /// `design/mockups/2026-11-09-request-page-cases/index.html` (1 CSS px = 1 pt). A `TextStyle`'s `lineHeight`
    /// here already holds the CSS line height turned into the theme's `size × (lineHeight − 1)` spacing on top of
    /// the font's own line height (STYLE-AUDIT rule 1), so `knockTextStyle` and `AskTextFace` draw the CSS line box.
    enum Column {
        /// A text style that draws CSS `font: <weight> <size>px/<lineHeight>`: the exact bundled face (500 is
        /// Medium, 600 SemiBold) and the line height of the CSS box.
        static func css(
            _ size: CGFloat, _ weight: NSFont.Weight = .regular, lineHeight: CGFloat = cssDefaultLineHeight,
            tracking: CGFloat? = nil, mono: Bool = false
        ) -> Theme.TextStyle {
            let spacing = Theme.Typography.cssLineSpacing(size: size, lineHeight: lineHeight, mono: mono)
            return Theme.TextStyle(
                font: font(size, weight, mono: mono), size: size, lineHeight: 1 + spacing / size, letterSpacing: tracking)
        }

        /// The bundled face itself, so `.semibold` draws InterTight-SemiBold (600), never the bold trait.
        static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, mono: Bool = false) -> Font {
            if mono { return .custom(Theme.FontFamily.mono, size: size) }
            return .custom(PromptBarLogic.sansFaceName(for: weight), size: size)
        }

        /// The CSS line box height of one line: `size × lineHeight`, never under the font's own line.
        static func lineBox(_ size: CGFloat, lineHeight: CGFloat = cssDefaultLineHeight, mono: Bool = false) -> CGFloat {
            let natural = mono ? Theme.Typography.monoNaturalLineHeight : Theme.Typography.sansNaturalLineHeight
            return (size * max(lineHeight, natural)).rounded(.up)
        }

        /// `html, body { font: 400 13px/1.45 }`: every element without its own line height.
        static let cssDefaultLineHeight: CGFloat = 1.45

        // Edges (`.tabs` margin 10 14 0, `.cs` padding 14 18 10, `.ans` padding 10 14 12).
        static let tabsInset = EdgeInsets(top: 10, leading: 14, bottom: 0, trailing: 14)
        static let scrollInset = EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 18)
        static let answerSideInset: CGFloat = 14

        // Tabs (`.tabs`, `.tabs span`, `.tabs .n`).
        static let tabLabel = css(13, .medium)
        static let tabCount = css(11, lineHeight: 1, mono: true)
        static let tabsTrackRadius: CGFloat = 9
        static let tabSegmentRadius: CGFloat = 7
        static let tabShadowBlur: CGFloat = 2

        // `.fu`, `.fu b`, `.latest`, `.track`.
        static let followUp = css(12)
        static let followUpTitle = css(12, .medium)
        static let latestWho = css(10.5, lineHeight: 1, mono: true)
        static let latestText = css(12)
        static let track = css(11.5)
        static let trackCurrent = css(11.5, .semibold)
        static let trackGlyph = css(9, lineHeight: 1)

        // `h1`: 600 19/1.25, −0.02 em.
        static let title = css(19, .semibold, lineHeight: 1.25, tracking: -0.38)
        static let titleGap: CGFloat = 10

        // B `.ctx`: the eyebrow over the title (here the round tag).
        static let eyebrow = css(11.5, lineHeight: 1, mono: true)

        // `.need`, `.need .q`, `.need .why`, `.need .more`.
        static let need = css(13, lineHeight: 1.5)
        static let needQuestion = css(13.5, .semibold, lineHeight: 1.5)
        static let needWhy = css(12)
        static let needMore = css(12)
        static let needPadding = EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13)
        static let needParagraphGap: CGFloat = 7
        static let needGap: CGFloat = 14

        // Tables (case map `table.t` sizes, mockup B's outer border, radius and header fill).
        static let tableText = css(12)
        static let tableRadius: CGFloat = 10
        static let tableCellPadding = EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
        static let tableMarginTop: CGFloat = 4
        static let tableMarginBottom: CGFloat = 12

        // Conversation (`.msg`, `.msg .h`, `.round`).
        static let message = css(12.5, lineHeight: 1.5)
        static let messageHead = css(10.5, lineHeight: 1, mono: true)
        static let messagePadding = EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)
        static let messageGap: CGFloat = 8
        static let messageRadius: CGFloat = 10
        /// `.msg.you .h` (#aaa).
        static let yourHead = Color(hex: 0xAAAAAA)

        // The status line, in Inter Tight (B: 12.5).
        static let status = css(12.5, .medium)
        static let statusFailed = css(12.5, .semibold)
    }
}

