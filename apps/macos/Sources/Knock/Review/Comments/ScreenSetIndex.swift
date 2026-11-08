import Foundation

/// WAG-323: which screen of a set the artifact box shows. Pure, so the bounds and the jumps are tested
/// without a view. The ends do not wrap: past the last screen, Next does nothing.
struct ScreenSetIndex: Equatable {
    private(set) var count: Int
    private(set) var current: Int

    init(count: Int, current: Int = 0) {
        self.count = max(0, count)
        self.current = Self.clamp(current, count: max(0, count))
    }

    var canGoPrevious: Bool { current > 0 }
    var canGoNext: Bool { current < count - 1 }

    /// Moves by `delta`, held between the first and last screen. True when the index moved.
    @discardableResult
    mutating func step(by delta: Int) -> Bool {
        jump(to: current + delta)
    }

    /// Goes to `index`, held between the first and last screen. True when the index moved.
    @discardableResult
    mutating func jump(to index: Int) -> Bool {
        let target = Self.clamp(index, count: count)
        defer { current = target }
        return target != current
    }

    /// A new set of `count` screens (a new revision): the screen on show stays by position, held to the new count.
    mutating func reset(count newCount: Int) {
        count = max(0, newCount)
        current = Self.clamp(current, count: count)
    }

    private static func clamp(_ index: Int, count: Int) -> Int {
        count == 0 ? 0 : max(0, min(count - 1, index))
    }
}
