import Testing
import AppKit
@testable import Knock

/// The annotated capture render (docs/protocol-mvp.md `Capture.annotated_
/// png_base64`, docs/design/mvp-values.md §2.11/§2.12 "numbered boxes"):
/// pure geometry first, then that the flattened output is a same-size,
/// still-valid image distinguishable from the untouched source.
@MainActor
struct AnnotatedCaptureRendererTests {
    @Test func pixelRectFlipsTopLeftOriginToAppKitsBottomLeftOrigin() {
        let canvas = CGSize(width: 200, height: 100)
        let rect = Rect(x: 0.1, y: 0.2, w: 0.5, h: 0.1)

        let pixelRect = AnnotatedCaptureRenderer.pixelRect(for: rect, in: canvas)

        // x/width scale directly; y flips (top-origin 0.2*100=20 down from
        // the top becomes 100-20-10=70 up from the bottom).
        #expect(pixelRect == CGRect(x: 20, y: 70, width: 100, height: 10))
    }

    @Test func pixelRectAtTheTopEdgeLandsAtTheCanvassTop() {
        let canvas = CGSize(width: 100, height: 100)
        let rect = Rect(x: 0, y: 0, w: 0.2, h: 0.2)

        let pixelRect = AnnotatedCaptureRenderer.pixelRect(for: rect, in: canvas)

        #expect(pixelRect.maxY == 100, "a region pinned to the visual top should end at the AppKit canvas's top (max y)")
    }

    @Test func renderKeepsTheSourceImagesPixelSize() {
        let image = Self.solidImage(size: NSSize(width: 64, height: 48), color: .white)
        let comments = [Comment(id: "c1", captureId: "cap1", n: 1, rect: Rect(x: 0.1, y: 0.1, w: 0.3, h: 0.2), text: "note")]

        let annotated = AnnotatedCaptureRenderer.render(image: image, comments: comments)

        #expect(annotated.size == image.size)
    }

    @Test func renderWithNoCommentsLeavesTheImageUnchanged() {
        let image = Self.solidImage(size: NSSize(width: 32, height: 32), color: .white)

        let annotated = AnnotatedCaptureRenderer.render(image: image, comments: [])

        #expect(annotated.pngData() != nil)
        #expect(annotated.size == image.size)
    }

    @Test func renderStrokesTheRegionsEdgeKnockColoured() {
        let image = Self.solidImage(size: NSSize(width: 100, height: 100), color: .white)
        // A region comfortably inside the canvas, away from the rounded
        // corners and the pin, so its left edge is a plain straight stroke.
        let comments = [Comment(id: "c1", captureId: "cap1", n: 1, rect: Rect(x: 0.3, y: 0.3, w: 0.4, h: 0.4), text: "note")]

        let annotated = AnnotatedCaptureRenderer.render(image: image, comments: comments)

        guard let bitmap = Self.bitmap(of: annotated) else {
            Issue.record("could not read back the rendered image")
            return
        }
        // The full-opacity 1.5pt stroke sits right on the box's left edge
        // (pixel x≈30, per `pixelRect`); scan a few pixels around it so
        // anti-aliasing/rounding can't make the assertion flaky.
        let sawAccentStroke = (27...33).contains { x in
            guard let color = bitmap.colorAt(x: x, y: 50) else { return false }
            return color.blueComponent < 0.5 && color.redComponent > color.blueComponent
        }
        #expect(sawAccentStroke, "expected an accent-tinted (low-blue, red>blue) pixel near the region's stroked edge")
    }

    @Test func renderKeepsTheImageRightSideUp() {
        // Top half red, bottom half blue, drawn in CG coordinates (y up).
        let width = 40, height = 40
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
        let source = Self.bitmap(of: image)!.colorAt(x: 20, y: 5)!

        let annotated = AnnotatedCaptureRenderer.render(image: image, comments: [])

        let top = Self.bitmap(of: annotated)!.colorAt(x: 20, y: 5)!
        #expect(source.redComponent > 0.5, "sanity: the source's visual top is red")
        #expect(top.redComponent > 0.5 && top.blueComponent < 0.5, "the rendered capture's visual top must still be red, not flipped")
    }

    /// Built via a raw `CGContext`, not `NSImage.lockFocus()`: `lockFocus`
    /// ties its context to the window server, which is not reliably present
    /// in a `swift test` process (see `AnnotatedCaptureRenderer`'s own note)
    /// - a `lockFocus`-filled image read back as blank white here even
    /// though the fill call ran, silently failing every test that assumed
    /// it worked.
    private static func solidImage(size: NSSize, color: NSColor) -> NSImage {
        let width = Int(size.width), height = Int(size.height)
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        return NSImage(cgImage: context.makeImage()!, size: size)
    }

    private static func bitmap(of image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }
}
