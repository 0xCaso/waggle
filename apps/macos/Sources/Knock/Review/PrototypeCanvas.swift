import CoreGraphics

/// HAIL-131: the pure maths of the prototype canvas. Zoom keeps the page point
/// under the pointer where it is, scroll never leaves the page, and Fit frames
/// the page's width. Lengths are CSS pixels for the page and view points for
/// the viewport, so a viewport of `v` points shows `v / scale` CSS pixels.
enum PrototypeCanvas {
    /// The scroll offset (CSS px) after a zoom from `oldScale` to `newScale` that
    /// keeps the page point under `pointer` (view points, top-left based) fixed.
    static func scrollOrigin(
        keeping pointer: CGPoint, scroll: CGPoint, from oldScale: CGFloat, to newScale: CGFloat
    ) -> CGPoint {
        guard oldScale > 0, newScale > 0 else { return scroll }
        return CGPoint(
            x: scroll.x + pointer.x / oldScale - pointer.x / newScale,
            y: scroll.y + pointer.y / oldScale - pointer.y / newScale
        )
    }

    /// `scroll` held inside the page: never negative, never past the page's far
    /// edge. A page smaller than the viewport stays at 0.
    static func clamped(scroll: CGPoint, page: CGSize, viewport: CGSize, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return .zero }
        let maxX = max(0, page.width - viewport.width / scale)
        let maxY = max(0, page.height - viewport.height / scale)
        return CGPoint(x: min(max(scroll.x, 0), maxX), y: min(max(scroll.y, 0), maxY))
    }

    /// The scroll offset after dragging the canvas by `translation` view points.
    static func panned(scroll: CGPoint, by translation: CGSize, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return scroll }
        return CGPoint(x: scroll.x - translation.width / scale, y: scroll.y - translation.height / scale)
    }

    /// Fit: the whole page width in view. A page that is not wider than the view
    /// stays at 100%; a wider one shrinks to the view's width.
    static func fitScale(viewportWidth: CGFloat, pageWidth: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard viewportWidth > 0, pageWidth > 0 else { return 1 }
        return min(max(min(1, viewportWidth / pageWidth), minimum), maximum)
    }

    /// Fit for a diagram (HAIL-141): the diagram's natural width in view. Unlike
    /// `fitScale`, a diagram narrower than the view grows to fill it, so the
    /// same maths scales a small SVG up and a wide one down.
    static func fitScaleUpscaling(viewportWidth: CGFloat, pageWidth: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard viewportWidth > 0, pageWidth > 0 else { return 1 }
        return min(max(viewportWidth / pageWidth, minimum), maximum)
    }
}
