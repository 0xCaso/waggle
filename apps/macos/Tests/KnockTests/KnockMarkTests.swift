import AppKit
import CoreGraphics
import Foundation
import KnockMark
import Testing

/// Guards the single geometry source behind the app icon, the menu-bar glyph and
/// the in-app lockup mark (HAIL-171, Waggle Cell W).
struct KnockMarkTests {
    private static let appDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func numbers(in svg: String, pathContaining marker: String) -> [Double]? {
        guard let line = svg.split(separator: "\n").first(where: { $0.contains(marker) }),
              let start = line.range(of: "d=\"")
        else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let body = rest[..<end].replacingOccurrences(of: "[MLZ]", with: " ", options: .regularExpression)
        return body.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
    }

    @Test func geometryMatchesTheCommittedIconSVG() throws {
        let svg = try String(contentsOf: Self.appDir.appendingPathComponent("Resources/AppIcon.svg"), encoding: .utf8)
        let cell = try #require(Self.numbers(in: svg, pathContaining: "fill=\"#fff\""))
        #expect(cell == KnockMark.cellPoints.flatMap { [Double($0.x), Double($0.y)] })
        let w = try #require(Self.numbers(in: svg, pathContaining: "stroke-width"))
        #expect(w == KnockMark.wPoints.flatMap { [Double($0.x), Double($0.y)] })
        #expect(svg.contains("stroke-width=\"10\""))
    }

    @Test func iconFilesAreValidIcns() throws {
        for name in ["AppIcon.icns", "AppIcon-dev.icns"] {
            let data = try Data(contentsOf: Self.appDir.appendingPathComponent("Resources/\(name)"))
            #expect(data.prefix(4) == Data("icns".utf8), "\(name) is not an icns file")
            #expect(data.count > 10_000)
        }
        for name in ["AppIcon.svg", "AppIcon-dev.svg"] {
            #expect(FileManager.default.fileExists(atPath: Self.appDir.appendingPathComponent("Resources/\(name)").path))
        }
    }

    private func render(_ draw: (CGContext, CGRect) -> Void) throws -> NSBitmapImageRep {
        let side = 100
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        draw(context, CGRect(x: 0, y: 0, width: side, height: side))
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }

    @Test func glyphFillsTheCellAndKnocksOutTheW() throws {
        let rep = try render { ctx, rect in
            KnockMark.draw(in: rect, context: ctx, color: CGColor(gray: 0, alpha: 1))
        }
        // Inside the cell, off the w.
        #expect(try #require(rep.colorAt(x: 50, y: 20)).alphaComponent > 0.9)
        // On the w's middle peak (50, 43).
        #expect(try #require(rep.colorAt(x: 50, y: 43)).alphaComponent < 0.1)
        // Outside the hexagon's corner.
        #expect(try #require(rep.colorAt(x: 3, y: 3)).alphaComponent < 0.1)
    }

    @Test func colourCellRunsHoneyTopToBottomWithAWhiteW() throws {
        let rep = try render { ctx, rect in
            KnockMark.draw(in: rect, context: ctx, fill: .honeyGradient, wColor: CGColor(gray: 1, alpha: 1))
        }
        let top = try #require(rep.colorAt(x: 50, y: 6)).usingColorSpace(.sRGB)!
        let bottom = try #require(rep.colorAt(x: 50, y: 94)).usingColorSpace(.sRGB)!
        #expect(top.redComponent > 0.95 && top.greenComponent > 0.75)
        #expect(bottom.greenComponent < top.greenComponent)
        let w = try #require(rep.colorAt(x: 50, y: 43)).usingColorSpace(.sRGB)!
        #expect(w.greenComponent > 0.95 && w.blueComponent > 0.95)
    }
}
