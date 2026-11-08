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
        #expect(composer.acceptButtonLabel == "Accept recommendation")
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

    /// `selectedOptionLabel` drives the send button's label once a comment
    /// is pinned (`ComposerFooterView.sendLabel`) - it must clear to `nil`
    /// in lockstep with `selectedOptionId` so the label falls back to "Send
    /// reply" the moment the option is deselected.
    @Test func selectedOptionLabelFollowsTheSelectionAndClearsOnDeselect() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        #expect(composer.selectedOptionLabel == nil)

        composer.selectOption("b")
        #expect(composer.selectedOptionLabel == "B · Detailed")

        composer.selectOption("b")
        #expect(composer.selectedOptionLabel == nil)
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
        #expect(composer.acceptButtonLabel == "Send recommended answer")
        #expect(composer.recommendationChoice == nil)
        #expect(composer.recommendationMessage == "App Support")
    }

    /// docs/design/mvp-values.md §M9 `ZBEXl`: "Confirm v3" replaces the
    /// generic accept label once a revision has arrived, for an options case
    /// and a free-text one alike - accepting here means confirming the
    /// returned revision, not choosing between options.
    @Test func aRevisionArrivalReplacesTheAcceptLabelWithConfirmVN() {
        let arrival = RevisionArrival(latestRevision: 3, priorRevision: 2, priorCommentCount: 2, agentMessage: nil)
        let optionsComposer = ComposerViewModel(knockCase: Self.optionsCase(), revisionArrival: arrival)
        #expect(optionsComposer.acceptButtonLabel == "Confirm v3")

        let freeTextComposer = ComposerViewModel(knockCase: Self.freeTextCase(), revisionArrival: arrival)
        #expect(freeTextComposer.acceptButtonLabel == "Confirm v3")
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

    /// docs/stories/HAIL-25.md: an option whose label reads as a change
    /// request (a free-text escape hatch) should route the friend to the
    /// review's message field rather than a plain accept.
    @Test func signalsChangeRequestMatchesFreeTextEscapeHatchLabelsCaseInsensitively() {
        #expect(Option(id: "x", label: "Something else").signalsChangeRequest)
        #expect(Option(id: "x", label: "Change the copy").signalsChangeRequest)
        #expect(Option(id: "x", label: "CUSTOM amount").signalsChangeRequest)
        #expect(!Option(id: "a", label: "A · Compact").signalsChangeRequest)
    }

    // MARK: - Footer primary action (Amendments, HAIL-25 continue pass)

    /// The default state (docs/design/mvp-values.md §M7 panel A; docs/
    /// stories/HAIL-36.md: no option starts selected): nothing picked,
    /// nothing typed, so the primary action stays "Accept recommendation" -
    /// pressing it still sends the recommendation explicitly, the same ⌘D
    /// action as always.
    @Test func footerDefaultsToAcceptRecommendationWhenNothingIsSelectedOrTyped() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        // WAG-316: this fixture is a review. A review decides only with a row picked, so with no pick the
        // primary action sends (comments keep the talk going) and picking the recommended row accepts it.
        #expect(composer.footerPrimaryAction == .send)
        composer.selectOption(composer.knockCase.recommendation)
        #expect(composer.footerPrimaryAction == .acceptRecommendation)
    }

    /// docs/stories/HAIL-36.md: "Typing a reply and sending with no option
    /// selected sends choice: nil and the message" - `currentChoice` must
    /// stay nil even though the case has options, since nothing was picked.
    @Test func currentChoiceIsNilWhenNoOptionIsSelectedEvenWithATypedMessage() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.draftText = "just a note, no pick"
        #expect(composer.currentChoice == nil)
        #expect(composer.currentMessage == "just a note, no pick")
        #expect(composer.footerPrimaryAction == .send)
    }

    /// A pick that differs from the recommendation (Amendment 1): the
    /// primary action must send that pick, named by its 1-indexed position
    /// (HAIL-54: the badge/button both name an option by position, not its
    /// full label - "b" is the second option in `Self.optionsCase()`).
    @Test func footerSendsTheSelectionWhenItDiffersFromTheRecommendation() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.selectOption("b")
        #expect(composer.footerPrimaryAction == .sendOption(position: 2))
    }

    /// A typed note over an unchanged pick (Amendment 1, third state):
    /// "Accept recommendation" would send the pick alone and drop the note,
    /// so the primary action becomes a plain "Send" instead.
    @Test func footerSendsWhenANoteIsTypedOverAnUnchangedSelection() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.draftText = "please hurry"
        #expect(composer.footerPrimaryAction == .send)
    }

    /// A changed selection takes priority over a typed note: the primary
    /// action still names the picked option's position, not a bare "Send".
    @Test func footerPrefersTheChangedSelectionOverATypedNote() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        composer.selectOption("b")
        composer.draftText = "please hurry"
        #expect(composer.footerPrimaryAction == .sendOption(position: 2))
    }

    /// A free-text case (no options) with a typed note: same third state as
    /// an options case, since there is no selection to differ from the
    /// recommendation.
    @Test func footerSendsForAFreeTextCaseWithATypedNote() {
        let composer = ComposerViewModel(knockCase: Self.freeTextCase())
        composer.draftText = "actually, use App Support"
        #expect(composer.footerPrimaryAction == .send)
    }

    // MARK: - Numbered options and the primary button's label (HAIL-54)

    @Test func selectedOptionPositionIsOneIndexedAndClearsOnDeselect() {
        let composer = ComposerViewModel(knockCase: Self.optionsCase())
        #expect(composer.selectedOptionPosition == nil)

        composer.selectOption("a")
        #expect(composer.selectedOptionPosition == 1)

        composer.selectOption("a")
        #expect(composer.selectedOptionPosition == nil)

        composer.selectOption("b")
        #expect(composer.selectedOptionPosition == 2)
    }

    @Test func selectedOptionPositionIsNilForAFreeTextCase() {
        let composer = ComposerViewModel(knockCase: Self.freeTextCase())
        #expect(composer.selectedOptionPosition == nil)
    }

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

    /// `primaryButtonLabel`/`primaryButtonKeyHint`: the button's text and key
    /// hint per state (contract: "'Send <n> ⌘↵' when option n is picked,
    /// 'Send ⌘↵' with only text, 'Accept recommendation ⌘D' when nothing is
    /// picked or typed; '+ N comments' suffix when comments are pinned").
    @Test func primaryButtonLabelPerState() {
        #expect(ComposerViewModel.primaryButtonLabel(action: .acceptRecommendation, commentCount: 0) == "Accept recommendation")
        #expect(ComposerViewModel.primaryButtonLabel(action: .acceptRecommendation, commentCount: 0, compact: true) == "Accept")
        #expect(ComposerViewModel.primaryButtonLabel(action: .sendOption(position: 2), commentCount: 0, compact: true) == "Send 2")
        #expect(ComposerViewModel.primaryButtonLabel(action: .send, commentCount: 0) == "Send")
        #expect(ComposerViewModel.primaryButtonLabel(action: .sendOption(position: 2), commentCount: 0) == "Send 2")
    }

    @Test func primaryButtonLabelAppendsTheCommentSuffixWhenCommentsArePinned() {
        #expect(ComposerViewModel.primaryButtonLabel(action: .send, commentCount: 1) == "Send + 1 comment")
        #expect(ComposerViewModel.primaryButtonLabel(action: .sendOption(position: 1), commentCount: 3) == "Send 1 + 3 comments")
        #expect(ComposerViewModel.primaryButtonLabel(action: .acceptRecommendation, commentCount: 2) == "Accept recommendation + 2 comments")
    }

    @Test func primaryButtonKeyHintIsCommandDOnlyForAcceptRecommendation() {
        #expect(ComposerViewModel.primaryButtonKeyHint(action: .acceptRecommendation) == "⌘D")
        #expect(ComposerViewModel.primaryButtonKeyHint(action: .send) == "⌘↵")
        #expect(ComposerViewModel.primaryButtonKeyHint(action: .sendOption(position: 1)) == "⌘↵")
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
