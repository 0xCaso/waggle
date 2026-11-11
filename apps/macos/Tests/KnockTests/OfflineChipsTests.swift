import Testing
import Foundation
@testable import Knock

struct OfflineChipsTests {
    private func makeCase(kind: Case.Kind, status: CaseStatus, runtime: Runtime = .claude) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: kind, title: "Title",
            need: "Need", why: "Why", recommendation: "R",
            recommendationWhy: "Because", options: [], status: status,
            hasArtifact: false, runtime: runtime,
            createdAt: "2026-09-26T10:00:00.000Z", updatedAt: "2026-09-26T10:00:00.000Z"
        )
    }

    @Test func aWaitingReviewShowsKindStatusAndClient() {
        let item = makeCase(kind: .review, status: .needsYou)
        #expect(OfflineChips.labels(for: item) == ["Review", "Needs you", item.runtimeLabel])
    }

    @Test func aQuestionIsNotCalledReviewAndAnAnsweredOneIsNotCalledBlocking() {
        let item = makeCase(kind: .question, status: .waitingOnAgent)
        let labels = OfflineChips.labels(for: item)
        #expect(labels.first == "Decision")
        #expect(labels[1] == "Answered")
        #expect(!labels.contains("Blocking"))
    }

    @Test func aResolvedRequestSaysDone() {
        #expect(OfflineChips.status(.resolved) == "Done")
    }
}
