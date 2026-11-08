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
            /// The need callout. Pen shows 12 on the wireframe; the brief and the prototype say 14.
            static let need: CGFloat = 14
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
