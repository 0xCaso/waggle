import AppKit

/// Draws a capture's saved comments onto a flattened copy of its image:
/// numbered boxes in `accent`, the same recipe `RegionBoxView`/`PinView` draw
/// on screen (docs/design/mvp-values.md §2.11, §2.12) - so the PNG a reply
/// sends the agent (docs/protocol-mvp.md `Capture.annotated_png_base64`)
/// looks like what the human saw.
///
/// Draws into an explicit `CGContext` bitmap, not `NSImage.lockFocus()`:
/// `lockFocus` ties its context to the window server, which this app's own
/// `swift test` process (no window, no run loop) does not reliably have -
/// `lockFocus`-drawn content silently failed to appear in the flattened
/// bitmap in that environment (verified against a plain hardcoded fill, not
/// specific to this renderer). A `CGContext` we allocate ourselves has no
/// such dependency.
enum AnnotatedCaptureRenderer {
    static func render(image: NSImage, comments: [Comment]) -> NSImage {
        let size = image.size
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }

        drawBase(image: image, in: context, size: CGSize(width: width, height: height))
        for comment in comments {
            draw(comment: comment, in: context, canvasSize: CGSize(width: width, height: height))
        }

        guard let cgImage = context.makeImage() else { return image }
        return NSImage(cgImage: cgImage, size: size)
    }

    /// `CGContext.draw(_:in:)` already draws a `CGImage` right side up in a
    /// bitmap context. Do not flip here: a flip sent every reply's capture to
    /// the agent upside down (operator report, 0.1.2).
    private static func drawBase(image: NSImage, in context: CGContext, size: CGSize) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
    }

    private static func draw(comment: Comment, in context: CGContext, canvasSize: CGSize) {
        let rect = pixelRect(for: comment.rect, in: canvasSize)

        let boxPath = CGPath(roundedRect: rect, cornerWidth: Theme.Radius.regionBox, cornerHeight: Theme.Radius.regionBox, transform: nil)
        context.addPath(boxPath)
        context.setFillColor(NSColor(Theme.Colors.accent.opacity(Theme.Alpha.regionCommitted)).cgColor)
        context.fillPath()
        context.addPath(boxPath)
        context.setStrokeColor(NSColor(Theme.Colors.accent).cgColor)
        context.setLineWidth(Theme.Stroke.regionBox.width)
        context.strokePath()

        // The pin's center sits at the region's top-left corner on screen
        // (`CommentCaptureStageView.commentOverlay`); after `pixelRect`'s
        // y-flip, that corner is this rect's top edge (`rect.maxY`).
        let diameter = Theme.Spacing.pinLarge
        let pinRect = CGRect(x: rect.minX - diameter / 2, y: rect.maxY - diameter / 2, width: diameter, height: diameter)
        context.setFillColor(NSColor(Theme.Colors.accent).cgColor)
        context.fillEllipse(in: pinRect)

        drawNumber(comment.n, centeredIn: pinRect, in: context)
    }

    private static func drawNumber(_ number: Int, centeredIn rect: CGRect, in context: CGContext) {
        let string = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor(Theme.Colors.onAccent),
        ]
        let textSize = string.size(withAttributes: attributes)
        let origin = CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        string.draw(at: origin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A normalized (0..1, top-left origin) `Rect` resolved to pixel space in
    /// `canvasSize`, then flipped to `CGContext`'s bottom-left origin - the
    /// one coordinate conversion this renderer needs beyond
    /// `CommentCaptureStageView.pointRect(for:in:)`, which targets an
    /// (already top-left) SwiftUI frame instead of a CG canvas.
    static func pixelRect(for rect: Rect, in canvasSize: CGSize) -> CGRect {
        let x = rect.x * canvasSize.width
        let w = rect.w * canvasSize.width
        let h = rect.h * canvasSize.height
        let topY = rect.y * canvasSize.height
        let y = canvasSize.height - topY - h
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

extension NSImage {
    /// Encodes this image as PNG bytes (docs/protocol-mvp.md `Capture`:
    /// `png_base64`/`annotated_png_base64`). `nil` only if AppKit's own PNG
    /// encoder fails, e.g. a zero-size image.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Encodes a capture for `reply.submit` (docs/protocol-mvp.md `Capture`):
    /// JPEG, scaled down so its long edge is at most `maxLongEdge` pixels.
    /// The agent's vision model gains nothing from more pixels than that,
    /// and a photographic slide as PNG is several megabytes. Comment rects
    /// are fractions of the image, so scaling keeps them in place. The
    /// daemon tells JPEG from an older reply's PNG by its first bytes.
    /// `nil` only when the image has no bitmap to draw, e.g. zero size.
    func captureWireData(maxLongEdge: CGFloat = 2048, quality: CGFloat = 0.85) -> Data? {
        guard let source = cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0
        else { return nil }
        let scale = min(1, maxLongEdge / CGFloat(max(source.width, source.height)))
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // JPEG has no alpha: a transparent pixel would turn black, so lay the
        // capture on white first.
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(NSColor(Theme.Colors.win).cgColor)
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(source, in: bounds)
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
