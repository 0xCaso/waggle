import Foundation
import Testing
@testable import Knock

/// WAG-382: every case with more than one round shows the current round, and names that differ only by a
/// version word are one artifact.
@MainActor
struct WAG382Tests {
    private func rev(_ n: Int, _ name: String?, round: Int?, kind: ArtifactKind = .screenshot) -> Revision {
        Revision(
            id: "r\(n)", caseId: "c1", n: n, createdAt: "2026-10-10T10:00:00Z", author: .agent, baseRevision: nil,
            name: name, kind: kind, round: round)
    }

    private func detail(_ revisions: [Revision]) -> CaseDetail {
        let c = Case(
            id: "c1", taskId: "t1", kind: .question, title: "T", need: "N", why: "W", recommendation: "",
            recommendationWhy: "", options: [], status: .needsYou, hasArtifact: true,
            createdAt: "2026-10-10T10:00:00Z", updatedAt: "2026-10-10T10:00:00Z")
        return CaseDetail(
            case: c, task: KnockTask(id: "t1", name: "n", project: "p"), messages: [], revisions: revisions,
            comments: [], replies: [])
    }

    @Test func versionWordsFoldIntoOneName() {
        for name in ["Slide 6 A", "Slide 6 A v2", "Slide 6 A v3", "Slide 6 A (v4)", "Slide 6 A rev 2", "Slide 6 A version 5", "Slide 6 A V2"] {
            #expect(ArtifactTabs.folded(name) == "Slide 6 A")
        }
        for name in ["Slide 6", "Step 2", "Option B2", "v2"] { #expect(ArtifactTabs.folded(name) == name) }
    }

    @Test func theRealCaseShowsOneTabWithItsHistory() {
        let d = detail([
            rev(1, "Slide 6 versions", round: 0, kind: .screenshots), rev(2, "Slide 6 A v2", round: 1),
            rev(3, "Slide 6 A v3", round: 2),
        ])
        let tabs = d.artifactTabs()
        #expect(tabs.map(\.title) == ["Slide 6 A"])
        #expect(tabs.first?.revision == 3 && tabs.first?.revisions == [2, 3])
        // An older revision keeps the tabs of its own round.
        #expect(d.artifactTabs(viewing: 1).map(\.title) == ["Slide 6 versions"])
    }

    @Test func oneRoundAndTwoArtifactsInARoundKeepEveryTab() {
        let one = detail([rev(1, "A", round: 0), rev(2, "B", round: 0)])
        #expect(one.artifactTabs().map(\.title) == ["A", "B"])
        let two = detail([rev(1, "Old", round: 0), rev(2, "A", round: 1), rev(3, "B", round: 1)])
        #expect(two.artifactTabs().map(\.title) == ["A", "B"])
    }

    @Test func anArtifactRefFindsTheFoldedName() {
        let tabs = ArtifactTabs.tabs(revisions: [rev(1, "Slide 6 A v2", round: 0), rev(2, "Slide 6 A v3", round: 1)])
        #expect(tabs.count == 1)
        for ref in ["Slide 6 A v3", "Slide 6 A", "slide 6 a V9"] {
            let link = ArtifactTabs.link(for: Option(id: "a", label: "A", artifactRef: ref), in: tabs, current: nil)
            #expect(link?.tabId == tabs[0].id)
        }
    }
}
