import Testing
@testable import Knock

/// `ComposerViewModel`: the three composer states (docs/design/mvp-values.md
/// §M7) - options with a default selection, and a free-text-only case whose
/// "recommendation" is the answer itself, not an option id.
@MainActor
struct ComposerViewModelTests {
    private static func optionsCase(recommendation: String = "a") -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .review, title: "Layout",
            need: "Pick one", why: "Not a technical call",
            recommendation: recommendation, recommendationWhy: "It is faster",
            options: [Option(id: "a", label: "A · Compact"), Option(id: "b", label: "B · Detailed")],
            status: .needsYou, hasArtifact: false,
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z"
        )
    }

    private static func freeTextCase() -> Case {
        Case(
            id: "c2", taskId: "t1", kind: .question, title: "Socket path",
            need: "Pick a path", why: "Ambiguous requirement",
            recommendation: "App Support", recommendationWhy: "Survives reinstalls",
            options: [], status: .needsYou, hasArtifact: false,
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z"
        )
    }

    /// docs/stories/HAIL-36.md: no option starts selected, even the
    /// recommended one - the operator must pick it, or press "Accept
    /// recommendation", before any option reads as chosen.
    @Test func anOptionsCaseStartsWithNoOptionSelected() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        #expect(composer.selectedOptionId == nil)
        #expect(composer.isOptionsCase)
    }

    /// WAG-343: an ask that began with legacy questions and got new options in a later round decides on the new
    /// options. The reply carries the new choice and no round 0 answers.
    @Test func aLaterOptionSetOnAQuestionsAskCarriesTheNewChoice() {
        let question = Question(
            id: "q", title: "T", now: nil, points: [QuestionPoint(id: "p", text: "P", options: nil)],
            artifactRef: nil, variants: nil, variantLabel: nil)
        let later = Case(
            id: "c3", taskId: "t1", kind: .question, title: "Layout", need: "Pick one", why: "W",
            recommendation: "n2", recommendationWhy: "R",
            options: [Option(id: "n1", label: "New one"), Option(id: "n2", label: "New two")],
            status: .needsYou, hasArtifact: false, createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T11:00:00Z",
            optionsSeq: 3, questions: [question])
        #expect(AskBarMode.forCase(later) == .decide)
        let composer = ComposerViewModel(knockCase: later)
        #expect(composer.isOptionsCase)
        composer.selectOption("n2")
        #expect(composer.currentChoice == "n2")
    }

    @Test func selectingADifferentOptionChangesTheCurrentChoice() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.selectOption("b")
        #expect(composer.selectedOptionId == "b")
        #expect(composer.currentChoice == "b")
    }

    /// docs/stories/HAIL-43.md, operator via Knock 2026-09-28: "Can i
    /// deselect either A or B after selecting one?" - clicking the same
    /// option again must clear it back to no selection.
    @Test func selectingTheSameOptionAgainClearsTheSelection() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.selectOption("b")
        #expect(composer.selectedOptionId == "b")

        composer.selectOption("b")
        #expect(composer.selectedOptionId == nil)
        #expect(composer.currentChoice == nil)
    }

    /// Reselecting a different option after clearing still works normally -
    /// the toggle only clears on a repeat click of the same option.
    @Test func selectingADifferentOptionAfterClearingSelectsIt() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.selectOption("b")
        composer.selectOption("b")
        composer.selectOption("a")
        #expect(composer.selectedOptionId == "a")
    }

    /// The toggle clear must reach the shared draft store too (docs/stories/
    /// HAIL-43.md AC: "draft store persists nil") - a second composer for
    /// the same case must restore no selection, not the option cleared on
    /// the first click.
    @Test func reselectingTheSameOptionPersistsTheClearedSelectionToTheDraftStore() {
        let store = ComposerDraftStore()
        let composer = ComposerViewModel(knockCase: Self.optionsCase(), draftStore: store)
        composer.draftText = "just a comment, no pick"
        composer.selectOption("b")
        composer.selectOption("b")

        let restored = ComposerViewModel(knockCase: Self.optionsCase(), draftStore: store)
        #expect(restored.selectedOptionId == nil)
        #expect(restored.draftText == "just a comment, no pick")
    }

    @Test func recommendationActionAlwaysUsesTheRecommendationRegardlessOfSelection() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.selectOption("b")
        composer.draftText = "ignored"
        #expect(composer.recommendationChoice == "a")
        #expect(composer.recommendationMessage == nil)
    }

    @Test func currentMessageIsNilForEmptyOrWhitespaceOnlyDraftText() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.draftText = "   "
        #expect(composer.currentMessage == nil)
        composer.draftText = "  a note  "
        #expect(composer.currentMessage == "a note")
    }

    @Test func aFreeTextCaseHasNoChoiceAndRecommendsItsRecommendationAsTheMessage() {
        let composer = ComposerViewModel(knockCase: Self.freeTextCase())
        #expect(composer.isOptionsCase == false)
        #expect(composer.selectedOptionId == nil)
        #expect(composer.currentChoice == nil)
        #expect(composer.recommendationChoice == nil)
        #expect(composer.recommendationMessage == "App Support")
    }

    /// docs/stories/HAIL-25.md: "the pane and the review share one draft per
    /// case" - a `nil` draft store (every test above) keeps a
    /// `ComposerViewModel` exactly as it always was; a shared store is what
    /// lets a second instance for the same case id pick up a selection made
    /// on the first.
    @Test func aSharedDraftStoreCarriesTheSelectionIntoASecondComposerForTheSameCase() {
        let store = ComposerDraftStore()
        let firstComposer = ComposerViewModel(knockCase: Self.optionsCase(), draftStore: store)
        firstComposer.selectOption("b")
        firstComposer.draftText = "keep this above the fold"

        let secondComposer = ComposerViewModel(knockCase: Self.optionsCase(), draftStore: store)
        #expect(secondComposer.selectedOptionId == "b")
        #expect(secondComposer.draftText == "keep this above the fold")
    }

    @Test func aFreshDraftStoreHasNothingToRestoreAndSelectsNoOption() {
        let store = ComposerDraftStore()
        let composer = ComposerViewModel(knockCase: Self.optionsCase(), draftStore: store)
        #expect(composer.selectedOptionId == nil)
        #expect(composer.draftText.isEmpty)
    }

    /// A restored draft's own `nil` selection survives (docs/stories/
    /// HAIL-36.md: "A restored draft keeps its own selectedOptionId
    /// (including nil)") - typing a note without ever picking an option must
    /// not resurface as the recommendation once a second composer restores
    /// from the same store.
    @Test func aRestoredDraftWithNoSelectionStaysNilRatherThanFallingBackToTheRecommendation() {
        let store = ComposerDraftStore()
        let firstComposer = ComposerViewModel(knockCase: Self.optionsCase(), draftStore: store)
        firstComposer.draftText = "just a note, no pick"

        let secondComposer = ComposerViewModel(knockCase: Self.optionsCase(), draftStore: store)
        #expect(secondComposer.selectedOptionId == nil)
        #expect(secondComposer.draftText == "just a note, no pick")
    }

    // MARK: - Footer primary action (Amendments, HAIL-25 continue pass)

    /// docs/stories/HAIL-36.md: "Typing a reply and sending with no option
    /// selected sends choice: nil and the message" - `currentChoice` must
    /// stay nil even though the case has options, since nothing was picked.
    @Test func currentChoiceIsNilWhenNoOptionIsSelectedEvenWithATypedMessage() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.draftText = "just a note, no pick"
        #expect(composer.currentChoice == nil)
        #expect(composer.currentMessage == "just a note, no pick")
    }

    // MARK: - Numbered options and the primary button's label (HAIL-54)

    /// `selectOption(atPosition:)` is what the digit-key shortcut calls
    /// (contract: "pressing the digit key picks that option") - a position
    /// picks the same option a click on that row would, HAIL-43's toggle
    /// deselect included.
    @Test func selectOptionAtPositionPicksTheMatchingOptionAndTogglesOffOnRepeat() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.selectOption(atPosition: 2)
        #expect(composer.selectedOptionId == "b")

        composer.selectOption(atPosition: 2)
        #expect(composer.selectedOptionId == nil)
    }

    /// A position with no matching option - "3" pressed on a 2-option case -
    /// is a no-op, not a crash or a fallback to some other option.
    @Test func selectOptionAtPositionIgnoresAnOutOfRangePosition() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.selectOption(atPosition: 3)
        #expect(composer.selectedOptionId == nil)
        composer.selectOption(atPosition: 0)
        #expect(composer.selectedOptionId == nil)
    }

    // MARK: - Ask for more detail (HAIL-33)

    @Test func beginAskingForDetailOpensTheFieldEmpty() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.detailQuestionText = "leftover from a prior open"
        composer.beginAskingForDetail()
        #expect(composer.isAskingForDetail)
        #expect(composer.detailQuestionText.isEmpty)
    }

    @Test func cancelAskingForDetailClosesTheFieldAndClearsIt() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.beginAskingForDetail()
        composer.detailQuestionText = "Show me the numbers"
        composer.cancelAskingForDetail()
        #expect(!composer.isAskingForDetail)
        #expect(composer.detailQuestionText.isEmpty)
    }

    /// The three chips (docs/stories/HAIL-33.md): each fills the field with
    /// its own exact text, still editable afterwards.
    @Test func chipsFillTheDetailQuestionField() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        for chip in ComposerViewModel.detailChips {
            composer.fillDetailChip(chip)
            #expect(composer.detailQuestionText == chip)
        }
    }

    @Test func detailQuestionIsNilForEmptyOrWhitespaceOnlyText() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        #expect(composer.detailQuestion == nil)
        composer.detailQuestionText = "   "
        #expect(composer.detailQuestion == nil)
        composer.detailQuestionText = "  Why blue?  "
        #expect(composer.detailQuestion == "Why blue?")
    }
}
