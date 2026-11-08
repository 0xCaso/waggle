import Testing
@testable import Knock

/// `ComposerKeyMapping.optionIndex`: which option a digit key names (HAIL-54
/// contract: "pressing the digit key picks that option"), as a pure function
/// of the digit and how many options there are.
struct ComposerKeyMappingTests {
    @Test func mapsEachDigitToItsZeroIndexedOption() {
        #expect(ComposerKeyMapping.optionIndex(forDigit: 1, optionCount: 3) == 0)
        #expect(ComposerKeyMapping.optionIndex(forDigit: 2, optionCount: 3) == 1)
        #expect(ComposerKeyMapping.optionIndex(forDigit: 3, optionCount: 3) == 2)
    }

    @Test func aDigitPastTheLastOptionMapsToNothing() {
        #expect(ComposerKeyMapping.optionIndex(forDigit: 4, optionCount: 3) == nil)
        #expect(ComposerKeyMapping.optionIndex(forDigit: 9, optionCount: 2) == nil)
    }

    @Test func zeroAndNegativeDigitsMapToNothing() {
        #expect(ComposerKeyMapping.optionIndex(forDigit: 0, optionCount: 3) == nil)
        #expect(ComposerKeyMapping.optionIndex(forDigit: -1, optionCount: 3) == nil)
    }

    @Test func noOptionsMeansNoDigitEverMaps() {
        #expect(ComposerKeyMapping.optionIndex(forDigit: 1, optionCount: 0) == nil)
    }
}
