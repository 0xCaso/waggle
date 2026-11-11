import Testing
import SwiftUI
@testable import Knock

/// The shared press style's values: 0.97, 120 ms, and no scale and no animation under Reduce Motion.
struct PressFeelTests {
    @Test func pressedScalesToTheSharedValue() {
        #expect(PressFeel.scale(isPressed: true, reduceMotion: false) == 0.97)
        #expect(PressFeel.scale(isPressed: false, reduceMotion: false) == 1)
    }

    @Test func reduceMotionNeverScales() {
        #expect(PressFeel.scale(isPressed: true, reduceMotion: true) == 1)
        #expect(PressFeel.scale(isPressed: false, reduceMotion: true) == 1)
    }

    @Test func animationIsShortAndOffUnderReduceMotion() {
        #expect(PressFeel.duration == 0.12)
        #expect(PressFeel.animation(reduceMotion: true) == nil)
        #expect(PressFeel.animation(reduceMotion: false) != nil)
    }
}
