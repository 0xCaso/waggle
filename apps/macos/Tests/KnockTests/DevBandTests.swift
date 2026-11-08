import XCTest
import CoreGraphics
import KnockMark

/// Verifies the "DEV" band (HAIL-26): a dark strip across the bottom quarter
/// with a white "DEV" label centred in it, drawn through the single KnockMark
/// geometry source the icon script uses.
final class DevBandTests: XCTestCase {
    func testDevBandDrawsDarkStripAndWhiteLabel() throws {
        let side = 256
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return XCTFail("could not create the bitmap context")
        }

        // Flip to KnockMark's top-left-origin, y-down contract.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)

        let rect = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
        // A white background makes the dark band and the white label detectable.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)

        KnockMark.drawDevBand(in: rect, context: context)

        let data = context.data!.bindMemory(to: UInt8.self, capacity: side * context.bytesPerRow)
        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let offset = y * context.bytesPerRow + x * 4
            return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
        }

        // The flipped context maps drawing coordinates onto the bitmap's memory
        // rows directly (row 0 = top). The band is the bottom quarter, so it is
        // rows (side*3/4)..<side; the top three quarters are rows 0..<(side*3/4).
        let topPixel = rgb(16, 16)
        XCTAssertGreaterThan(topPixel.r, 240)
        XCTAssertGreaterThan(topPixel.g, 240)
        XCTAssertGreaterThan(topPixel.b, 240)

        let bandPixel = rgb(16, 224)
        XCTAssertLessThan(bandPixel.r, 60)
        XCTAssertLessThan(bandPixel.g, 60)
        XCTAssertLessThan(bandPixel.b, 60)

        // The white "DEV" label puts white pixels inside the dark band, but the
        // band is not solid white.
        var whiteInBand = 0
        for y in (side * 3 / 4)..<side {
            for x in 0..<side {
                let p = rgb(x, y)
                if p.r > 200 && p.g > 200 && p.b > 200 { whiteInBand += 1 }
            }
        }
        XCTAssertGreaterThan(whiteInBand, 0)
        XCTAssertLessThan(whiteInBand, side * side / 8)
    }
}
