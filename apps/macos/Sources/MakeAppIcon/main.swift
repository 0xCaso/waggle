import AppKit
import CoreGraphics
import Foundation
import KnockMark

/// Renders every PNG a macOS `.iconset` needs for the Cell W app icon,
/// through the single `KnockMark` geometry source (contract: HAIL-23).
/// `iconutil -c icns` turns the output directory into `AppIcon.icns`; see
/// `scripts/make-app-icon.sh`.
///
/// Usage: make-app-icon <output .iconset directory> [--dev]

/// Base point sizes an `.iconset` needs; each is rendered at 1x and 2x.
private let pointSizes = [16, 32, 128, 256, 512]
private let scales = [1, 2]

/// HAIL-171, board "APP ICON": a honey gradient rounded square (top #F9C846,
/// bottom #E89A0C), a white cell, a honey w. Mirrors `Resources/AppIcon.svg`.
private let markColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
private let wColor = CGColor(srgbRed: 0xE8 / 255.0, green: 0x9A / 255.0, blue: 0x0C / 255.0, alpha: 1)
private let cornerRadiusRatio: CGFloat = 58.0 / 256.0
private let markBoxRatio: CGFloat = 148.0 / 256.0

private func renderPNG(pixelSize: Int, dev: Bool) -> Data {
    let side = CGFloat(pixelSize)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!  // exact honey in the sRGB-tagged PNG
    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("could not create a \(pixelSize)x\(pixelSize) bitmap context")
    }

    // CGBitmapContext defaults to a bottom-left origin, y-up; flip it so
    // KnockMark.draw's top-left, y-down contract holds.
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)

    let iconRect = CGRect(x: 0, y: 0, width: side, height: side)
    let iconPath = CGPath(
        roundedRect: iconRect,
        cornerWidth: cornerRadiusRatio * side,
        cornerHeight: cornerRadiusRatio * side,
        transform: nil
    )

    context.saveGState()
    context.addPath(iconPath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [KnockMark.honeyTop, KnockMark.honeyBottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: CGPoint(x: side / 2, y: 0), end: CGPoint(x: side / 2, y: side), options: [])
    context.restoreGState()

    let markSide = markBoxRatio * side
    let markOrigin = (side - markSide) / 2
    let markRect = CGRect(x: markOrigin, y: markOrigin, width: markSide, height: markSide)
    KnockMark.draw(in: markRect, context: context, fill: .solid(markColor), wColor: wColor)

    // The DEV band sits on top of the mark, clipped to the rounded icon so the
    // strip's bottom corners follow the radius (HAIL-26).
    if dev {
        context.saveGState()
        context.addPath(iconPath)
        context.clip()
        KnockMark.drawDevBand(in: iconRect, context: context)
        context.restoreGState()
    }

    guard let image = context.makeImage() else {
        fatalError("could not rasterize the \(pixelSize)x\(pixelSize) icon")
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode the \(pixelSize)x\(pixelSize) icon as PNG")
    }
    return png
}

let arguments = CommandLine.arguments
guard arguments.count >= 2, arguments.count <= 3 else {
    FileHandle.standardError.write(Data("usage: make-app-icon <output .iconset directory> [--dev]\n".utf8))
    exit(1)
}
let outputDir = arguments[1]
let dev = arguments.count == 3 && arguments[2] == "--dev"
try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for pointSize in pointSizes {
    for scale in scales {
        let suffix = scale == 1 ? "" : "@\(scale)x"
        let filename = "icon_\(pointSize)x\(pointSize)\(suffix).png"
        let data = renderPNG(pixelSize: pointSize * scale, dev: dev)
        let path = (outputDir as NSString).appendingPathComponent(filename)
        try data.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}
