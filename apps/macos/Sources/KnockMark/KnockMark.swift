import AppKit
import CoreGraphics

/// The Waggle "Cell W" mark (HAIL-171): a pointy-top honeycomb cell with a
/// single-line lowercase w. The single geometry source for the app icon, the
/// menu-bar glyph and the in-app lockup mark. Points are in a 100x100 box and
/// mirror `favicon.svg` of the Waggle site and `Resources/AppIcon.svg`
/// (a test compares them with the committed SVG).
///
/// (The module keeps its old name: renames belong to HAIL-176.)
public enum KnockMark {
    // MARK: Cell (pointy-top hexagon in a 100 box)

    public static let cellPoints: [CGPoint] = [
        CGPoint(x: 50, y: 0), CGPoint(x: 93.3, y: 25), CGPoint(x: 93.3, y: 75),
        CGPoint(x: 50, y: 100), CGPoint(x: 6.7, y: 75), CGPoint(x: 6.7, y: 25),
    ]
    // MARK: W (one line, round joins and caps)

    public static let wPoints: [CGPoint] = [
        CGPoint(x: 27, y: 40), CGPoint(x: 38, y: 63), CGPoint(x: 50, y: 43),
        CGPoint(x: 62, y: 63), CGPoint(x: 73, y: 40),
    ]
    public static let wStrokeWidth: CGFloat = 10

    public static let honeyTop = CGColor(srgbRed: 0xF9 / 255.0, green: 0xC8 / 255.0, blue: 0x46 / 255.0, alpha: 1)
    public static let honeyBottom = CGColor(srgbRed: 0xE8 / 255.0, green: 0x9A / 255.0, blue: 0x0C / 255.0, alpha: 1)

    public enum CellFill {
        /// The brand gradient, honey300 at the top to honey600 at the bottom.
        case honeyGradient
        case solid(CGColor)
    }

    private static func cellPath(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let scale = side / 100
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let path = CGMutablePath()
        for (index, point) in cellPoints.enumerated() {
            let mapped = CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
            if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
        }
        path.closeSubpath()
        return path
    }

    private static func wPath(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let scale = side / 100
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let path = CGMutablePath()
        for (index, point) in wPoints.enumerated() {
            let mapped = CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
            if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
        }
        return path
    }

    /// Draws the cell filled with `fill` and the w stroked in `wColor`.
    /// A nil `wColor` punches the w out of the cell (a one-colour glyph, for
    /// template images). `context` must use a top-left-origin, y-down system
    /// (a flipped `NSImage`, a flipped bitmap, a SwiftUI `Canvas`), so the
    /// gradient runs top to bottom on screen.
    public static func draw(in rect: CGRect, context: CGContext, fill: CellFill, wColor: CGColor?) {
        let side = min(rect.width, rect.height)
        context.saveGState()
        context.addPath(cellPath(in: rect))
        switch fill {
        case .solid(let color):
            context.setFillColor(color)
            context.fillPath()
        case .honeyGradient:
            context.clip()
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [honeyTop, honeyBottom] as CFArray,
                locations: [0, 1]
            )!
            let cell = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: cell.midX, y: cell.minY),
                end: CGPoint(x: cell.midX, y: cell.maxY),
                options: []
            )
        }
        context.restoreGState()

        context.saveGState()
        context.addPath(wPath(in: rect))
        context.setLineWidth(wStrokeWidth * side / 100)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        if let wColor {
            context.setStrokeColor(wColor)
        } else {
            context.setBlendMode(.clear)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        }
        context.strokePath()
        context.restoreGState()
    }

    /// One-colour cell with the w knocked out: the menu-bar glyph.
    public static func draw(in rect: CGRect, context: CGContext, color: CGColor) {
        draw(in: rect, context: context, fill: .solid(color), wColor: nil)
    }

    // MARK: Dev band (HAIL-26)

    /// The "DEV" band's height as a fraction of the icon side: the bottom
    /// quarter of the icon.
    public static let devBandHeightRatio: CGFloat = 0.25
    /// The "DEV" label font size as a fraction of the band height.
    public static let devFontSizeRatio: CGFloat = 0.5
    /// The dark band colour. Mirrors the near-black text colour of the app.
    public static let devBandColor = CGColor(
        srgbRed: 0x1A / 255.0,
        green: 0x1A / 255.0,
        blue: 0x1A / 255.0,
        alpha: 1
    )

    /// Draws a dark strip across the bottom quarter of `rect` with the white
    /// "DEV" label centred in it. The caller clips `rect` to the rounded icon
    /// shape first, so the strip's bottom corners follow the icon radius.
    ///
    /// `context` must use the same top-left-origin, y-down coordinate system as
    /// `draw(in:context:color:)`.
    public static func drawDevBand(in rect: CGRect, context: CGContext) {
        let side = min(rect.width, rect.height)
        let bandRect = CGRect(
            x: rect.minX,
            y: rect.minY + (1 - devBandHeightRatio) * side,
            width: side,
            height: devBandHeightRatio * side
        )

        context.saveGState()
        context.setFillColor(devBandColor)
        context.fill(bandRect)

        let font = NSFont.boldSystemFont(ofSize: bandRect.height * devFontSizeRatio)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let string = NSAttributedString(string: "DEV", attributes: attributes)
        let textSize = string.size()
        let textRect = CGRect(
            x: bandRect.minX,
            y: bandRect.minY + (bandRect.height - textSize.height) / 2,
            width: bandRect.width,
            height: textSize.height
        )

        // AppKit text draws top-left-origin when the wrapping context is
        // flipped, matching the context's own y-down coordinate system.
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        string.draw(in: textRect)
        NSGraphicsContext.restoreGraphicsState()

        context.restoreGState()
    }
}
