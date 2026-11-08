import AppKit
import SwiftUI
import Testing

@testable import Knock

/// WAG-379: a click on an option row picks it at once, and the tooltip never holds the click back.
@MainActor
struct OptionRowPressTests {
    @Test func aPressPicksAnOpenRowOnly() {
        #expect(CalmOption.acceptsPick(isLocked: false, isLimitDimmed: false, isSelected: false))
        #expect(CalmOption.acceptsPick(isLocked: false, isLimitDimmed: false, isSelected: true))
        // A locked row does not react.
        #expect(!CalmOption.acceptsPick(isLocked: true, isLimitDimmed: false, isSelected: false))
        #expect(!CalmOption.acceptsPick(isLocked: true, isLimitDimmed: false, isSelected: true))
        // An unticked row at the limit does not react; a ticked one can still be unticked.
        #expect(!CalmOption.acceptsPick(isLocked: false, isLimitDimmed: true, isSelected: false))
        #expect(CalmOption.acceptsPick(isLocked: false, isLimitDimmed: true, isSelected: true))
    }

    @Test func theFocusOfAClickDoesNotOpenTheTooltip() {
        // No press: this is keyboard focus, and it opens the tooltip.
        #expect(!CalmOption.isPointerFocus(nil))
        // The focus a click gives comes a few milliseconds after the press.
        #expect(CalmOption.isPointerFocus(.milliseconds(12)))
        #expect(CalmOption.isPointerFocus(.milliseconds(399)))
        // A Tab key long after a click is keyboard focus again.
        #expect(!CalmOption.isPointerFocus(.milliseconds(400)))
        #expect(!CalmOption.isPointerFocus(.seconds(5)))
    }

    @Test func theTooltipPopoverNeverClosesOnAClickOutside() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = OptionTipPresenter<Text>.AnchorView(frame: NSRect(x: 20, y: 20, width: 300, height: 40))
        window.contentView?.addSubview(anchor)
        let coordinator = OptionTipPresenter<Text>.Coordinator()

        coordinator.update(isPresented: true, anchor: anchor, content: AnyView(Text("tip")))
        let popover = try #require(coordinator.popover)
        // `transient` would swallow the press that closes it: that was the click that did nothing.
        #expect(popover.behavior == .applicationDefined)

        coordinator.update(isPresented: false, anchor: anchor, content: nil)
        #expect(coordinator.popover == nil)
        #expect(!popover.isShown)
    }

    @Test func theAnchorLetsEveryClickThrough() {
        let anchor = OptionTipPresenter<Text>.AnchorView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        #expect(anchor.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test func theTooltipStillWaitsFor400msOfRest() {
        #expect(CalmOption.tooltipDelay == 0.4)
    }
}
