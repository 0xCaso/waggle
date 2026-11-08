import Foundation
import Testing
@testable import Knock

/// HAIL-174: an update with new options leads with its question.
struct RoundHeadingTests {
    private let message = "Which of the five assumptions are correct?\n\nI kept your change to 24 hours.\n\nTick each assumption that is correct."

    private func make(seq: Int = 1, question: String? = nil, message: String? = nil, answer: String? = "Approve") -> RoundHeading? {
        RoundHeading.make(seq: seq, question: question, message: message ?? self.message, originalTitle: "Brief: approve or change?", answer: answer)
    }

    private func makeCase(seq: Int, question: String?, status: CaseStatus = .needsYou, plan: PlanInfo? = nil) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "Brief: approve or change?", need: "Need", why: "Why",
            recommendation: "a", recommendationWhy: "Because",
            options: [Option(id: "a", label: "Approve it", title: "Approve")], status: status, hasArtifact: false,
            latestReplyId: "r_1", latestReplyChoice: "a", createdAt: "2026-10-05T10:00:00.000Z",
            updatedAt: "2026-10-05T10:00:00.000Z", plan: plan, optionsSeq: seq, roundQuestion: question)
    }

    @Test func splitsAtTheFirstBlankLine() {
        let heading = make()
        #expect(heading?.title == "Which of the five assumptions are correct?")
        #expect(heading?.tag == "Round 2")
        #expect(heading?.was == "Was: Brief: approve or change? · You answered: Approve")
        #expect(heading?.instruction == "Tick each assumption that is correct.")
    }

    @Test func questionFieldWins() {
        let heading = make(question: "Use the new copy?\n\nDetails here.", message: message)
        #expect(heading?.title == "Use the new copy?")
        #expect(heading?.instruction == nil)
    }

    @Test func singleParagraphStillLeadsTheRound() {
        let heading = make(message: "Where does the intake go in the demo?")
        #expect(heading?.title == "Where does the intake go in the demo?")
        #expect(heading?.need == "Where does the intake go in the demo?")
        #expect(make(seq: 0) == nil)
    }

    @Test func needIsTheDetailsWithoutQuestionAndInstruction() {
        #expect(make()?.need == "I kept your change to 24 hours.")
        #expect(make(message: "Question?\n\nDetail one.\n\nDetail two.\n\nPick one.")?.need == "Detail one.\n\nDetail two.")
        #expect(make(message: "Question?\n\nOnly details.")?.need == "Only details.")
    }

    @Test func noAnswerOmitsTheAnswerPart() {
        #expect(make(answer: nil)?.was == "Was: Brief: approve or change?")
    }

    @Test func cardKeepsOnlyTheDetails() {
        let heading = make()!
        #expect(heading.cardMessage(message) == "I kept your change to 24 hours.")
        #expect(heading.cardMessage("Some other note.\n\nMore.") == "Some other note.\n\nMore.")
    }

    @Test func contextCardModelUsesTheDetailsOnly() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let thread = ThreadModel(
            steps: [.updated(.init(message: message, revision: nil, at: at))], runtimeName: "Claude Code")
        let model = ContextCardModel.make(block: nil, thread: thread, heading: make())
        #expect(model.update?.message == "I kept your change to 24 hours.")
        #expect(ContextCardModel.make(block: nil, thread: thread).update?.message == message)
    }

    @Test func rowFirstLineFollowsTheRule() {
        #expect(makeCase(seq: 1, question: message).rowTitle == "Which of the five assumptions are correct?")
        #expect(makeCase(seq: 0, question: nil).rowTitle == "Brief: approve or change?")
        #expect(makeCase(seq: 1, question: "One paragraph.").rowTitle == "One paragraph.")
        // The newest round keeps its question after you answer it.
        #expect(makeCase(seq: 1, question: message, status: .waitingOnAgent).rowTitle == "Which of the five assumptions are correct?")
        #expect(makeCase(seq: 1, question: message, status: .waitingOnAgent).roundHeading?.was == "Was: Brief: approve or change?")
    }

    @Test func lastAnswerUsesTheOptionTitle() {
        #expect(makeCase(seq: 1, question: message).roundHeading?.was.hasSuffix("You answered: Approve") == true)
    }
}
