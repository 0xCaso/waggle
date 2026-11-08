import Foundation
import Testing
@testable import Knock

/// WAG-281: the calm card option look.
struct CalmCardTests {
    private let options = [
        Option(id: "a", label: "Rewrite the message of commit 206543af so its risk note is valid, then force-push the branch.", title: "Rewrite and force-push", pros: ["Every check is green"], cons: ["Rewrites two commits"]),
        Option(id: "b", label: "Merge as it is", title: "Merge as it is", pros: ["Merges today"], cons: ["Red check stays"], why: "Fast, but the check fails again later."),
        Option(id: "c", label: "Open the pull request now and fix the note in round 3.", title: "Open it, fix later"),
    ]

    private func makeCase(options: [Option]) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Pick one", need: "Need", why: "Why",
            recommendation: options.first?.id ?? "", recommendationWhy: "Because", options: options,
            status: .needsYou, hasArtifact: true,
            createdAt: "2026-10-07T10:00:00Z", updatedAt: "2026-10-07T10:00:00Z")
    }

    @Test func barRowsNeverExpand() {
        #expect(CalmOption.rowsExpand == false)
        #expect(OptionChipView.isSelected(optionId: "a", isLocked: false, yourAnswerOptionId: nil, selectedOptionId: "a"))
    }

    @Test func chipCountsFollowTheLists() {
        #expect(CalmOption.chipCounts(pros: ["a", "b"], cons: ["c"]) == (2, 1))
        #expect(CalmOption.chipCounts(pros: [], cons: []) == (0, 0))
        #expect(CalmOption.goodTip(2) == "2 good points" && CalmOption.watchTip(1) == "1 thing to watch")
        #expect(CalmOption.tooltipDelay == 0.4 && CalmOption.blockFade == 0.15)
    }

    @Test func yourPickBlockFollowsTheSelectionAndFallsBackToTheRecommendation() {
        let picked = CalmOption.pickBlock(options: options, selectedId: "c", recommendationId: "a")
        #expect(picked?.option.id == "c" && picked?.position == 3 && picked?.isPick == true)
        let fallback = CalmOption.pickBlock(options: options, selectedId: nil, recommendationId: "b")
        #expect(fallback?.option.id == "b" && fallback?.position == 2 && fallback?.isPick == false)
        #expect(CalmOption.pickBlock(options: options, selectedId: nil, recommendationId: nil) == nil)
        #expect(CalmOption.pickBlock(options: options, selectedId: "zzz", recommendationId: "a")?.option.id == "a")
        #expect(CalmOption.blockLabel(position: 2, isPick: true) == "YOUR PICK · 2")
        #expect(CalmOption.blockLabel(position: 2, isPick: false) == "RECOMMENDED · 2")
        #expect(CalmOption.blockLabel(position: 1, isPick: true, suffix: "POINT 2") == "YOUR PICK · 1 · POINT 2")
    }

    @Test func aStepPointPicksByChoice() {
        let point = QuestionPoint(id: "p", text: "Which?", options: [PointOption(label: "One", pros: ["x"]), PointOption(label: "Two", cons: ["y"])])
        #expect(CalmOption.pointPick(point, choice: "Two")?.position == 2)
        #expect(CalmOption.pointPick(point, choice: nil) == nil)
        let plain = QuestionPoint(id: "q", text: "Plain?", options: nil)
        // WAG-304: plain string answers get a pick box too; a point has no recommendation, so no pick means no block.
        #expect(CalmOption.pointPick(plain, choice: "Yes")?.option.label == "Yes")
        #expect(CalmOption.pointPick(plain, choice: nil) == nil)
        #expect(CalmOption.pointPick(plain, choice: "Maybe") == nil)
    }

    @Test func aClosedRowShowsTheFirstWordsOfTheDescription() {
        let body = CalmOption.description(of: options[0], position: 1)
        let short = CalmOption.shortLine(body)
        #expect(short == "Rewrite the message of commit 206543af so its…")
        #expect(CalmOption.shortLine("Keep it short") == "Keep it short")
        #expect(CalmOption.shortLine(nil) == nil)
        #expect(CalmOption.description(of: Option(id: "x", label: "Merge as it is", title: "Merge as it is"), position: 1) == nil)
    }

    @Test func theBarRowKeepsTheDescriptionForTheTooltip() {
        let body = CalmOption.description(of: options[0], position: 1)
        #expect(body == options[0].label)
        #expect(CompactOptionRow.hasTip(description: body, pros: [], cons: [], note: nil))
        #expect(!CompactOptionRow.hasTip(description: nil, pros: [], cons: [], note: nil))
        let row = CompactOptionRow(position: 1, title: "T", description: body, isSelected: false, onSelect: {})
        #expect(row.description == body)
        let tip = OptionTooltipView(description: body, pros: ["a"], cons: [], note: "n", isRecommended: true)
        #expect(tip.description == body && tip.isRecommended)
    }

    @Test func theRecommendedPillAndLabel() {
        #expect(CalmOption.recommendedPill == "Recommended")
        #expect(CompactOptionRow.accessibilityLabel(title: "Merge", isRecommended: true) == "Merge, Recommended")
        #expect(CompactOptionRow.accessibilityLabel(title: "Merge", isRecommended: false) == "Merge")
        #expect(CalmNoteView.title(isRecommended: false) == "Why")
    }

    @Test func theRecommendationWhyShowsOnlyOnTheRecommendedOption() {
        let why = "Only this loop wrote to the branch."
        #expect(CalmOption.note(for: options[0], isRecommended: true, recommendationWhy: why) == why)
        #expect(CalmOption.note(for: options[2], isRecommended: false, recommendationWhy: why) == nil)
        #expect(CalmOption.note(for: options[1], isRecommended: false, recommendationWhy: why) == "Fast, but the check fails again later.")
        #expect(CalmOption.note(for: options[0], isRecommended: true, recommendationWhy: "") == nil)
        #expect(CalmNoteView.title(isRecommended: true) == "Why I recommend it")
    }

    @Test func aMissingWhyDecodesAndOldOptionsStillDecode() throws {
        let json = #"{"id":"a","label":"A","why":"Because"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(Option.self, from: json).why == "Because")
        let old = #"{"id":"a","label":"A"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(Option.self, from: old).why == nil)
    }

    @Test func thePanelSwapsItsDocWithThePick() {
        let item = makeCase(options: options)
        let first = AskPanelLayout.pickedOption(in: item, selectedId: "a")
        let second = AskPanelLayout.pickedOption(in: item, selectedId: "c")
        #expect(first?.id == "a" && second?.id == "c")
        #expect(CalmOption.pickLabel(options[2], position: 3) == "YOUR PICK · 3 OPEN IT, FIX LATER")
        #expect(CalmOption.swapDuration == 0.2 && CalmOption.openDuration == 0.22)
        // A pick without lists still shows its description.
        #expect(AskPanelLayout.parts(for: item, picked: options[2]).contains(.pickedPoints))
    }

    @Test func aPlanAndAMultiQuestionPointUseTheSameLook() {
        // A plan ask keeps its options as plain Options, so the same calm rules apply.
        let planOptions = [Option(id: "a", label: "Anyone with the link: Anyone can view.", title: "Anyone with the link", pros: ["No setup"], cons: ["Links leak"])]
        #expect(CalmOption.description(of: planOptions[0], position: 1) == "Anyone can view.")
        // A point's answers carry pros and cons and show cards (WAG-257).
        let point = PointOption(label: "Cards", pros: ["Easy"], cons: ["Roomy"])
        #expect(point.hasPoints)
        #expect(CalmOption.goodTip(1) == "1 good point")
    }

    @Test func noCopyHasAnEmDash() {
        let copy = [CalmNoteView.title(isRecommended: true), CalmNoteView.title(isRecommended: false), CalmOption.pickLabel(options[0], position: 1)]
        #expect(copy.allSatisfy { !$0.contains("—") })
    }

    /// WAG-288: three levels, one shared style.
    @Test func theThreeTextLevelsShareOneStyle() {
        #expect(CalmNoteView.title(isRecommended: true) == "Why I recommend it")
        #expect(CalmNoteView.title(isRecommended: false) == "Why")
        #expect(OptionText.descriptionColor == Theme.Colors.ink2)
        #expect(OptionText.whyLabelColor == Theme.Colors.ink3)
        #expect(OptionText.whyColor == Theme.Colors.ink2)
        #expect(OptionText.descriptionStyle.size > OptionText.whyStyle.size)
        #expect(CalmOption.note(for: options[0], isRecommended: true, recommendationWhy: "Because") == "Because")
        #expect(CalmOption.note(for: options[1], isRecommended: false, recommendationWhy: "Because") == "Fast, but the check fails again later.")
    }
}
