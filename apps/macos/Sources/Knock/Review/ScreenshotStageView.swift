import SwiftUI
import AppKit

/// Owns the `NSScrollView` a screenshot artifact renders in, so the fit-to-
/// width and zoom-in/out actions the story asks for (pinch, plus keyboard)
/// have somewhere to live outside the view struct's per-update lifecycle.
@MainActor
final class ScreenshotZoomController: ObservableObject {
    fileprivate weak var scrollView: NSScrollView?
    fileprivate var imageSize: CGSize = .zero

    func fitToWidth() {
        guard let scrollView, imageSize.width > 0, scrollView.bounds.width > 0 else { return }
        scrollView.magnification = max(scrollView.bounds.width / imageSize.width, scrollView.minMagnification)
    }

    func zoomIn() { zoom(by: 1.25) }
    func zoomOut() { zoom(by: 0.8) }

    private func zoom(by factor: CGFloat) {
        guard let scrollView else { return }
        let target = (scrollView.magnification * factor)
            .clamped(to: scrollView.minMagnification...scrollView.maxMagnification)
        scrollView.animator().setMagnification(target, centeredAt: .zero)
    }
}

/// A screenshot artifact, fit to width with pinch and ⌘+/⌘- zoom (story
/// AC: "Screenshot artifacts render fit-to-width with zoom").
struct ScreenshotStageView: View {
    let image: NSImage
    @ObservedObject var controller: ScreenshotZoomController

    var body: some View {
        ZoomableImageView(image: image, controller: controller)
            .imageContextMenu(image)
            .background(
                HStack {
                    Button("Zoom in") { controller.zoomIn() }
                        .keyboardShortcut("+", modifiers: .command)
                    Button("Zoom out") { controller.zoomOut() }
                        .keyboardShortcut("-", modifiers: .command)
                }
                .opacity(0)
            )
    }
}

private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let controller: ScreenshotZoomController

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = false

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        scrollView.documentView = imageView

        controller.scrollView = scrollView
        controller.imageSize = image.size
        DispatchQueue.main.async { controller.fitToWidth() }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
