import AppKit
import KnockMark
import SwiftUI

/// AppKit/SwiftUI adapters over the single `KnockMark` geometry source
/// (contract: HAIL-23). Kept out of the `KnockMark` package itself so that
/// target stays plain Core Graphics, reusable from the `make-app-icon` CLI
/// too.
extension KnockMark {
    /// An 18x18 pt template image of the mark alone, for the menu-bar status
    /// item (the cell fills the 18x18 box, the w is knocked out). `isTemplate = true` lets macOS tint it
    /// for light and dark menu bars.
    static func menuBarTemplateImage() -> NSImage {
        let size = CGSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            KnockMark.draw(in: rect, context: context, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Draws the mark alone (no background) filling its bounds, for use inside a
/// larger lockup (headers, About). Default: the honey gradient cell with a
/// white w. Pass `color` for a one-colour cell with the w knocked out.
struct KnockMarkView: View {
    var color: Color? = nil

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.withCGContext { cgContext in
                if let color, let cgColor = color.cgColor {
                    KnockMark.draw(in: rect, context: cgContext, color: cgColor)
                } else {
                    let white = NSColor(Theme.Colors.onFill).cgColor
                    KnockMark.draw(in: rect, context: cgContext, fill: .honeyGradient, wColor: white)
                }
            }
        }
    }
}

/// The brand lockup: the honey cell and the "waggle" wordmark (Inter Tight
/// Medium, tracking -3.5%). Used in the queue header and the onboarding header.
struct WordmarkLockup: View {
    var markSize: CGFloat = 18
    var textSize: CGFloat = 15

    var body: some View {
        HStack(spacing: markSize * 0.35) {
            KnockMarkView().frame(width: markSize, height: markSize)
            Text("waggle")
                .knockTextStyle(Theme.Typography.wordmark(size: textSize))
                .foregroundColor(Theme.Colors.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("waggle")
    }
}
