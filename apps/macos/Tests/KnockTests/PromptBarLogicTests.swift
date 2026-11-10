import CoreGraphics
import Testing
@testable import Knock

/// HAIL-77: the prompt bar's growth, layout switch, Return key and Send rules.
struct PromptBarLogicTests {
    private let controls = PromptBarLogic.controlsWidth(quietLabels: ["Ask for more detail"], sendPillLabel: nil)

    private func layout(_ text: String, width: CGFloat = 480, maxLines: Int = 6) -> PromptBarLogic.Layout {
        PromptBarLogic.layout(text: text, barWidth: width, controlsWidth: controls, maxLines: maxLines)
    }

    private func lines(_ n: Int) -> String {
        (1...n).map { "line \($0)" }.joined(separator: "\n")
    }

    // MARK: growth

    @Test func emptyAndShortTextIsOneLine28Tall() {
        for text in ["", "Yes, go ahead"] {
            let l = layout(text)
            #expect(l.totalLines == 1)
            #expect(l.visibleLines == 1)
            #expect(l.fieldHeight == 28)
            #expect(!l.isMultiline)
            #expect(!l.scrolls)
        }
    }

    @Test func threeLinesGrowOneLineAtATime() {
        #expect(layout(lines(2)).fieldHeight == 46)
        let l = layout(lines(3))
        #expect(l.totalLines == 3)
        #expect(l.visibleLines == 3)
        #expect(l.fieldHeight == 64)
        #expect(!l.scrolls)
    }

    @Test func paneCapsAtSixLinesThenScrolls() {
        let six = layout(lines(6))
        #expect(six.visibleLines == 6)
        #expect(six.fieldHeight == 118)
        #expect(!six.scrolls)
        let ten = layout(lines(10))
        #expect(ten.totalLines == 10)
        #expect(ten.visibleLines == 6)
        #expect(ten.fieldHeight == 118)
        #expect(ten.scrolls)
    }

    @Test func workspaceCapsAtFourLines() {
        let l = layout(lines(9), maxLines: PromptBarLogic.workspaceMaxLines)
        #expect(l.visibleLines == 4)
        #expect(l.fieldHeight == 82)
        #expect(l.scrolls)
        #expect(!layout(lines(4), maxLines: 4).scrolls)
    }

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

    @Test func aNewlineSwitchesToTheStackedLayout() {
        #expect(!layout("one line").isMultiline)
        #expect(layout("one\ntwo").isMultiline)
        #expect(layout("one\n").isMultiline)
    }

    @Test func wrappingOnTheSharedRowSwitchesToTheStackedLayout() {
        let text = String(repeating: "word ", count: 12)
        #expect(layout(text, width: 480).isMultiline)
        // The stacked row is wider, so the same text can be one line there.
        #expect(layout(text, width: 480).totalLines >= 1)
        #expect(!layout(text, width: 1400).isMultiline)
    }

    @Test func aNarrowerBarWrapsSooner() {
        let text = "Republish it, but keep the intro short"
        #expect(!layout(text, width: 700).isMultiline)
        #expect(layout(text, width: 330).isMultiline)
    }

    @Test func commentsWidenTheControlsAndShrinkTheSharedRow() {
        let pill = PromptBarLogic.controlsWidth(quietLabels: ["Ask for more detail"], sendPillLabel: "Send + 2 comments")
        #expect(pill > controls + 60)
        let text = "Republish it, but keep the intro short"
        let plain = PromptBarLogic.layout(text: text, barWidth: 520, controlsWidth: controls, maxLines: 6)
        let withPill = PromptBarLogic.layout(text: text, barWidth: 520, controlsWidth: pill, maxLines: 6)
        #expect(withPill.singleRowFieldWidth! < plain.singleRowFieldWidth!)
    }

    // MARK: placeholder

    private let panePlaceholder = "Add a note, or reply in your own words…"
    private let workspacePlaceholder = "Reply, or click an artifact to comment on it…"

    private func emptyLayout(width: CGFloat, placeholder: String, quiet: [String] = ["Ask for more detail", "Open review"]) -> PromptBarLogic.Layout {
        PromptBarLogic.layout(
            text: "", placeholder: placeholder, barWidth: width,
            controlsWidth: PromptBarLogic.controlsWidth(quietLabels: quiet, sendPillLabel: nil),
            maxLines: 6
        )
    }

    @Test func emptyPaneBarStacksWhenThePlaceholderIsCutOffAt1000() {
        // A narrow case pane (Inter Tight sets the placeholder narrower than Inter did, so 480, not 540).
        let l = emptyLayout(width: 480, placeholder: panePlaceholder)
        #expect(l.isMultiline)
        #expect(l.fieldHeight == 28)
    }

    @Test func emptyPaneBarKeepsOneRowWhenThePlaceholderFitsAt1400() {
        let l = emptyLayout(width: 1000, placeholder: panePlaceholder)
        #expect(!l.isMultiline)
    }

    @Test func emptyWorkspaceComposerStacksInTheNarrowColumn() {
        let l = emptyLayout(width: 360, placeholder: workspacePlaceholder, quiet: ["Ask for more detail"])
        #expect(l.isMultiline)
        #expect(l.fieldHeight == 28)
    }

    @Test func placeholderIsIgnoredOnceThereIsText() {
        let l = PromptBarLogic.layout(
            text: "ok", placeholder: panePlaceholder, barWidth: 600,
            controlsWidth: controls, maxLines: 6
        )
        #expect(!l.isMultiline)
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
                        let used = plan.width + PromptBarLogic.controlSize + PromptBarLogic.controlGap
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
        let l = PromptBarLogic.layout(text: "ok", barWidth: wide + 60, controlsWidth: wide, maxLines: 6)
        #expect(l.isMultiline)
    }

}
