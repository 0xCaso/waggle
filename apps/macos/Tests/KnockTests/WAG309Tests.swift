import Foundation
import Testing
@testable import Knock

/// WAG-309: full size has the artifact tabs, one version label, the Open menu and the crumb in the column.
@MainActor
struct WAG309Tests {
    private func revision(
        _ n: Int, name: String? = nil, kind: ArtifactKind? = .htmlBundle, author: Revision.Author = .agent, base: Int? = nil
    ) -> Revision {
        Revision(
            id: "r\(n)", caseId: "c1", n: n, createdAt: "2026-10-07T10:00:00Z", author: author, baseRevision: base,
            name: name, kind: kind)
    }

    private var plan: [Revision] {
        [
            revision(1, name: "Write-up", kind: .markdown),
            revision(2, name: "Prototype", kind: .htmlBundle),
            revision(3, name: "Screens", kind: .screenshots),
            revision(4, name: "Write-up", kind: .markdown),
        ]
    }

    @Test func tabSwitchFollowsTheRevisionOnShow() {
        let tabs = ArtifactTabs.tabs(revisions: plan)
        #expect(tabs.map(\.title) == ["Write-up", "Prototype", "Screens"])
        // Full size shows the newest revision of the second tab: that tab is on.
        let second = tabs[1]
        #expect(ArtifactTabs.tabId(showing: second.revision, revisions: plan) == second.id)
        // An older revision of the write-up still lights the write-up tab.
        #expect(ArtifactTabs.tabId(showing: 1, revisions: plan) == tabs[0].id)
        #expect(ArtifactTabs.tabId(showing: 4, revisions: plan) == tabs[0].id)
        #expect(ArtifactTabs.tabId(showing: nil, revisions: plan) == nil)
        #expect(ArtifactTabs.tabId(showing: 9, revisions: plan) == nil)
    }

    @Test func aSavedEditStaysOnTheTabItStartedFrom() {
        let revisions = plan + [revision(5, kind: .markdown, author: .you, base: 4)]
        let tabs = ArtifactTabs.tabs(revisions: revisions)
        #expect(tabs.count == 3)
        #expect(ArtifactTabs.tabId(showing: 5, revisions: revisions) == tabs[0].id)
    }

    @Test func versionShowsOnceAndTheCapturePositionStaysOutOfIt() {
        #expect(ArtifactVersionLabel.chrome(title: "Screenshots", revision: 8) == "Screenshots · v8")
        #expect(!ArtifactVersionLabel.chrome(title: "Screenshots", revision: 8).contains("/"))
    }

    @Test func theHeaderNamesTheVersionOnce() {
        // The latest version: the version only, or the name and the version when no tab names the artifact.
        #expect(ArtifactVersionLabel.header(title: nil, revision: 3, latest: nil) == "v3")
        #expect(ArtifactVersionLabel.header(title: "Prototype", revision: 3, latest: nil) == "Prototype · v3")
        // An older version: one quiet marker, "v2 of 3".
        #expect(ArtifactVersionLabel.header(title: nil, revision: 2, latest: 3) == "v2 of 3")
        #expect(ArtifactVersionLabel.header(title: "Prototype", revision: 2, latest: 3) == "Prototype · v2 of 3")
        // The newest version, or an unknown newest one, adds no "of".
        #expect(ArtifactVersionLabel.header(title: nil, revision: 3, latest: 3) == "v3")
        #expect(ArtifactVersionLabel.header(title: nil, revision: 4, latest: 3) == "v4")
        // The word "latest" and "arrived" never show: no chip or banner repeats the version.
        for text in [(nil, 3, nil), ("Prototype", 2, 3)] as [(String?, Int, Int?)] {
            let label = ArtifactVersionLabel.header(title: text.0, revision: text.1, latest: text.2)
            #expect(!label.contains("latest") && !label.contains("arrived"))
        }
    }

    @Test func aCaptureOfTheSameVersionAddsNoVersionWords() {
        #expect(ArtifactVersionLabel.captureOrigin(captureRevision: 8, artifactRevision: 8) == nil)
        #expect(ArtifactVersionLabel.captureChip(n: 1, captureRevision: 8, artifactRevision: 8, time: "14:02") == "Capture 1 · 14:02")
    }

    @Test func anOlderCaptureSaysFromInPlainWords() {
        #expect(ArtifactVersionLabel.captureOrigin(captureRevision: 7, artifactRevision: 8) == "from v7")
        #expect(ArtifactVersionLabel.captureChip(n: 1, captureRevision: 7, artifactRevision: 8, time: "14:02") == "Capture 1 · from v7 · 14:02")
    }

    @Test func aVersionThatArrivesOnThePageIsMarkedNew() {
        typealias A = ArtifactVersionLabel.Arrivals
        #expect(ArtifactVersionLabel.newMark(from: A(caseId: "c1", count: 2), to: A(caseId: "c1", count: 3), latest: 3) == 3)
        // The first load, another request, and a tab or older-version switch show no mark.
        #expect(ArtifactVersionLabel.newMark(from: A(caseId: nil, count: 0), to: A(caseId: "c1", count: 3), latest: 3) == nil)
        #expect(ArtifactVersionLabel.newMark(from: A(caseId: "c1", count: 0), to: A(caseId: "c1", count: 1), latest: 1) == nil)
        #expect(ArtifactVersionLabel.newMark(from: A(caseId: "c1", count: 2), to: A(caseId: "c2", count: 3), latest: 3) == nil)
        #expect(ArtifactVersionLabel.newMark(from: A(caseId: "c1", count: 3), to: A(caseId: "c1", count: 3), latest: 3) == nil)
    }

    @Test func fullSizeOpenMenuHasWindowAndBrowserButNoFullSize() {
        #expect(ArtifactFullSizeOpenMenu.items(kind: .htmlBundle, hasWindow: true, hasBrowser: true) == [.window, .browser])
        #expect(ArtifactFullSizeOpenMenu.items(kind: .markdown, hasWindow: true, hasBrowser: true) == [.window])
        #expect(ArtifactFullSizeOpenMenu.items(kind: .htmlBundle, hasWindow: false, hasBrowser: false).isEmpty)
    }

    @Test func crumbSitsOverTheTitleNotInTheTitlebar() {
        let task = KnockTask(id: "t", name: "share-link-9a8b7c6d", project: "Gym OS")
        #expect(ReviewTitlebarView.crumbText(task: task, sessionTitle: "Share link settings") == "Gym OS · Share link settings")
        // The ask column shows the crumb line as its first part for an ask with a title.
        let item = Case(
            id: "c1", taskId: "t1", kind: .question, title: "Pick one", need: "Need", why: "Why",
            recommendation: "", recommendationWhy: "", options: [], status: .needsYou, hasArtifact: true,
            createdAt: "2026-10-07T10:00:00Z", updatedAt: "2026-10-07T10:00:00Z")
        #expect(AskPanelLayout.parts(for: item, picked: nil).prefix(2) == [.crumb, .title])
    }
}
