import CoreGraphics
import Foundation

/// The live page's scroll offset and viewport size, in CSS px at the page zoom
/// they were read at (`zoom`, the web view's `pageZoom`): one CSS px is `zoom`
/// points on screen. Recorded on a capture when its first comment is placed,
/// and read from the page while pins are on screen (HAIL-75).
///
/// `anchorX`/`anchorY` is where the page's content anchor sits in page
/// coordinates: a diagram's SVG, which its page centres, so the SVG moves when
/// a zoom changes the layout width. Zero on any other page.
struct PageViewport: Equatable, Sendable {
    var scrollX: Double
    var scrollY: Double
    var width: Double
    var height: Double
    var zoom: Double = 1
    var anchorX: Double = 0
    var anchorY: Double = 0

    var scroll: CGPoint { CGPoint(x: scrollX, y: scrollY) }
    var size: CGSize { CGSize(width: width, height: height) }
    var anchor: CGPoint { CGPoint(x: anchorX, y: anchorY) }

    /// Same page position, size and zoom, within a point (sub-point scroll noise).
    func matches(_ other: PageViewport) -> Bool {
        abs(scrollX - other.scrollX) < 1 && abs(scrollY - other.scrollY) < 1
            && abs(width - other.width) < 1 && abs(height - other.height) < 1
            && abs(zoom - other.zoom) < 0.001
    }

    /// The read-only script behind `WebViewCaptureController.readPageViewport`:
    /// scroll, viewport size and the content anchor, all in CSS px.
    static let readScript = "(function(){var s=document.querySelector('#diagram svg');var r=s?s.getBoundingClientRect():null;return [window.scrollX,window.scrollY,window.innerWidth,window.innerHeight,r?r.left+window.scrollX:0,r?r.top+window.scrollY:0];})()"

    /// Builds a reading from `readScript`'s result and the zoom it was read at.
    /// With the web view's size in points, the viewport is that size over the
    /// zoom: `innerWidth`/`innerHeight` are whole CSS px, and at 400% their
    /// rounding moved a pin by 2 pt.
    static func make(values: [Double], zoom: Double, viewSize: CGSize? = nil) -> PageViewport? {
        guard values.count >= 4 else { return nil }
        var width = values[2], height = values[3]
        if let viewSize, viewSize.width > 0, viewSize.height > 0, zoom > 0 {
            width = viewSize.width / zoom
            height = viewSize.height / zoom
        }
        return PageViewport(
            scrollX: values[0], scrollY: values[1], width: width, height: height, zoom: zoom,
            anchorX: values.count >= 6 ? values[4] : 0, anchorY: values.count >= 6 ? values[5] : 0
        )
    }
}

/// Which view of a prototype a comment was made on (HAIL-103): the page's
/// `location.hash` (without the `#`) and a fingerprint of its visible text.
/// Read through the capture controller's read-only JS, never from the page.
struct PageView: Equatable, Sendable {
    var hash: String
    var fingerprint: String

    /// Only this much visible text is hashed, so a huge page stays cheap.
    static let textCap = 20_000

    /// Fingerprint of the document's visible text: whitespace collapsed,
    /// trimmed, capped, then hashed with FNV-1a 64 (stable across launches,
    /// unlike `Hashable`). Empty text gives an empty fingerprint (unknown).
    static func fingerprint(ofText text: String) -> String {
        let words = text.prefix(textCap * 4).split(whereSeparator: { $0.isWhitespace })
        let normalised = String(words.joined(separator: " ").prefix(textCap))
        guard !normalised.isEmpty else { return "" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalised.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    static func make(hash: String, text: String) -> PageView {
        PageView(hash: hash.hasPrefix("#") ? String(hash.dropFirst()) : hash, fingerprint: fingerprint(ofText: text))
    }

    /// Whether a comment made on `comment` shows while the page is on
    /// `current`: the same hash when the comment has one, otherwise the same
    /// fingerprint. A comment with no recorded view (made before HAIL-103) and
    /// an unread current view both show, as before.
    static func shows(comment: PageView?, current: PageView?) -> Bool {
        guard let comment, let current else { return true }
        if !comment.hash.isEmpty { return comment.hash == current.hash }
        if comment.fingerprint.isEmpty { return true }
        return comment.fingerprint == current.fingerprint
    }
}

/// Pure geometry for pins on the live page (HAIL-75). A comment's `Rect` is
/// 0...1 of the viewport its capture froze; page space is that viewport's
/// origin plus its scroll offset, in CSS px, so the pin stays on the spot it
/// marked while the page scrolls. The layer over the page is in points, and one
/// CSS px is the page zoom in points, so pins also follow the page at any zoom.
/// A new comment's `Rect` is 0...1 of the layer, which is also 0...1 of the
/// viewport snapshot taken with it, whatever the zoom.
enum CommentPageMapping {
    /// The comment's rect in page coordinates. A capture without a recorded
    /// viewport (a restored reply) reads as taken at the top of the page in
    /// the current viewport size.
    static func pageRect(for rect: Rect, capture: PageViewport?, fallbackSize: CGSize) -> CGRect {
        let scroll = capture?.scroll ?? .zero
        let size = capture?.size ?? fallbackSize
        return CGRect(
            x: scroll.x + rect.x * size.width, y: scroll.y + rect.y * size.height,
            width: rect.w * size.width, height: rect.h * size.height
        )
    }

    /// The comment's rect in the page as it is laid out now: `pageRect`, moved
    /// by as much as the content anchor moved since the capture (a centred
    /// diagram shifts when the zoom changes the layout width). A capture with
    /// no recorded viewport falls back to the current viewport size.
    static func currentPageRect(for rect: Rect, capture: PageViewport?, current: PageViewport?, layerSize: CGSize) -> CGRect {
        let page = pageRect(for: rect, capture: capture, fallbackSize: current?.size ?? layerSize)
        guard let capture, let current else { return page }
        return page.offsetBy(dx: current.anchorX - capture.anchorX, dy: current.anchorY - capture.anchorY)
    }

    /// Where a page-space rect sits inside the layer over the page right now:
    /// its offset from the scroll position, times the page zoom.
    static func layerRect(forPageRect page: CGRect, scroll: CGPoint, scale: CGFloat = 1) -> CGRect {
        CGRect(
            x: (page.minX - scroll.x) * scale, y: (page.minY - scroll.y) * scale,
            width: page.width * scale, height: page.height * scale
        )
    }

    /// Where a comment's rect sits in the layer right now. Without a current
    /// reading the page counts as at the top, at 100%.
    static func layerRect(for rect: Rect, capture: PageViewport?, current: PageViewport?, layerSize: CGSize) -> CGRect {
        let page = currentPageRect(for: rect, capture: capture, current: current, layerSize: layerSize)
        return layerRect(forPageRect: page, scroll: current?.scroll ?? .zero, scale: CGFloat(current?.zoom ?? 1))
    }

    /// The pin (top-left corner) is drawn only when it is inside the layer;
    /// an off-screen pin is not drawn (HAIL-75 choice: no edge markers).
    static func pinIsVisible(_ layerRect: CGRect, in size: CGSize) -> Bool {
        CGRect(origin: .zero, size: size).contains(layerRect.origin)
    }

    /// The region box is drawn (clipped) whenever any part is on screen.
    static func regionIsVisible(_ layerRect: CGRect, in size: CGSize) -> Bool {
        CGRect(origin: .zero, size: size).intersects(layerRect)
    }

    /// The scroll offset that brings a page-space rect into view, or `nil`
    /// when its pin and box are already fully visible. Vertical placement
    /// puts the top of the box a quarter of the viewport down.
    static func scrollTarget(forPageRect page: CGRect, scroll: CGPoint, viewport: CGSize) -> CGPoint? {
        let margin: CGFloat = 12
        let visible = CGRect(origin: scroll, size: viewport).insetBy(dx: margin, dy: margin)
        if visible.contains(page) || (page.height > visible.height && visible.contains(page.origin)) { return nil }
        var target = scroll
        if page.minX < visible.minX || page.minX > visible.maxX - min(page.width, visible.width) {
            target.x = max(0, page.minX - viewport.width / 4)
        }
        target.y = max(0, page.minY - viewport.height / 4)
        return target
    }

    /// The comment whose pin circle is under `point` (layer coordinates), the
    /// newest first. `layerRects` maps a comment id to its rect in the layer.
    static func pinHit(at point: CGPoint, comments: [Comment], layerRects: [String: CGRect], size: CGSize) -> Comment? {
        let radius = Theme.Spacing.pinLarge / 2 + 4
        for comment in comments.reversed() {
            guard let rect = layerRects[comment.id], pinIsVisible(rect, in: size) else { continue }
            if hypot(point.x - rect.minX, point.y - rect.minY) <= radius { return comment }
        }
        return nil
    }
}
