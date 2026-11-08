import Testing
import Foundation
import AppKit
@testable import Knock

/// HAIL-158: the diagram and prototype pinch route runs on fake input, like the screenshot one.
@MainActor
struct PrototypePinchRouteTests {
    @MainActor
    private final class Rig {
        var logs: [String] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let view = NSView(frame: NSRect(x: 50, y: 40, width: 200, height: 100))
        let model = PrototypeZoomModel()
        init() {
            window.contentView?.addSubview(view)
            PrototypePinchMonitor.log = { [weak self] in self?.logs.append($0) }
        }
    }

    @Test func aPinchInsideScalesTheModelAndLogsIt() {
        let rig = Rig()
        let route = PrototypePinchMonitor.route(PinchInput(factor: 1.5, windowPoint: CGPoint(x: 100, y: 100), window: rig.window), in: rig.view, model: rig.model)
        #expect(route == .handled)
        #expect(abs(rig.model.storedScale - 1.5) < 0.001)
        #expect(rig.logs.last?.contains("received") == true)
    }

    @Test func smartZoomToggles100And200() {
        let rig = Rig()
        let input = PinchInput(kind: .smart, factor: 1, windowPoint: CGPoint(x: 100, y: 100), window: rig.window)
        PrototypePinchMonitor.route(input, in: rig.view, model: rig.model)
        #expect(rig.model.storedScale == 2)
        PrototypePinchMonitor.route(input, in: rig.view, model: rig.model)
        #expect(rig.model.storedScale == 1)
    }

    @Test func earlyReturnsAreNamedAndLogged() {
        let rig = Rig()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(PrototypePinchMonitor.route(PinchInput(factor: 1.1, windowPoint: CGPoint(x: 100, y: 100), window: other), in: rig.view, model: rig.model) == .otherWindow)
        #expect(PrototypePinchMonitor.route(PinchInput(factor: 1.1, windowPoint: CGPoint(x: 5, y: 5), window: rig.window), in: rig.view, model: rig.model) == .outsideStage)
        #expect(PrototypePinchMonitor.route(PinchInput(factor: 1.1, windowPoint: CGPoint(x: 100, y: 100), window: rig.window), in: nil, model: rig.model) == .noViewport)
        #expect(rig.model.storedScale == 1)
        #expect(rig.logs.count == 3)
    }

    @Test func diagramPagesKeepTheSvgAtItsNaturalSize() throws {
        for format in [DiagramFormat.mermaid, .svg] {
            let html = DiagramPage.wrapperHTML(source: format == .svg ? "<svg viewBox=\"0 0 10 10\" width=\"10\" height=\"10\"></svg>" : "flowchart TD\n A-->B", format: format)
            #expect(html.contains("#diagram svg { flex: none; max-width: none;"))
        }
    }
}
