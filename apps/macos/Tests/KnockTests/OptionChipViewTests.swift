import Testing
@testable import Knock

/// `OptionChipView.isSelected`: which option reads as selected, as a pure
/// function of lock state (docs/stories/HAIL-36.md, the same "no option
/// chosen unless the operator picks it" fix as `ComposerViewModel`'s default
/// selection). Locked, this must read the reply's own choice, never the
/// composer's live selection - a reply sent with no choice must mark
/// nothing, even if the composer still holds some other selection.
struct OptionChipViewTests {
    @Test func unlockedReadsTheComposersLiveSelection() {
        #expect(OptionChipView.isSelected(optionId: "a", isLocked: false, yourAnswerOptionId: nil, selectedOptionId: "a"))
        #expect(!OptionChipView.isSelected(optionId: "a", isLocked: false, yourAnswerOptionId: "a", selectedOptionId: nil))
    }

    @Test func lockedReadsTheReplysOwnChoice() {
        #expect(OptionChipView.isSelected(optionId: "a", isLocked: true, yourAnswerOptionId: "a", selectedOptionId: "b"))
        #expect(!OptionChipView.isSelected(optionId: "b", isLocked: true, yourAnswerOptionId: "a", selectedOptionId: "b"))
    }

    /// The case this story fixes: a reply with no choice at all (a typed
    /// message only) must mark no option selected once locked, even if the
    /// composer's own selection still names one - the reply is what was
    /// actually sent, not whatever the composer happens to show now.
    @Test func lockedWithNoChoiceSentMarksNoOptionSelected() {
        #expect(!OptionChipView.isSelected(optionId: "a", isLocked: true, yourAnswerOptionId: nil, selectedOptionId: "a"))
        #expect(!OptionChipView.isSelected(optionId: "b", isLocked: true, yourAnswerOptionId: nil, selectedOptionId: "a"))
    }

    /// docs/stories/HAIL-43.md AC: "the option announces 'selected, click
    /// again to clear'" - only while unlocked, since a locked chip cannot be
    /// cleared by tapping it.
    @Test func accessibilityValueAnnouncesClickAgainToClearWhenSelectedAndUnlocked() {
        #expect(OptionChipView.accessibilityValue(isSelected: true, isLocked: false) == "selected, click again to clear")
        #expect(OptionChipView.accessibilityValue(isSelected: false, isLocked: false) == "")
    }

    /// A locked, selected chip reads "your answer" (matching its "Your
    /// answer" tag) rather than inviting a tap that does nothing.
    @Test func accessibilityValueReadsYourAnswerWhenSelectedAndLocked() {
        #expect(OptionChipView.accessibilityValue(isSelected: true, isLocked: true) == "your answer")
        #expect(OptionChipView.accessibilityValue(isSelected: false, isLocked: true) == "")
    }
}
