import Testing

@testable import Knock

/// WAG-294: the need box reads as a question plus details, and keeps safe markdown.
struct NeedTextTests {
    @Test func theFirstParagraphIsTheQuestionAndTheRestAreDetails() {
        let parts = NeedText.split("Which day is **Today**?\n\nIt sits at the end of the path.\n\n- Mon\n- Tue")
        #expect(parts.question == "Which day is **Today**?")
        #expect(parts.details == "It sits at the end of the path.\n\n- Mon\n- Tue")
    }

    @Test func aOneParagraphNeedHasNoDetails() {
        #expect(NeedText.split("Pick a layout.") == .init(question: "Pick a layout.", details: nil))
    }

    @Test func aNeedThatOpensWithAListHasNoQuestion() {
        #expect(NeedText.split("- one\n- two") == .init(question: "", details: "- one\n- two"))
    }

    @Test func theSectionPrefixGoesWhenTheLabelSaysIt() {
        let label = "Design · section 3 of 3"
        #expect(NeedText.split("Section 3 of 3: Which day is Today?", labelAbove: label).question == "Which day is Today?")
        #expect(NeedText.split("**Section 3 of 3:** Which day?", labelAbove: label).question == "Which day?")
        #expect(NeedText.split("**Section 3 of 3: Which day?**", labelAbove: label).question == "**Which day?**")
        #expect(NeedText.split("Question 2 of ~5 - Who reads it?", labelAbove: "QUESTION 2 OF ~5").question == "Who reads it?")
    }

    @Test func theSectionPrefixStaysWhenTheLabelDoesNotSayIt() {
        #expect(NeedText.split("Section 2 of 3: Which day?", labelAbove: "Design · section 3 of 3").question == "Section 2 of 3: Which day?")
        #expect(NeedText.split("Section 3 of 3: Which day?", labelAbove: nil).question == "Section 3 of 3: Which day?")
    }

    @Test func markdownSurvivesAndRowsStayPlain() {
        let need = "Which **day** is `Today`?\n\nSome *detail* here."
        let parts = NeedText.split(need)
        #expect(AgentMarkdown.blocks(parts.question) == [.paragraph("Which **day** is `Today`?")])
        #expect(AgentMarkdown.singleLine(need) == "Which day is Today? Some detail here.")
    }

    @Test func aPlanRoundKeepsItsMessageWhole() {
        let message = "Section 3 of 3: Today.\n\nFirst **bold** detail.\n\nSecond detail."
        let stage = PlanStage(name: .design, step: 3, total: 3)
        let c = Case(
            id: "c", taskId: "t", kind: .question, title: "T", need: "first", why: "w", recommendation: "a", recommendationWhy: "r",
            options: [Option(id: "a", label: "A")], status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-07T09:00:00Z", updatedAt: "2026-10-07T09:00:00Z",
            plan: PlanInfo(stage: stage, rounds: 1, answered: 0))
        let round = PlanRound(seq: 0, stage: stage, question: message, options: [], recommendation: "", createdAt: "2026-10-07T09:00:00Z")
        #expect(c.currentNeed(planRounds: [round]) == message)
    }
}
