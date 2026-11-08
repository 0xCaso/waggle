import Foundation
import Testing
@testable import Knock

/// The context card's rows (HAIL-107): session, earlier asks, each thread step once, the newest update at the bottom.
struct ContextCardTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func thread(_ steps: [ThreadStep]) -> ThreadModel { ThreadModel(steps: steps, runtimeName: "Claude Code") }

    private var asked: ThreadStep { .asked(.init(need: "Approve the card hiding once done.", meta: nil, at: t0)) }
    private var replied: ThreadStep {
        .replied(.init(
            summary: "How do we define skipped?", meta: nil, at: t0.addingTimeInterval(60),
            pickedUp: .init(runtime: "Claude Code", at: t0.addingTimeInterval(70), worked: 14)))
    }
    private func updated(_ message: String = "Skipped means **tap**.") -> ThreadStep {
        .updated(.init(message: message, revision: nil, at: t0.addingTimeInterval(120)))
    }

    private func block(earlier: Int = 2, withLine: Bool = true) -> SessionContextBlock {
        let items = (0..<earlier).map {
            SessionContextBlock.Item(caseId: "c\($0)", kind: .answer, at: t0.addingTimeInterval(Double($0)), text: "You chose: option \($0)")
        }
        let line = withLine
            ? SessionContextBlock.Line(status: .working, summary: "Fixing the check-in flow", detail: "· 3rd decision · started 1h ago", startedAgo: "1h")
            : nil
        return SessionContextBlock(line: line, earlier: items, askNumber: 3)
    }

    @Test func titleCarriesTheAskOrdinal() {
        #expect(ContextCardModel.make(block: block(), thread: nil).title == "Context · 3rd request")
        #expect(ContextCardModel.make(block: nil, thread: thread([asked])).title == "Context")
    }

    @Test func rowsRunSessionEarlierThenEachStepOnce() {
        let model = ContextCardModel.make(block: block(), thread: thread([asked, replied]))
        #expect(model.rows.map(\.label) == ["This session", "2 earlier requests", "Decision", "You replied"])
        #expect(model.rows.map(\.time).first == "1h")
        #expect(model.update == nil)
    }

    @Test func oneEarlierAskReadsInTheSingular() {
        let model = ContextCardModel.make(block: block(earlier: 1, withLine: false), thread: nil)
        #expect(model.rows.map(\.label) == ["1 earlier request"])
    }

    @Test func theNewestUpdateLeavesTheRowsAndSitsAtTheBottom() {
        let model = ContextCardModel.make(block: nil, thread: thread([asked, replied, updated()]))
        #expect(model.rows.map(\.label) == ["Decision", "You replied"])
        #expect(model.update?.message == "Skipped means **tap**.")
        #expect(model.update?.runtime == "Claude Code")
    }

    @Test func anUpdateYouRepliedToStaysAsARow() {
        let model = ContextCardModel.make(block: nil, thread: thread([asked, replied, updated(), replied]))
        #expect(model.rows.map(\.label) == ["Decision", "You replied", "Updated", "You replied"])
        #expect(model.update == nil)
    }

    @Test func aRowChipIsOnePlainLineAndItsDetailKeepsTheFullText() {
        let model = ContextCardModel.make(block: nil, thread: thread([asked, replied]))
        let reply = model.rows[1]
        #expect(reply.chip == "How do we define skipped?")
        #expect(reply.details[0].text == "How do we define skipped?")
        #expect(reply.details[0].caption == "Picked up by Claude Code " + ThreadCopy.clock(t0.addingTimeInterval(70)) + " · worked 14s")
    }

    @Test func aDetailRequestChipStripsTheLeadMarkersAndKeepsTheQuestion() {
        let step = ThreadStep.replied(.init(summary: "Asked for more detail\n\nWhy blue?", meta: nil, at: t0, pickedUp: nil))
        let model = ContextCardModel.make(block: nil, thread: thread([step]))
        #expect(model.rows[0].details[0].text == "Asked for more detail\n\nWhy blue?")
        #expect(!model.rows[0].chip.contains("\n"))
    }

    @Test func aLatestRevisionOffersTheVersionBefore() {
        let step = ThreadStep.updated(.init(
            message: "New version.", revision: .init(n: 2, isLatest: true, prior: 1), at: t0))
        let update = ContextCardModel.make(block: nil, thread: thread([asked, step])).update
        #expect(update?.revisionLabel == "v2 is new")
        #expect(update?.priorVersion == 1)
    }

    @Test func nothingToShowIsEmpty() {
        #expect(ContextCardModel.make(block: nil, thread: nil).isEmpty)
        #expect(ContextCardModel.make(block: SessionContextBlock(line: nil, earlier: []), thread: nil).isEmpty)
    }

    // MARK: Decision card after an update (HAIL-108 follow-up)

    @Test func theDecisionCardTitleIsPlain() {
        #expect(DecisionSectionView.title() == "Decision")
    }

    // MARK: Ask for more detail (HAIL-111)

    @MainActor @Test func theDetailPanelOffersFiveQuickAsks() {
        #expect(ComposerViewModel.detailChips == [
            "Explain how the code behind this decision works.", "Explain the trade-offs", "Show me a prototype", "Show the numbers", "Give me an example",
        ])
    }

    @Test func theOptionsCardDropsTheButtonFromThePromptBar() {
        #expect(PromptBarLogic.quietLabels(hasOpenReview: false, hasDetail: false).isEmpty)
        #expect(PromptBarLogic.quietLabels(hasOpenReview: true, hasDetail: false) == ["Open review"])
        #expect(PromptBarLogic.quietLabels(hasOpenReview: false) == ["Ask for more detail"])
    }
}
