import AppKit
import WebKit

/// `KNOCK_EVIDENCE_SNAPSHOT=<png path>` (HAIL-73 evidence hook, same style as
/// the other `KNOCK_EVIDENCE_*` ones): a few seconds after the review stage
/// shows, writes the app's own largest window to that path. It draws the
/// app's own view tree, so it needs no Screen Recording permission and can
/// never record another app. A live prototype's pixels come from the web
/// view's own snapshot (`cacheDisplay` leaves a `WKWebView` blank), drawn under
/// the AppKit layers (HAIL-84).
@MainActor
enum EvidenceWindowSnapshot {
    private static var scheduled = false

    static func scheduleIfRequested(delay: TimeInterval = 4) {
        let environment = ProcessInfo.processInfo.environment
        guard !scheduled,
              let path = environment["KNOCK_EVIDENCE_WINDOW_SHOT"] ?? environment["KNOCK_EVIDENCE_SNAPSHOT"]
        else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in await write(to: path) }
        }
        // `KNOCK_EVIDENCE_WINDOW_SHOT_2=<png>,<seconds from now>` (HAIL-114): a second shot of the
        // same window, after the harness sent a new revision to the open ask.
        if let second = environment["KNOCK_EVIDENCE_WINDOW_SHOT_2"] {
            let parts = second.split(separator: ",", maxSplits: 1).map(String.init)
            if parts.count == 2, let seconds = Double(parts[1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    Task { @MainActor in await write(to: parts[0]) }
                }
            }
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("evidence-shot: \(message)\n".utf8))
    }

    private static func write(to path: String) async {
        log("start")
        let window = NSApp.windows
            .filter { $0.isVisible && $0.contentView != nil }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        var pages: [(NSImage, NSRect)] = []
        for web in webViews(in: view) where !web.isHidden && web.bounds.width > 1 {
            let config = WKSnapshotConfiguration()
            let length = await withTimeout(seconds: 3) {
                try? await web.evaluateJavaScript("document.body ? document.body.innerText.length : -1") as? Int
            }
            log("web view \(web.bounds.size) loading=\(web.isLoading) text=\(String(describing: length))")
            // The first snapshot of a web view that was just resized can come back blank (seen on
            // the folded layouts); a second one after a pause is painted.
            _ = await withTimeout(seconds: 5) { try? await web.takeSnapshot(configuration: config) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let taken = await withTimeout(seconds: 5) { try? await web.takeSnapshot(configuration: config) }
            log("snapshot \(String(describing: taken??.size))")
            if let shot = taken ?? nil {
                pages.append((shot, view.convert(web.bounds, from: web)))
            }
        }
        guard let png = EvidenceComposite.png(content: view, cached: rep, pages: pages) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }
}

/// Draws a window's cached AppKit tree and the web views' own snapshots into
/// one PNG (HAIL-141c). The AppKit tree renders through `cacheDisplay` (which
/// paints a WKWebView's layer as an opaque dark rectangle), and each web view's
/// own snapshot is drawn over it. A snapshot's frame comes from
/// `convert(_:from:)` in the content view's own coordinates, which are top-down
/// when the view is flipped (SwiftUI's hosting view is); `unflipped` maps that
/// frame into the bottom-up drawing space the snapshot is drawn in.
@MainActor
enum EvidenceComposite {
    static func png(content: NSView, cached: NSBitmapImageRep, pages: [(NSImage, NSRect)]) -> Data? {
        let size = content.bounds.size
        let out = NSImage(size: size)
        out.lockFocus()
        let full = NSRect(origin: .zero, size: size)
        cached.draw(in: full, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        for (shot, frame) in pages {
            shot.draw(in: unflipped(frame, in: content), from: .zero, operation: .sourceOver, fraction: 1)
        }
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        restoreOverlays(in: rep, from: cached, pages: pages.map { unflipped($0.1, in: content) }, contentSize: size, flipped: content.isFlipped)
        return rep.representation(using: .png, properties: [:])
    }

    /// WAG-307: a web view's snapshot is drawn over the whole of its frame, so SwiftUI pins laid over
    /// the page vanish. The cached tree has the pins on a flat stand-in for the page. A pin is a small
    /// cluster of accent red pixels: each one is found, and its round footprint (number included) goes
    /// back on top of the snapshot.
    private static func restoreOverlays(
        in out: NSBitmapImageRep, from cached: NSBitmapImageRep, pages: [NSRect], contentSize: NSSize, flipped: Bool
    ) {
        guard cached.pixelsWide > 0, out.pixelsWide > 0, let src = cached.bitmapData,
              cached.samplesPerPixel >= 3, out.samplesPerPixel >= 3 else { return }
        let sx = Double(cached.pixelsWide) / contentSize.width, sy = Double(cached.pixelsHigh) / contentSize.height
        let ox = Double(out.pixelsWide) / contentSize.width, oy = Double(out.pixelsHigh) / contentSize.height
        func px(_ rep: NSBitmapImageRep, _ data: UnsafeMutablePointer<UInt8>, _ x: Int, _ y: Int) -> UnsafeMutablePointer<UInt8> {
            data + y * rep.bytesPerRow + x * rep.bitsPerPixel / 8
        }
        func isRed(_ p: UnsafeMutablePointer<UInt8>) -> Bool { Int(p[0]) > Int(p[1]) + 90 && Int(p[0]) > Int(p[2]) + 90 }
        var circles: [(x: Double, y: Double, r: Double)] = []
        for frame in pages {
            let top = contentSize.height - frame.maxY
            let x0 = Int(frame.minX * sx), x1 = min(cached.pixelsWide, Int(frame.maxX * sx))
            let y0 = Int(top * sy), y1 = min(cached.pixelsHigh, Int((top + frame.height) * sy))
            guard x1 > x0 + 4, y1 > y0 + 4 else { continue }
            let width = x1 - x0
            var seen = [Bool](repeating: false, count: width * (y1 - y0))
            for y in y0..<y1 {
                for x in x0..<x1 where !seen[(y - y0) * width + (x - x0)] && isRed(px(cached, src, x, y)) {
                    var stack = [(x, y)], minX = x, maxX = x, minY = y, maxY = y
                    seen[(y - y0) * width + (x - x0)] = true
                    while let (cx, cy) = stack.popLast() {
                        minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
                        for (nx, ny) in [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)]
                        where nx >= x0 && nx < x1 && ny >= y0 && ny < y1 && !seen[(ny - y0) * width + (nx - x0)] && isRed(px(cached, src, nx, ny)) {
                            seen[(ny - y0) * width + (nx - x0)] = true
                            stack.append((nx, ny))
                        }
                    }
                    let w = maxX - minX + 1, h = maxY - minY + 1
                    guard w >= 14, h >= 14, w <= 90, h <= 90 else { continue }
                    let cx = Double(minX + maxX) / 2, cy = Double(minY + maxY) / 2, r = Double(max(w, h)) / 2 + 1
                    circles.append((cx / sx, cy / sy, r / sx))
                }
            }
        }
        guard !circles.isEmpty, let context = NSGraphicsContext(bitmapImageRep: out) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for c in circles {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: NSRect(x: c.x - c.r, y: contentSize.height - c.y - c.r, width: c.r * 2, height: c.r * 2)).addClip()
            cached.draw(in: NSRect(origin: .zero, size: contentSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A frame in the content view's coordinates, as a rect in the bottom-up drawing space.
    static func unflipped(_ frame: NSRect, in content: NSView) -> NSRect {
        guard content.isFlipped else { return frame }
        return NSRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }
}
