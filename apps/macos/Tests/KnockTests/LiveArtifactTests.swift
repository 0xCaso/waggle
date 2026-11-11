import Foundation
import Testing
@testable import Knock

/// WAG-276: the live artifact on the decision page, tabs, option links, the panel and the plan page.
struct LiveArtifactTests {
    private func revision(
        _ n: Int, name: String? = nil, kind: ArtifactKind? = .htmlBundle, author: Revision.Author = .agent, base: Int? = nil
    ) -> Revision {
        Revision(
            id: "r\(n)", caseId: "c1", n: n, createdAt: "2026-10-07T10:00:00Z", author: author, baseRevision: base,
            name: name, kind: kind)
    }

    private func decoded<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func makeCase(options: [Option] = [], plan: PlanInfo? = nil, why: String = "Why") -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Pick one", need: "Need", why: why,
            recommendation: options.first?.id ?? "", recommendationWhy: "Because", options: options,
            status: .needsYou, hasArtifact: true,
            createdAt: "2026-10-07T10:00:00Z", updatedAt: "2026-10-07T10:00:00Z", plan: plan)
    }

    // MARK: protocol

    @Test func anOptionCarriesProsConsAndALink() throws {
        let option = try decoded(
            Option.self,
            #"{"id":"a","label":"Cards","pros":["Easy to scan"],"cons":["Takes room"],"artifact_ref":"Flow","anchor":"cards"}"#)
        #expect(option.pros == ["Easy to scan"])
        #expect(option.cons == ["Takes room"])
        #expect(option.artifactRef == "Flow")
        #expect(option.anchor == "cards")
        #expect(option.hasPoints)
    }

    @Test func anOldOptionStillDecodesAndRoundTrips() throws {
        let option = try decoded(Option.self, #"{"id":"a","label":"Cards"}"#)
        #expect(option.pros.isEmpty && option.cons.isEmpty && option.artifactRef == nil && option.anchor == nil)
        #expect(!option.hasPoints)
        let again = try JSONDecoder().decode(Option.self, from: JSONEncoder().encode(option))
        #expect(again == option)
    }

    @Test func aRevisionCarriesNameAndKind() throws {
        let named = try decoded(
            Revision.self, #"{"id":"r1","case_id":"c1","n":1,"created_at":"x","author":"agent","name":"Flow","kind":"diagram"}"#)
        #expect(named.name == "Flow" && named.kind == .diagram)
        let old = try decoded(Revision.self, #"{"id":"r1","case_id":"c1","n":1,"created_at":"x"}"#)
        #expect(old.name == nil && old.kind == nil)
    }

    // MARK: tabs

    @Test func revisionsOfOneArtifactAreOneTabShowingTheNewest() {
        let tabs = ArtifactTabs.tabs(revisions: [revision(1), revision(2), revision(3)])
        #expect(tabs.count == 1)
        #expect(tabs[0].revision == 3 && tabs[0].title == "Prototype")
    }

    @Test func eachNameAndEachUnnamedKindIsATab() {
        let tabs = ArtifactTabs.tabs(revisions: [
            revision(1, name: "Variants"), revision(2, name: "Flow", kind: .diagram), revision(3, kind: .markdown),
            revision(4, name: "variants"),
        ])
        #expect(tabs.map(\.title) == ["variants", "Flow", "Write-up"])
        #expect(tabs.map(\.revision) == [4, 2, 3])
    }

    @Test func aRevisionYouSavedJoinsTheArtifactItStartedFrom() {
        let tabs = ArtifactTabs.tabs(revisions: [
            revision(1, name: "Notes", kind: .markdown), revision(2, kind: .markdown, author: .you, base: 1),
        ])
        #expect(tabs.count == 1 && tabs[0].title == "Notes" && tabs[0].revision == 2)
    }

    @Test func aDaemonWithNoKindStillGivesOneTab() {
        let tabs = ArtifactTabs.tabs(revisions: [revision(1, kind: nil), revision(2, kind: nil)])
        #expect(tabs.count == 1 && tabs[0].title == "Artifact")
    }

    // MARK: live replaces the preview

    @Test func theLivePageScalesDownToTheBoxAndNeverUp() {
        let wide = ViewportSize(width: 1280, height: 800)
        #expect(LiveArtifactGeometry.scale(boxWidth: 640, viewport: wide) == 0.5)
        #expect(LiveArtifactGeometry.scale(boxWidth: 2000, viewport: wide) == 1)
        #expect(LiveArtifactGeometry.scale(boxWidth: 640, viewport: nil) == 1)
        #expect(LiveArtifactGeometry.height(boxWidth: 640, viewport: wide) == 400)
        #expect(LiveArtifactGeometry.height(boxWidth: 640, viewport: nil) == LiveArtifactGeometry.defaultHeight)
        #expect(LiveArtifactGeometry.height(boxWidth: 640, viewport: ViewportSize(width: 390, height: 2000)) == LiveArtifactGeometry.maxHeight)
    }

    // MARK: option links

    private var tabs: [ArtifactTab] {
        ArtifactTabs.tabs(revisions: [revision(1, name: "Variants"), revision(2, name: "Notes", kind: .markdown)])
    }

    @Test func anOptionLinksToATabByNameIgnoringCase() {
        let option = Option(id: "b", label: "B", artifactRef: " notes ", anchor: nil)
        let link = ArtifactTabs.link(for: option, in: tabs, current: "name:variants")
        #expect(link == ArtifactLink(tabId: "name:notes", anchor: nil))
    }

    @Test func anAnchorWithNoArtifactStaysOnTheTabOnShow() {
        let link = ArtifactTabs.link(for: Option(id: "a", label: "A", anchor: "cards"), in: tabs, current: "name:variants")
        #expect(link == ArtifactLink(tabId: "name:variants", anchor: "cards"))
    }

    @Test func anOptionWithNoLinkOrAnUnknownNameLinksToNothing() {
        #expect(ArtifactTabs.link(for: Option(id: "a", label: "A"), in: tabs, current: nil) == nil)
        #expect(ArtifactTabs.link(for: Option(id: "a", label: "A", artifactRef: "Nope"), in: tabs, current: nil) == nil)
        #expect(ArtifactTabs.link(for: nil, in: tabs, current: nil) == nil)
    }

    @Test func theAnchorMessageIsPostedIntoThePageAndTheAnchorIsQuoted() {
        let script = ArtifactTabs.anchorScript(#"a"b</script>"#)
        #expect(script.contains(#"window.postMessage({type:"waggle:anchor",anchor:a},"*")"#))
        #expect(script.contains(#"("a\"b<\/script>")"#) || script.contains(#"("a\"b</script>")"#))
        #expect(script.contains("data-waggle-anchor"))
        #expect(!script.contains("fetch(") && !script.contains("XMLHttpRequest"))
    }

    @MainActor @Test func selectingALinkedOptionSwitchesTheTabAndAsksForTheAnchor() async {
        let model = LiveArtifactModel(caseId: "c1", client: KnockClient(socketPath: "/nonexistent.sock", startDaemon: {}), tabs: tabs)
        #expect(model.selectedTab?.title == "Notes")
        model.apply(ArtifactLink(tabId: "name:variants", anchor: "cards"))
        #expect(model.selectedTab?.title == "Variants")
        #expect(model.anchorRequest?.anchor == "cards")
        let first = model.anchorRequest?.token
        model.apply(ArtifactLink(tabId: "name:variants", anchor: "cards"))
        #expect(model.anchorRequest?.token != first)
        model.apply(ArtifactLink(tabId: "name:missing", anchor: nil))
        #expect(model.selectedTab?.title == "Variants")
    }

    // MARK: the panel

    @Test func thePanelHoldsTheDocAndNeverListsTheOptions() {
        let options = [
            Option(id: "a", label: "Cards", title: "Cards", pros: ["Easy"], cons: ["Roomy"]),
            Option(id: "b", label: "Table", title: "Table"),
        ]
        let item = makeCase(options: options)
        #expect(AskPanelLayout.parts(for: item, picked: options[0]) == [.crumb, .title, .need, .why, .pickedPoints])
        #expect(AskPanelLayout.parts(for: item, picked: options[1]) == [.crumb, .title, .need, .why, .pickedPoints])
        #expect(AskPanelLayout.parts(for: item, picked: nil, hasCrumb: false) == [.title, .need, .why])
        #expect(AskPanelLayout.optionsPlaces(for: item) == [.bottomBar])
        #expect(AskPanelLayout.pickLabel(options[0], position: 1) == "YOUR PICK · 1 CARDS")
    }

    // MARK: the plan page

    @Test func anyAskWithAnArtifactPutsItBesideTheColumnOnAWideWindow() {
        #expect(AskLayout.layout(width: 1400, hasArtifact: true) == .beside)
        #expect(AskLayout.layout(width: 1000, hasArtifact: true) == .beside)
        // Under 440 + 480 pt the artifact folds to the pinned bar.
        #expect(AskLayout.layout(width: 919, hasArtifact: true) == .folded)
        #expect(AskLayout.layout(width: 800, hasArtifact: true) == .folded)
    }

    @Test func anAskWithoutAnArtifactIsTheColumnAlone() {
        #expect(AskLayout.layout(width: 1600, hasArtifact: false) == .page)
    }

    @Test func theFoldedRowNamesThePlanWriteUpOrTheArtifact() {
        let page = ArtifactTabs.tabs(revisions: [revision(1, kind: .htmlBundle)])
        let shot = ArtifactTabs.tabs(revisions: [revision(1, kind: .screenshot)])
        let diagram = ArtifactTabs.tabs(revisions: [revision(1, kind: .diagram)])
        #expect(AskLayout.foldTitle(page.first) == "Prototype")
        #expect(AskLayout.foldTitle(shot.first) == "Screenshot")
        #expect(AskLayout.foldTitle(diagram.first) == "Diagram")
    }

    @Test func anAnsweredAskKeepsItsRowsLockedWithThePickMarked() {
        let sent = ComposerCardView.answeredRows(isLocked: false, deliveryIdle: false, yourAnswerOptionId: nil, selectedOptionId: "b")
        #expect(sent.locked && sent.pickedId == "b")
        let answered = ComposerCardView.answeredRows(isLocked: true, deliveryIdle: true, yourAnswerOptionId: "a", selectedOptionId: "b")
        #expect(answered.locked && answered.pickedId == "a")
        let open = ComposerCardView.answeredRows(isLocked: false, deliveryIdle: true, yourAnswerOptionId: nil, selectedOptionId: "b")
        #expect(!open.locked)
    }

    @Test func theWriteUpRowNamesWhatItHolds() {
        #expect(AskLayout.writeUpTitle(nil) == "Background write-up")
        let notes = ArtifactTabs.tabs(revisions: [revision(1, kind: .markdown)])
        #expect(AskLayout.writeUpTitle(notes.first) == "Background write-up")
        let page = ArtifactTabs.tabs(revisions: [revision(1)])
        #expect(AskLayout.writeUpTitle(page.first) == "Background prototype")
    }

    @Test func noNewCopyHasAnEmDash() {
        let copy = [
            AskLayout.writeUpTitle(nil), AskPanelLayout.pickLabel(Option(id: "a", label: "A"), position: 1),
            ArtifactTabs.defaultTitle(.htmlBundle), ArtifactTabs.defaultTitle(.markdown),
        ]
        #expect(copy.allSatisfy { !$0.contains("—") })
    }
}
