import Testing
@testable import Knock

/// `OptionLabelFormatting.displayLabel`: strips an agent's own letter/number
/// prefix (HAIL-54 contract: "when an option label starts with a letter or
/// number prefix like 'A · ', 'A. ', 'A) ', 'B: ', '1. ', '2) ' strip it for
/// display"), since Knock now numbers every option itself with the key badge.
struct OptionLabelFormattingTests {
    @Test func stripsEveryPrefixFormTheContractNames() {
        #expect(OptionLabelFormatting.displayLabel("A · Compact") == "Compact")
        #expect(OptionLabelFormatting.displayLabel("A. Compact") == "Compact")
        #expect(OptionLabelFormatting.displayLabel("A) Compact") == "Compact")
        #expect(OptionLabelFormatting.displayLabel("B: Detailed") == "Detailed")
        #expect(OptionLabelFormatting.displayLabel("1. Compact") == "Compact")
        #expect(OptionLabelFormatting.displayLabel("2) Detailed") == "Detailed")
    }

    @Test func leavesALabelWithNoPrefixUntouched() {
        #expect(OptionLabelFormatting.displayLabel("Compact") == "Compact")
        #expect(OptionLabelFormatting.displayLabel("Ship as is") == "Ship as is")
    }

    /// A digit with no separator after it is ordinary text, not a prefix -
    /// "3 pack bundle" must not lose its leading "3".
    @Test func doesNotStripADigitWithNoSeparatorFollowingIt() {
        #expect(OptionLabelFormatting.displayLabel("3 pack bundle") == "3 pack bundle")
        #expect(OptionLabelFormatting.displayLabel("A compact card") == "A compact card")
    }

    @Test func stripsOnlyTheLeadingPrefixNotAnyLaterOccurrence() {
        #expect(OptionLabelFormatting.displayLabel("A · Compact: one screen") == "Compact: one screen")
    }

    // MARK: - Titles (HAIL-85)

    @Test func anAgentTitleWinsOverTheLabel() {
        let option = Option(id: "a", label: "Compact: one screen, fewer fields", title: "Tight layout")
        #expect(option.displayTitle == "Tight layout")
    }

    @Test func aBlankTitleFallsBackToTheDerivedOne() {
        #expect(Option(id: "a", label: "Compact: one screen", title: "  ").displayTitle == "Compact")
    }

    @Test func derivesTheTextBeforeTheFirstColonWhenItIsOneToSixWords() {
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "Compact: one screen, fewer fields") == "Compact")
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "A · One page for it all: design left") == "One page for it all")
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "One two three four five six: rest") == "One two three four five six")
    }

    // HAIL-99: no clamp, no "…". The old "fallsBackToTheFirstSentenceWhenTheColonHeadIsTooLong"
    // and "clampsALongFirstSentenceToOneLineWithAnEllipsis" tests are replaced on purpose.
    @Test func fallsBackToTheFirstSentenceWhenTheColonHeadIsTooLong() {
        let label = "One two three four five six seven: rest of it. And a second sentence."
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: label) == "One two three four five six seven: rest of it.")
    }

    @Test func usesTheFirstSentenceWhenThereIsNoColon() {
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "Ship it now. Then tidy up later.") == "Ship it now.")
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "Ship as is") == "Ship as is")
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "Version 2.5 is fine") == "Version 2.5 is fine")
    }

    @Test func usesTheFirstClauseWhenItIsShortEnough() {
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "Ship it now; tidy up later") == "Ship it now")
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "Ship it now — tidy up later") == "Ship it now")
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "Ship it now – tidy up later") == "Ship it now")
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "Ship it now - tidy up later") == "Ship it now")
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "Ship it now (and tidy up later)") == "Ship it now")
    }

    @Test func aLongLabelWithNoShortClauseIsTheWholeLabel() {
        let label = "Mention it as an optional path for rich, stateful prototypes, with the three fixes written in; plain HTML stays the default"
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: label) == label)
        let long = "One page the ask page itself becomes the split view with the design on the left and the question and answer on the right"
        let title = OptionLabelFormatting.derivedTitle(fromLabel: long)
        #expect(title == long)
        #expect(!title.contains("…"))
    }

    @Test func theOperatorExampleWithAColonUsesTheColonHead() {
        #expect(OptionLabelFormatting.derivedTitle(fromLabel: "Leave it out: plain HTML is good enough for reviews") == "Leave it out")
    }

    @Test func aWholeLabelTitleShowsOnceInTheDecisionSection() {
        let label = "Mention it as an optional path for rich, stateful prototypes, with the three fixes written in; plain HTML stays the default"
        let entry = DecisionSectionView.entries(options: [Option(id: "a", label: label)], recommendationId: "x")[0]
        #expect(entry.title == label)
        #expect(!entry.showsLabel)
    }

    @Test func cutAtWordNeverCutsMidWord() {
        #expect(OptionLabelFormatting.cutAtWord("short title", limit: 20) == "short title")
        let cut = OptionLabelFormatting.cutAtWord("alpha beta gamma delta epsilon", limit: 13)
        #expect(cut == "alpha beta…")
        #expect(OptionLabelFormatting.cutAtWord("alpha beta gamma", limit: 10) == "alpha beta…")
    }

    @Test func decisionBodyDropsARepeatedTitle() {
        #expect(OptionLabelFormatting.decisionBody(
            label: "Two pages: keep the ask page and the review page apart.", title: "Two pages")
            == "Keep the ask page and the review page apart.")
        #expect(OptionLabelFormatting.decisionBody(label: "One page : the split view.", title: "one page") == "The split view.")
        #expect(OptionLabelFormatting.decisionBody(label: "B · Detailed: more room.", title: "Detailed") == "More room.")
        #expect(OptionLabelFormatting.decisionBody(label: "Keep the scroll as it is.", title: "Keep") == "Keep the scroll as it is.")
        #expect(OptionLabelFormatting.decisionBody(label: "Ship it", title: "Ship it") == "Ship it")
    }
}
