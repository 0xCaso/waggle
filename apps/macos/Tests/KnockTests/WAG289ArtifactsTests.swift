import Foundation
import Testing
@testable import Knock

/// WAG-289: clicking between the artifacts of a decision never loses one. A write-up, three pages and
/// some versions: every artifact stays a tab and a card in any click order.
@MainActor
struct WAG289ArtifactsTests {
    private func revision(_ n: Int, _ name: String, _ kind: ArtifactKind = .htmlBundle) -> Revision {
        Revision(
            id: "r\(n)", caseId: "c1", n: n, createdAt: "2026-10-07T10:00:00Z", author: .agent, baseRevision: nil,
            name: name, kind: kind)
    }

    private var revisions: [Revision] {
        [
            revision(1, "Background write-up", .markdown), revision(2, "Flow A"), revision(3, "Flow B"),
            revision(4, "Flow C"), revision(5, "Flow A"), revision(6, "Flow C"),
        ]
    }

    private let titles = ["Background write-up", "Flow A", "Flow B", "Flow C"]

    private func model(_ revisions: [Revision]) -> LiveArtifactModel {
        LiveArtifactModel(
            caseId: "c1", client: KnockClient(socketPath: "/nonexistent.sock", startDaemon: {}),
            tabs: ArtifactTabs.tabs(revisions: revisions))
    }

    private func option(_ id: String, ref: String?) throws -> Option {
        let json = #"{"id":"\#(id)","label":"L","artifact_ref":\#(ref.map { "\"\($0)\"" } ?? "null")}"#
        return try JSONDecoder().decode(Option.self, from: Data(json.utf8))
    }

    private func item(kind: ArtifactKind = .htmlBundle) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Pick", need: "Need", why: "Why", recommendation: "",
            recommendationWhy: "", options: [], status: .needsYou, hasArtifact: true,
            createdAt: "2026-10-07T10:00:00Z", updatedAt: "2026-10-07T10:00:00Z", artifactKind: kind)
    }

    @Test func everyArtifactStaysATabInAnyClickOrder() throws {
        let m = model(revisions)
        #expect(m.tabs.map(\.title) == titles)
        #expect(m.tabs.map(\.revision) == [1, 5, 3, 6])
        let ids = m.tabs.map(\.id)
        for id in ids + ids.reversed() + [ids[2], ids[0], ids[3], ids[1], ids[1], ids[0]] {
            m.select(id)
            #expect(m.selectedTab?.id == id)
            #expect(m.tabs.map(\.title) == titles)
        }
        m.apply(ArtifactTabs.link(for: try option("a", ref: "flow b"), in: m.tabs, current: m.selectedTab?.id))
        #expect(m.selectedTab?.title == "Flow B")
        #expect(m.follow(option: try option("b", ref: "Background write-up")))
        #expect(m.selectedTab?.title == "Background write-up")
        #expect(!m.follow(option: try option("c", ref: "nothing")))
        #expect(m.selectedTab?.title == "Background write-up")
        #expect(m.tabs.map(\.title) == titles)
    }

    @Test func aNewRoundKeepsEveryTabAndBringsTheNewestToFront() {
        let m = model(revisions)
        m.select(m.tabs[0].id)
        m.update(tabs: ArtifactTabs.tabs(revisions: revisions + [revision(7, "Flow B")]))
        #expect(m.tabs.map(\.title) == titles)
        #expect(m.selectedTab?.title == "Flow B" && m.selectedTab?.revision == 7)
        // A tab that stays: the one on show stays.
        m.select(m.tabs[1].id)
        m.update(tabs: ArtifactTabs.tabs(revisions: revisions + [revision(7, "Flow B")]))
        #expect(m.selectedTab?.title == "Flow A")
    }

    @Test func aSelectedTabThatNoLongerExistsFallsToTheFirst() {
        let m = model(revisions)
        m.select(m.tabs[0].id)
        m.update(tabs: ArtifactTabs.tabs(revisions: Array(revisions.dropFirst())))
        // WAG-351: the first tab of the new set.
        #expect(m.selectedTab?.title == "Flow A")
    }

    @Test func eachArtifactIsACardThatOpensItsOwnRevision() throws {
        let m = model(revisions)
        let cards = ArtifactCardModel.cards(for: item(), revision: 6, tabs: m.tabs)
        #expect(cards.map(\.name) == titles)
        #expect(cards.map(\.revision) == [1, 5, 3, 6])
        #expect(cards[0].type == .writeUp && cards[1].type == .prototype)
        #expect(Set(cards.map(\.id)).count == 4)
    }

    @Test func oneArtifactKeepsTheOneCard() {
        let m = model([revision(1, "Flow A"), revision(2, "Flow A")])
        let cards = ArtifactCardModel.cards(for: item(), revision: 2, tabs: m.tabs)
        #expect(cards.count == 1 && cards[0].revision == 2 && cards[0].name == "Prototype")
    }
}
