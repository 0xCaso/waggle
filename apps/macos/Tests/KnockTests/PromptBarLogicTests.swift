import CoreGraphics
import Testing
@testable import Knock

/// HAIL-77: the prompt bar's growth, layout switch, Return key and Send rules.
@MainActor
struct PromptBarLogicTests {
    private let controls = PromptBarLogic.controlsWidth(quietLabels: ["Ask for more detail"], sendPillLabel: nil)

    // MARK: growth (the measured height itself is in PromptBarFieldSizingTests)

    @Test func aTrailingNewlineCountsAsALine() {
        #expect(PromptBarLogic.lineCount(text: "a\n", textWidth: 300) == 2)
        #expect(PromptBarLogic.lineCount(text: "", textWidth: 300) == 1)
    }

    @Test func longTextWrapsIntoMoreLines() {
        let text = String(repeating: "word ", count: 80)
        #expect(PromptBarLogic.lineCount(text: text, textWidth: 300) > 3)
        #expect(PromptBarLogic.lineCount(text: text, textWidth: 300) > PromptBarLogic.lineCount(text: text, textWidth: 900))
    }

    // MARK: layout switch

    private func ownRow(_ text: String, width: CGFloat = 480, controlsWidth: CGFloat? = nil) -> Bool {
        PromptBarLogic.fieldTakesOwnRow(
            text: text, naturalTextWidth: PromptBarFieldProbe.naturalWidth(text), barWidth: width,
            controlsWidth: controlsWidth ?? controls)
    }

    @Test func aNewlineSwitchesToTheStackedLayout() {
        #expect(!ownRow("one line"))
        #expect(ownRow("one\ntwo"))
        #expect(ownRow("one\n"))
    }

    @Test func wrappingOnTheSharedRowSwitchesToTheStackedLayout() {
        let text = String(repeating: "word ", count: 12)
        #expect(ownRow(text, width: 480))
        #expect(!ownRow(text, width: 1400))
    }

    @Test func aNarrowerBarWrapsSooner() {
        let text = "Republish it, but keep the intro short"
        #expect(!ownRow(text, width: 700))
        #expect(ownRow(text, width: 330))
    }

    @Test func commentsWidenTheControlsAndShrinkTheSharedRow() {
        let pill = PromptBarLogic.controlsWidth(quietLabels: ["Ask for more detail"], sendPillLabel: "Send + 2 comments")
        #expect(pill > controls + 60)
        #expect(PromptBarLogic.sharedRowFieldWidth(barWidth: 520, controlsWidth: pill)
            < PromptBarLogic.sharedRowFieldWidth(barWidth: 520, controlsWidth: controls))
    }

    // MARK: placeholder (WAG-305: an empty field keeps the shared row; the placeholder wraps there)

    @Test func anEmptyFieldKeepsTheSharedRow() {
        // While it keeps 140 pt there (C6); a narrower bar leaves it under 140 pt beside these controls, so it moves.
        #expect(!PromptBarLogic.fieldTakesOwnRow(text: "", naturalTextWidth: 0, barWidth: 400, controlsWidth: controls))
        #expect(PromptBarLogic.fieldTakesOwnRow(text: "", naturalTextWidth: 0, barWidth: 360, controlsWidth: controls)
            == (PromptBarLogic.sharedRowFieldWidth(barWidth: 360, controlsWidth: controls) < PromptBarLogic.minSharedFieldWidth))
        #expect(!PromptBarLogic.fieldTakesOwnRow(text: "", naturalTextWidth: nil, barWidth: 1000, controlsWidth: controls))
    }

    // MARK: Return key

    @Test func returnSendsWhenThereIsSomethingToSend() {
        #expect(PromptBarLogic.returnKeyAction(shift: false, command: false, hasMarkedText: false, canSend: true) == .send)
    }

    @Test func returnDoesNothingWithNothingToSend() {
        #expect(PromptBarLogic.returnKeyAction(shift: false, command: false, hasMarkedText: false, canSend: false) == .ignore)
    }

    @Test func shiftReturnInsertsANewlineEvenWithNothingToSend() {
        #expect(PromptBarLogic.returnKeyAction(shift: true, command: false, hasMarkedText: false, canSend: true) == .newline)
        #expect(PromptBarLogic.returnKeyAction(shift: true, command: false, hasMarkedText: false, canSend: false) == .newline)
    }

    @Test func imeCompositionNeverSends() {
        #expect(PromptBarLogic.returnKeyAction(shift: false, command: false, hasMarkedText: true, canSend: true) == .passThrough)
        #expect(PromptBarLogic.returnKeyAction(shift: true, command: false, hasMarkedText: true, canSend: true) == .passThrough)
    }

    @Test func commandReturnIsLeftToTheShortcut() {
        #expect(PromptBarLogic.returnKeyAction(shift: false, command: true, hasMarkedText: false, canSend: true) == .passThrough)
    }

    // MARK: Send

    @Test func sendIsLiveForAChoiceTextOrComments() {
        #expect(!PromptBarLogic.canSend(hasChoice: false, hasMessage: false, commentCount: 0))
        #expect(PromptBarLogic.canSend(hasChoice: true, hasMessage: false, commentCount: 0))
        #expect(PromptBarLogic.canSend(hasChoice: false, hasMessage: true, commentCount: 0))
        #expect(PromptBarLogic.canSend(hasChoice: false, hasMessage: false, commentCount: 2))
    }

    @Test func sendPillNamesTheComments() {
        #expect(PromptBarLogic.sendPillLabel(commentCount: 0) == nil)
        #expect(PromptBarLogic.sendPillLabel(commentCount: 1) == "Send + 1 comment")
        #expect(PromptBarLogic.sendPillLabel(commentCount: 3) == "Send + 3 comments")
    }

    @Test func nothingToSendMeansSendDoesNothing() {
        #expect(PromptBarLogic.sendAction(primary: .acceptRecommendation, canSend: false, commentCount: 0, acceptsRecommendationWithComments: true) == .none)
    }

    @Test func aTypedNoteOrPickedOptionSends() {
        #expect(PromptBarLogic.sendAction(primary: .send, canSend: true, commentCount: 0, acceptsRecommendationWithComments: true) == .send)
        #expect(PromptBarLogic.sendAction(primary: .sendOption(position: 2), canSend: true, commentCount: 0, acceptsRecommendationWithComments: true) == .send)
    }

    @Test func commentsOnlyKeepsEachHostsOldRule() {
        // The options card accepted the recommendation with comments; the free-text footer sent.
        #expect(PromptBarLogic.sendAction(primary: .acceptRecommendation, canSend: true, commentCount: 2, acceptsRecommendationWithComments: true) == .acceptRecommendation)
        #expect(PromptBarLogic.sendAction(primary: .acceptRecommendation, canSend: true, commentCount: 2, acceptsRecommendationWithComments: false) == .send)
    }

    @Test func theBarHasNoAcceptControl() {
        #expect(PromptBarLogic.quietLabels(hasOpenReview: false) == ["Ask for more detail"])
        #expect(PromptBarLogic.quietLabels(hasOpenReview: true) == ["Ask for more detail", "Open review"])
    }

    // MARK: Fitting the controls row (bug 4 Oct 2026: "rove section + 1 commen")

    private let designQuiet = ["Ask for more detail", "Change"]
    private var designPills: [String?] {
        PromptBarLogic.sendPillLabels(commentCount: 1, planLabel: "Approve section", shortPlanLabel: "Approve")
    }

    @Test func pillFormsGoFromFullToShortToBare() {
        #expect(designPills == ["Approve section + 1 comment", "Approve + 1 comment", "Approve"])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 12) == ["Send + 12 comments", "Send"])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0) == [nil])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, planLabel: "Next question", shortPlanLabel: "Next")
            == ["Next question", "Next"])
    }

    @Test func aWideRowShowsEverything() {
        let plan = PromptBarLogic.controlsPlan(rowWidth: 700, quietLabels: designQuiet, pillLabels: designPills)
        #expect(plan == .init(quietLabels: designQuiet, overflowLabels: [], sendPillLabel: "Approve section + 1 comment"))
    }

    @Test func anUnmeasuredRowShowsEverything() {
        let plan = PromptBarLogic.controlsPlan(rowWidth: nil, quietLabels: designQuiet, pillLabels: designPills)
        #expect(plan.overflowLabels.isEmpty && plan.sendPillLabel == "Approve section + 1 comment")
    }

    @Test func quietButtonsGiveWayBeforeThePrimaryLabelShortens() {
        // Just wide enough for the full pill with "Ask for more detail" in the menu.
        let full = PromptBarLogic.ControlsPlan(
            quietLabels: ["Change"], overflowLabels: ["Ask for more detail"], sendPillLabel: "Approve section + 1 comment")
        let row = full.width + PromptBarLogic.controlSize + PromptBarLogic.controlGap
        let plan = PromptBarLogic.controlsPlan(rowWidth: row, quietLabels: designQuiet, pillLabels: designPills)
        // Too narrow to keep the 200 pt field beside the controls: they take their own row, the quiet button in the menu.
        #expect(plan.ownRow)
        #expect(plan.quietLabels == full.quietLabels && plan.overflowLabels == full.overflowLabels && plan.sendPillLabel == full.sendPillLabel)
        // Narrower still: "Change" goes into the menu too, the pill keeps its full words.
        let tighter = PromptBarLogic.controlsPlan(rowWidth: row - 20, quietLabels: designQuiet, pillLabels: designPills)
        #expect(tighter.overflowLabels == designQuiet)
        #expect(tighter.sendPillLabel == "Approve section + 1 comment")
    }

    @Test func theControlsAlwaysFitTheNarrowestColumn() {
        // The review workspace's ask column is at least 340 pt: 24 pt footer padding each
        // side, the bar's 1 pt border and 6 pt padding leave a 278 pt row.
        let kinds: [(quiet: [String], plan: String?, short: String?)] = [
            (["Ask for more detail"], nil, nil),
            (["Ask for more detail", "Open review"], nil, nil),
            ([], nil, nil),
            (["Ask for more detail"], "Next question", "Next"),
            (["Ask for more detail"], "Use this approach", "Use this"),
            (["Ask for more detail", "Change"], "Approve section", "Approve"),
            (["Ask for more detail", "Request changes"], "Approve and start planning", "Approve"),
        ]
        for row in stride(from: CGFloat(278), through: 700, by: 4) {
            for kind in kinds {
                for comments in [0, 1, 12] {
                    for picks in kind.plan == nil ? [0, 3] : [0] {
                        let forms = PromptBarLogic.sendPillLabels(
                            commentCount: comments, pickCount: picks, planLabel: kind.plan, shortPlanLabel: kind.short)
                        let plan = PromptBarLogic.controlsPlan(rowWidth: row, quietLabels: kind.quiet, pillLabels: forms)
                        let used = plan.width + PromptBarLogic.attachWidth + PromptBarLogic.controlGap
                        #expect(used <= row, "\(kind.plan ?? "send") \(comments)c \(picks)p at \(row): \(plan)")
                        // The menu takes the leftmost buttons; every button stays reachable.
                        #expect(plan.overflowLabels + plan.quietLabels == kind.quiet)
                    }
                }
            }
        }
    }

    @Test func theCaseOfTheBugReportKeepsItsFullWordsAt540() {
        // Case pane about 540 pt: 24 pt footer padding each side, 1 pt border, 6 pt bar padding.
        let plan = PromptBarLogic.controlsPlan(rowWidth: 540 - 48 - 2 - 12, quietLabels: designQuiet, pillLabels: designPills)
        #expect(plan.sendPillLabel == "Approve section + 1 comment")
    }

    @Test func controlsWithNoRoomForTheFieldTakeTheirOwnRow() {
        let wide = PromptBarLogic.controlsWidth(quietLabels: designQuiet, sendPillLabel: "Approve section + 12 comments")
        #expect(PromptBarLogic.fieldTakesOwnRow(text: "ok", naturalTextWidth: 12, barWidth: wide + 60, controlsWidth: wide))
    }

    @Test func commandDStillSendsTheRecommendedChoice() {
        // ⌘D is the hidden shortcut button wired to `acceptRecommendation`; the bar's
        // Send with nothing picked, typed or commented must not do the same.
        #expect(PromptBarLogic.sendAction(primary: .acceptRecommendation, canSend: false, commentCount: 0, acceptsRecommendationWithComments: false) == .none)
    }
}
