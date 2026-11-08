import Testing
import Foundation
import AppKit
@testable import Knock

/// HAIL-155: the pinch route is driven with fake input, so a unit test covers
/// what a real magnify event does.
@MainActor
struct PinchZoomRouteTests {
    @MainActor
    private final class Rig {
        var pinches: [(CGFloat, CGPoint, Bool)] = []
        var smart: [CGPoint] = []
        var logs: [String] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let view = NSView(frame: NSRect(x: 50, y: 40, width: 200, height: 100))
        var monitor: PinchZoomMonitor!

        init() {
            window.contentView?.addSubview(view)
            monitor = PinchZoomMonitor(
                handle: ScrollViewHandle(),
                onPinch: { [weak self] in self?.pinches.append(($0, $1, $2)) },
                onSmartZoom: { [weak self] in self?.smart.append($0) }
            )
            PinchZoomMonitor.log = { [weak self] in self?.logs.append($0) }
        }
    }

    @Test func aPinchInsideTheStageReachesTheHandlerWithAViewportPoint() {
        let rig = Rig()
        let route = rig.monitor.route(PinchInput(factor: 1.1, windowPoint: CGPoint(x: 60, y: 130), window: rig.window, ended: true), in: rig.view)
        #expect(route == .handled)
        #expect(rig.pinches.count == 1)
        #expect(rig.pinches[0].0 == 1.1 && rig.pinches[0].2)
        // The view's bottom-left is (50, 40), so (60, 140) is 10 right of the left and 90 up: 10 from the top, in a top-left origin.
        #expect(rig.pinches[0].1 == CGPoint(x: 10, y: 10))
        #expect(rig.logs.contains { $0.hasPrefix("pinch received") })
    }

    @Test func aSmartMagnifyReachesTheSmartHandler() {
        let rig = Rig()
        let route = rig.monitor.route(PinchInput(kind: .smart, factor: 1, windowPoint: CGPoint(x: 100, y: 80), window: rig.window), in: rig.view)
        #expect(route == .handled)
        #expect(rig.smart == [CGPoint(x: 50, y: 60)])
    }

    @Test func earlyReturnsSayWhy() {
        let rig = Rig()
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        #expect(rig.monitor.route(PinchInput(factor: 1.1, windowPoint: CGPoint(x: 60, y: 60), window: other), in: rig.view) == .otherWindow)
        #expect(rig.monitor.route(PinchInput(factor: 1.1, windowPoint: CGPoint(x: 5, y: 5), window: rig.window), in: rig.view) == .outsideStage)
        #expect(rig.monitor.route(PinchInput(factor: 1.1, windowPoint: CGPoint(x: 60, y: 60), window: rig.window), in: nil) == .noViewport)
        #expect(rig.pinches.isEmpty)
        #expect(rig.logs.count == 3 && rig.logs.allSatisfy { $0.contains("ignored") })
    }

    @Test func pinchingTheModelZoomsAroundThePointer() {
        let model = ScreenshotStageModel()
        model.updateViewport(container: CGSize(width: 800, height: 600), image: CGSize(width: 1600, height: 1200))
        let anchor = ScreenshotViewport.Anchor(fraction: CGPoint(x: 0.5, y: 0.5), viewport: CGPoint(x: 400, y: 300))
        model.pinch(by: 1.5, anchor: anchor)
        #expect(model.zoom != .fit)
        #expect(abs(model.scale - 0.75) < 0.001)
        #expect(model.percentText == "75%")
        model.pinch(by: 1 / 1.5, anchor: anchor)
        #expect(model.zoom == .fit)
        model.userSmartZoom(anchor: anchor)
        #expect(model.zoom == .scale(1))
        model.userSmartZoom(anchor: anchor)
        #expect(model.zoom == .fit)
    }

    @Test func scrollViewIsResolvedFromTheProbeWhenItJoinsAWindowLate() {
        let handle = ScrollViewHandle()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = content
        let probe = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        content.addSubview(probe)
        handle.probe = probe
        #expect(handle.scrollView == nil, "not in a window yet")
        window.contentView?.addSubview(scroll)
        #expect(handle.scrollView === scroll)
    }

    @Test func evidenceSpecParses() {
        #expect(PinchEvidence.parse("2,0.25,0.75") == [.init(factor: 2, x: 0.25, y: 0.75, repeats: 1)])
        #expect(PinchEvidence.parse("1.04,0.5,0.5,20;0.9") == [
            .init(factor: 1.04, x: 0.5, y: 0.5, repeats: 20), .init(factor: 0.9, x: 0.5, y: 0.5, repeats: 1),
        ])
        #expect(PinchEvidence.parse(nil).isEmpty)
        #expect(PinchEvidence.parse("x").isEmpty)
    }
}
