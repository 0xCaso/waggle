import AppKit
import Foundation
import Testing
@testable import Knock

/// WAG-352: the artifact box follows the decision on screen.
@MainActor
struct WAG352Tests {
    // MARK: Fixtures

    private func rev(_ n: Int, _ name: String, _ kind: ArtifactKind) -> Revision {
        Revision(
            id: "r\(n)", caseId: "c1", n: n, createdAt: "2026-10-10T10:00:00Z", author: .agent, baseRevision: nil,
            name: name, kind: kind)
    }

    /// A deck (a set of screens) and a write-up.
    private var tabs: [ArtifactTab] {
        ArtifactTabs.tabs(revisions: [rev(1, "Deck", .screenshots), rev(2, "Notes", .markdown), rev(3, "Flow", .htmlBundle)])
    }

    private let deck = "name:deck"
    private let captions: [String?] = ["Discover", "Evening", "Rewards"]

    private func opt(_ id: String, ref: String? = nil, anchor: String? = nil) -> Option {
        Option(id: id, label: id.uppercased(), artifactRef: ref, anchor: anchor)
    }

    private func focus(
        _ options: [Option], index: Int = 0, count: Int = 3, chosen: [String] = [], recommended: [String] = []
    ) -> DecisionFocus {
        DecisionFocus(index: index, count: count, options: options, chosen: chosen, recommended: recommended)
    }

    private func target(_ focus: DecisionFocus, current: String? = "name:deck", captions: [String?]? = nil) -> DecisionArtifactTarget? {
        let names = captions ?? self.captions
        return DecisionArtifactRule.target(for: focus, tabs: tabs, current: current) { $0 == "name:deck" ? names : nil }
    }

    // MARK: Rule 1: the chosen or pre-picked option

    @Test func theChosenOptionShowsItsTabAndAnchor() {
        let f = focus([opt("a", ref: "Notes", anchor: "intro"), opt("b", ref: "Flow", anchor: "cards")], chosen: ["b"])
        #expect(target(f) == DecisionArtifactTarget(tabId: "name:flow", anchor: "cards"))
    }

    @Test func thePrePickedOptionShowsItWhenNothingIsChosen() {
        let f = focus([opt("a", ref: "Notes"), opt("b", ref: "Flow")], recommended: ["b"])
        #expect(target(f) == DecisionArtifactTarget(tabId: "name:flow", anchor: nil))
    }

    @Test func theChosenOptionBeatsThePrePick() {
        let f = focus([opt("a", ref: "Notes"), opt("b", ref: "Flow")], chosen: ["a"], recommended: ["b"])
        #expect(target(f)?.tabId == "name:notes")
    }

    @Test func aChosenOptionOnASetFlipsToItsImageByNumberOrCaption() {
        let byNumber = focus([opt("a", ref: "Deck", anchor: "2"), opt("b", ref: "Deck", anchor: "3")], chosen: ["b"])
        #expect(target(byNumber) == DecisionArtifactTarget(tabId: deck, anchor: nil, image: 2))
        let byCaption = focus([opt("a", ref: "Deck", anchor: " EVEN ing ")], chosen: ["a"])
        #expect(target(byCaption) == DecisionArtifactTarget(tabId: deck, anchor: nil, image: 1))
    }

    // MARK: Rule 2: every option names one artifact

    @Test func optionsThatNameOneArtifactShowIt() {
        let f = focus([opt("a", ref: "Notes"), opt("b", ref: "notes "), opt("c")])
        #expect(target(f, current: deck) == DecisionArtifactTarget(tabId: "name:notes", anchor: nil))
    }

    @Test func theSharedAnchorShowsToo() {
        let f = focus([opt("a", ref: "Flow", anchor: "cards"), opt("b", ref: "Flow", anchor: "cards")])
        #expect(target(f)?.anchor == "cards")
        let mixed = focus([opt("a", ref: "Flow", anchor: "cards"), opt("b", ref: "Flow", anchor: "table")])
        #expect(target(mixed) == DecisionArtifactTarget(tabId: "name:flow", anchor: nil))
    }

    @Test func optionsThatNameDifferentArtifactsFallThrough() {
        let f = focus([opt("a", ref: "Notes"), opt("b", ref: "Flow")], index: 1, count: 3)
        // No pick, no shared artifact: rule 3 applies to the set on show.
        #expect(target(f) == DecisionArtifactTarget(tabId: nil, anchor: nil, image: 1))
    }

    // MARK: Rule 3: an image of the set on show

    @Test func anAnchorNumberShowsThatImage() {
        let f = focus([opt("a", anchor: "3"), opt("b", anchor: "3")], index: 0)
        #expect(target(f) == DecisionArtifactTarget(tabId: nil, anchor: nil, image: 2))
    }

    @Test func aCaptionAnchorIgnoresCaseAndSpaces() {
        let f = focus([opt("a", anchor: "  rEwArDs ")], index: 0, chosen: ["a"])
        #expect(target(f)?.image == 2)
        // The anchor of the pick wins over a position.
        let g = focus([opt("a", anchor: "1"), opt("b", anchor: "2")], index: 2, recommended: ["b"])
        #expect(target(g)?.image == 1)
    }

    @Test func withNoAnchorDecisionKShowsImageKWhenTheCountsMatch() {
        for k in 0..<3 {
            #expect(target(focus([opt("a"), opt("b")], index: k))?.image == k)
        }
    }

    @Test func withNoAnchorMoreDecisionsThanImagesChangeNothing() {
        // Fewer decisions than images still follows by position (operator's case, 10 Oct: 2 decisions, 3 images).
        #expect(target(focus([opt("a")], index: 1, count: 2)) != nil)
        #expect(target(focus([opt("a")], index: 1, count: 4)) == nil)
    }

    @Test func anAnchorThatNamesNoImageFallsBackToThePosition() {
        #expect(target(focus([opt("a", anchor: "9"), opt("b", anchor: "nothing")], index: 1, chosen: ["a"]))?.image == 1)
        #expect(target(focus([opt("a", anchor: "9")], index: 1, count: 4, chosen: ["a"])) == nil)
    }

    // MARK: Rule 4: nothing

    @Test func anArtifactThatIsNotASetStaysAsItIs() {
        let f = focus([opt("a"), opt("b")], index: 1)
        #expect(target(f, current: "name:notes") == nil)
        #expect(target(f, current: "name:flow") == nil)
        #expect(target(f, current: nil) == nil)
    }

    @Test func aNameThatMatchesNoTabFallsThrough() {
        let f = focus([opt("a", ref: "Nope")], index: 2, chosen: ["a"])
        #expect(target(f)?.image == 2)
        #expect(target(f, current: "name:notes") == nil)
    }

    @Test func aSetThatHasNotLoadedChangesNothing() {
        #expect(target(focus([opt("a")], index: 1), captions: []) == nil)
        let f = focus([opt("a")], index: 1)
        let none = DecisionArtifactRule.target(for: f, tabs: tabs, current: deck) { _ in nil }
        #expect(none == nil)
    }

    @Test func aSingleDecisionNeverFlipsASet() {
        #expect(target(focus([opt("a")], index: 0, count: 1)) == nil)
    }

    // MARK: The decision on screen

    private func request(items: [Item]) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Deck", need: "Need", why: "Why", recommendation: "",
            recommendationWhy: "", options: [], status: .needsYou, hasArtifact: true,
            createdAt: "2026-10-10T10:00:00Z", updatedAt: "2026-10-10T10:00:00Z", items: items)
    }

    private var items: [Item] {
        [
            Item(id: "i1", question: "Which Discover?", options: [opt("a", ref: "Deck", anchor: "1"), opt("b", ref: "Deck", anchor: "2")], recommendation: ["a"]),
            Item(id: "i2", question: "Which evening?", options: [opt("c"), opt("d")]),
        ]
    }

    @Test func theFocusFollowsTheStepAndThePicks() {
        let c = request(items: items)
        var doc = QuestionsDocModel(request: c)
        let first = DecisionFocus.make(case: c, doc: doc)
        #expect(first?.index == 0 && first?.count == 2)
        #expect(first?.options.map(\.id) == ["a", "b"] && first?.recommended == ["a"] && first?.chosen == [])
        doc.choose("B", question: "i1", point: "i1")
        #expect(DecisionFocus.make(case: c, doc: doc)?.chosen == ["b"])
        doc.next()
        let second = DecisionFocus.make(case: c, doc: doc)
        #expect(second?.index == 1 && second?.options.map(\.id) == ["c", "d"])
        doc.next()
        #expect(doc.isReview && DecisionFocus.make(case: c, doc: doc) == nil)
    }

    @Test func aRequestWithOneDecisionHasNoFocus() {
        let c = request(items: [items[0]])
        #expect(DecisionFocus.make(case: c, doc: QuestionsDocModel(request: c)) == nil)
    }

    // MARK: The box

    private func box(_ kind: ArtifactKind = .screenshots) -> (LiveArtifactModel, CommentsSessionStore, [CaptureRecord]) {
        let store = CommentsSessionStore()
        let model = LiveArtifactModel(
            caseId: "c1", client: KnockClient(socketPath: "/nonexistent.sock", startDaemon: {}),
            tabs: ArtifactTabs.tabs(revisions: [rev(1, "Deck", kind), rev(2, "Notes", .markdown)]), commentsStore: store)
        let image = NSImage(size: NSSize(width: 40, height: 80))
        let records = store.addScreenshotsCaptures(
            images: [(image, "Discover"), (image, "Evening"), (image, "Rewards")], revision: 1)
        model.select("name:deck")
        return (model, store, records)
    }

    @Test func movingBetweenDecisionsFlipsTheSetAndTheOperatorsFlipStaysInsideADecision() async {
        let (model, store, records) = box()
        let one = focus([opt("a"), opt("b")], index: 0)
        let two = focus([opt("a"), opt("b")], index: 1)
        await model.follow(decision: one)
        #expect(store.selectedCaptureId == records[0].id)
        await model.follow(decision: two)
        #expect(store.selectedCaptureId == records[1].id)
        // The operator flips to image 3 inside decision 2: nothing moves it back until the decision changes.
        model.stepScreen(by: 1)
        #expect(store.selectedCaptureId == records[2].id)
        await model.follow(decision: one)
        #expect(store.selectedCaptureId == records[0].id)
        #expect(model.fullSizeRevision == 1)
    }

    @Test func movingToADecisionThatNamesAnotherTabSwitchesIt() async {
        let (model, _, _) = box()
        await model.follow(decision: focus([opt("a", ref: "Notes")], chosen: ["a"]))
        #expect(model.selectedTab?.id == "name:notes")
        #expect(model.fullSizeRevision == 2)
    }

    @Test func choosingAnOptionWithAnImageAnchorFlipsTheSet() async {
        let (model, store, records) = box()
        model.apply(ArtifactTabs.link(for: opt("a", ref: "Deck", anchor: "Rewards"), in: model.tabs, current: nil))
        _ = try? await pollUntil(.seconds(20)) { store.selectedCaptureId == records[2].id }
        #expect(store.selectedCaptureId == records[2].id)
        #expect(model.anchorRequest == nil)
    }

    @Test func aRequestThatNeverFollowedADecisionOpensFullSizeOnTheNewest() {
        let (model, _, _) = box()
        #expect(model.fullSizeRevision == nil)
    }
}
