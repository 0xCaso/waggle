import Testing
@testable import Knock

/// The Decision section lists every option in full (HAIL-85); the answer box
/// rows show only the short title.
struct DecisionSectionViewTests {
    private let long = "One page: the ask page itself becomes the split view (design left, question and answer right), so the operator never leaves the page while deciding."
    /// `long` in the Decision section: the repeated "One page:" is dropped
    /// (operator, 30 Sep, ship_trim), the rest is kept in full.
    private let longBody = "The ask page itself becomes the split view (design left, question and answer right), so the operator never leaves the page while deciding."

    @Test func listsEveryOptionInOrderWithItsFullLabel() {
        let options = [
            Option(id: "a", label: long, title: "One page"),
            Option(id: "b", label: "B · Two pages: keep them apart"),
        ]
        let entries = DecisionSectionView.entries(options: options, recommendationId: "a")
        #expect(entries == [
            .init(position: 1, title: "One page", label: longBody, isRecommended: true),
            .init(position: 2, title: "Two pages", label: "Keep them apart", isRecommended: false),
        ])
    }

    @Test func aNoTitleOptionGetsADerivedTitleButKeepsItsFullLabel() {
        let entries = DecisionSectionView.entries(options: [Option(id: "a", label: long)], recommendationId: "x")
        #expect(entries[0].title == "One page")
        #expect(entries[0].label == longBody)
        #expect(!entries[0].isRecommended)
    }

    @Test func answerRowsShowTheTitleNotTheLabel() {
        let withTitle = Option(id: "a", label: long, title: "One page")
        let old = Option(id: "b", label: "Compact: one screen, fewer fields")
        #expect(withTitle.displayTitle == "One page")
        #expect(old.displayTitle == "Compact")
    }

    @Test func aShortOptionDoesNotRepeatItsTitleUnderIt() {
        let short = DecisionSectionView.Entry(position: 1, title: "Ship as is", label: "Ship as is.", isRecommended: true)
        #expect(!short.showsLabel)
        let long = DecisionSectionView.Entry(position: 2, title: "Needs another pass", label: "Hold it: the contrast is too low on the button.", isRecommended: false)
        #expect(long.showsLabel)
    }
}
