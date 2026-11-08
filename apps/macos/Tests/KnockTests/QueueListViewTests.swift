import Testing
import Foundation
@testable import Knock

/// `QueueListView.grouped` (HAIL-33 amendment: "a follow-up sits directly
/// under its earlier ask ... when both are visible") - pure and
/// unit-testable without hosting the view, the same pattern
/// `CasePaneDetailView.footerKind` uses.
struct QueueListViewTests {
    private func makeCase(id: String, createdAt: String, followsCaseId: String? = nil) -> Case {
        Case(
            id: id, taskId: "t_1", kind: .question, title: "Title \(id)",
            need: "Need", why: "Why", recommendation: "R", recommendationWhy: "Because",
            options: [], status: .needsYou, hasArtifact: false, followsCaseId: followsCaseId,
            createdAt: createdAt, updatedAt: createdAt
        )
    }

    @Test func groupsTheFollowUpRightAfterItsParentRegardlessOfInputOrder() {
        let earlier = makeCase(id: "c1", createdAt: "2026-09-26T10:00:00Z")
        let unrelated = makeCase(id: "c2", createdAt: "2026-09-26T10:05:00Z")
        let followUp = makeCase(id: "c3", createdAt: "2026-09-26T10:10:00Z", followsCaseId: "c1")

        // Newest-first input, as AppModel produces it: c3, c2, c1.
        let grouped = QueueListView.grouped([followUp, unrelated, earlier])

        #expect(grouped.map(\.item.id) == ["c2", "c1", "c3"])
        #expect(grouped.map(\.isFollowUp) == [false, false, true])
    }

    @Test func aFollowUpWhoseEarlierAskIsNotInThisListStaysUngroupedInItsOwnPosition() {
        let unrelated = makeCase(id: "c2", createdAt: "2026-09-26T10:05:00Z")
        // "c1" (what this follows) is not in this list - already resolved,
        // or sitting in the other queue section.
        let followUp = makeCase(id: "c3", createdAt: "2026-09-26T10:10:00Z", followsCaseId: "c1")

        let grouped = QueueListView.grouped([followUp, unrelated])

        #expect(grouped.map(\.item.id) == ["c3", "c2"])
        #expect(grouped.map(\.isFollowUp) == [false, false], "with no visible parent, the follow-up is not indented")
    }

    @Test func multipleFollowUpsOfTheSameAskAllGroupUnderIt() {
        let earlier = makeCase(id: "c1", createdAt: "2026-09-26T10:00:00Z")
        let followUpA = makeCase(id: "c2", createdAt: "2026-09-26T10:05:00Z", followsCaseId: "c1")
        let followUpB = makeCase(id: "c3", createdAt: "2026-09-26T10:10:00Z", followsCaseId: "c1")

        let grouped = QueueListView.grouped([followUpB, followUpA, earlier])

        #expect(grouped.map(\.item.id) == ["c1", "c3", "c2"])
        #expect(grouped.map(\.isFollowUp) == [false, true, true])
    }

    @Test func anEmptyListStaysEmpty() {
        #expect(QueueListView.grouped([]).isEmpty)
    }

    /// HAIL-120: a follow-up of a follow-up used to vanish from the queue (its parent was
    /// itself a child, so nobody drew it). Every ask must show exactly once.
    @Test func aFollowUpOfAFollowUpStillShowsUnderItsParent() {
        let first = makeCase(id: "c1", createdAt: "2026-09-26T10:00:00Z")
        let second = makeCase(id: "c2", createdAt: "2026-09-26T10:05:00Z", followsCaseId: "c1")
        let third = makeCase(id: "c3", createdAt: "2026-09-26T10:10:00Z", followsCaseId: "c2")

        let grouped = QueueListView.grouped([third, second, first])

        #expect(grouped.map(\.item.id) == ["c1", "c2", "c3"])
        #expect(grouped.map(\.isFollowUp) == [false, true, true])
    }

    @Test func aFollowUpCycleOrASelfFollowNeverHidesAnAsk() {
        let a = makeCase(id: "c1", createdAt: "2026-09-26T10:00:00Z", followsCaseId: "c2")
        let b = makeCase(id: "c2", createdAt: "2026-09-26T10:05:00Z", followsCaseId: "c1")
        let own = makeCase(id: "c3", createdAt: "2026-09-26T10:10:00Z", followsCaseId: "c3")

        let grouped = QueueListView.grouped([own, b, a])

        #expect(Set(grouped.map(\.item.id)) == ["c1", "c2", "c3"])
        #expect(grouped.count == 3)
    }

    @Test func everyAskShowsExactlyOnceWhateverItFollows() {
        let ids = ["c1", "c2", "c3", "c4", "c5"]
        for shift in 0..<ids.count {
            let cases = ids.enumerated().map { index, id in
                makeCase(
                    id: id, createdAt: "2026-09-26T10:0\(index):00Z",
                    followsCaseId: ids[(index + shift) % ids.count])
            }
            let grouped = QueueListView.grouped(cases)
            #expect(grouped.map(\.item.id).sorted() == ids, "shift \(shift)")
        }
    }
}

/// `QueueListView.rowIdentity`: the row's own `.id()`, which must change the
/// instant a case first moves from `needsYouCases` into `waitingOnAgentCases`
/// (docs/stories/HAIL-36.md amendment 2, operator report: an answered row
/// sat under "Waiting on agent" still showing the pending arrival clock, no
/// "you -> ..." line, no "Waiting for pickup" spinner). Reproduced against a
/// real daemon and a real `reply.submit` (`HAIL36ReproScratchTests`, not
/// committed): `AppModel.refreshCases()` itself always returns fresh,
/// fully-consistent data the instant a `case.updated`/`reply.state_changed`
/// event fires - the daemon writes the status flip and the reply in one
/// transaction, so `cases.list` can never see one without the other. The
/// staleness is a SwiftUI `LazyVStack` identity-reuse issue instead: a fresh
/// reply's `deliveryStatus` reads `nil` right up to and right after that
/// transition (a queued reply is not yet a delivered/failed outcome), so the
/// existing `badgeIdentity`-only `.id()` (KNOCK-13 fold) does not change
/// across it, and `LazyVStack` can go on reusing the pre-reply row it first
/// appeared with - this is the same staleness class KNOCK-13 fold already
/// fixed for a LATER delivered/failed transition, just one step earlier.
struct QueueRowIdentityTests {
    @Test @MainActor func changesWhenACaseFirstMovesFromNeedsYouToWaitingOnAgent() {
        let beforeReply = QueueListView.rowIdentity(caseId: "c_1", status: .needsYou, deliveryStatus: nil)
        let justAfterReply = QueueListView.rowIdentity(caseId: "c_1", status: .waitingOnAgent, deliveryStatus: nil)

        #expect(
            beforeReply != justAfterReply,
            "a freshly-queued reply carries the same nil deliveryStatus on both sides of the status flip - the row's `.id()` must still change, or LazyVStack can reuse the pre-reply layout"
        )
    }

    @Test @MainActor func stillChangesOnceDeliveryStatusItselfLaterChanges() {
        let queued = QueueListView.rowIdentity(caseId: "c_1", status: .waitingOnAgent, deliveryStatus: nil)
        let delivered = QueueListView.rowIdentity(caseId: "c_1", status: .waitingOnAgent, deliveryStatus: .delivered(at: Date()))

        #expect(queued != delivered, "the existing KNOCK-13 fold discriminator must still work")
    }

    @Test @MainActor func isStableForAnUnrelatedRerenderOfAnAlreadyWaitingRow() {
        let a = QueueListView.rowIdentity(caseId: "c_1", status: .waitingOnAgent, deliveryStatus: nil)
        let b = QueueListView.rowIdentity(caseId: "c_1", status: .waitingOnAgent, deliveryStatus: nil)

        #expect(a == b, "an unrelated re-render (the same case, still waiting, no delivery outcome) must not reset row identity")
    }
}
