import Testing
@testable import Knock

@Suite struct PointerCursorTests {
    @Test func pushesOnceThenPopsOnLeave() {
        var t = PointerCursorTracker()
        #expect(t.hoverChanged(inside: true, enabled: true) == .push)
        #expect(t.hoverChanged(inside: true, enabled: true) == .none)
        #expect(t.hoverChanged(inside: false, enabled: true) == .pop)
        #expect(t.hoverChanged(inside: false, enabled: true) == .none)
    }

    @Test func disabledNeverPushes() {
        var t = PointerCursorTracker()
        #expect(t.hoverChanged(inside: true, enabled: false) == .none)
        #expect(!t.isPushed)
    }

    @Test func disablingWhileInsidePops() {
        var t = PointerCursorTracker()
        _ = t.hoverChanged(inside: true, enabled: true)
        #expect(t.hoverChanged(inside: true, enabled: false) == .pop)
        #expect(t.hoverChanged(inside: true, enabled: true) == .push)
    }
}
