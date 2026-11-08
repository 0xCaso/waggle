import Foundation

/// Maps the digit key the friend pressed to an option's 0-indexed position in
/// `Case.options` (HAIL-54: "pressing the digit key picks that option"). A
/// pure function, kept separate from `ComposerViewModel.selectOption(
/// atPosition:)` so the mapping itself - including the out-of-range case, a
/// digit past the last option - is unit-testable without a `Case`/`Option`
/// fixture.
enum ComposerKeyMapping {
    static func optionIndex(forDigit digit: Int, optionCount: Int) -> Int? {
        guard digit >= 1, digit <= optionCount else { return nil }
        return digit - 1
    }
}
