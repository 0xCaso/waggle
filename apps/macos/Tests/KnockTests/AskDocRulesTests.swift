import Testing
import Foundation
import SwiftUI
import AppKit
@testable import Knock

/// The decision doc's rules (WAG-257): the bottom bar by ask shape, one place for options, the card layout
/// by count, where an artifact opens and what the browser sees.
struct AskDocRulesTests {
    private func ask(
        options: [Option] = [], questions: [Question] = [], hasArtifact: Bool = false, kind: ArtifactKind? = nil, id: String = "c1",
        optionsSeq: Int = 0
    ) -> Case {
        Case(
            id: id, taskId: "t", kind: .question, title: "Which layout?", need: "Pick one.", why: "Cannot decide.",
            recommendation: "a", recommendationWhy: "Simple.", options: options, status: .needsYou, hasArtifact: hasArtifact,
            createdAt: "2026-10-07T10:00:00Z", updatedAt: "2026-10-07T10:00:00Z", artifactKind: kind, optionsSeq: optionsSeq, questions: questions)
    }

    private let options = [Option(id: "a", label: "Flagged first"), Option(id: "b", label: "Newest first")]
    private let questions = [Question(id: "q", title: "T", now: nil, points: [QuestionPoint(id: "p", text: "P", options: nil)], artifactRef: nil, variants: nil, variantLabel: nil)]

    // MARK: Bottom bar by ask shape

    @Test func aSimpleAskGetsTheDecideBar() {
        #expect(AskBarMode.forCase(ask(options: options)) == .decide)
    }

    @Test func anAskWithQuestionsGetsTheAnswersBarNeverTheDecideBar() {
        #expect(AskBarMode.forCase(ask(questions: questions)) == .answers)
        // Even when the ask also names options, the bar is one or the other.
        #expect(AskBarMode.forCase(ask(options: options, questions: questions)) == .answers)
    }

    // WAG-343: new options on an ask that began with questions replace the questions doc.
    @Test func newOptionsReplaceTheQuestionsDoc() {
        let later = ask(options: options, questions: questions, optionsSeq: 1)
        #expect(!later.hasQuestionsDoc)
        #expect(later.questionsReplacedByLaterRound)
        #expect(AskBarMode.forCase(later) == .decide)
        #expect(AskDocRules.optionsPlaces(for: later) == [.bottomBar])
        // The first round still reads as the questions doc.
        #expect(ask(options: options, questions: questions, optionsSeq: 0).hasQuestionsDoc)
    }

    @Test func aLaterRoundWithNoOptionsDoesNotLeaveTheQuestionsOnTheAnswersBar() {
        let later = ask(options: [], questions: questions, optionsSeq: 2)
        #expect(AskBarMode.forCase(later) == .reply)
    }

    @Test func anAskWithNoOptionsAndNoQuestionsGetsTheReplyBar() {
        #expect(AskBarMode.forCase(ask()) == .reply)
    }

    // MARK: One place for options

    @Test func optionsLiveInOnePlaceAtMost() {
        for item in [ask(options: options), ask(questions: questions), ask(), ask(options: options, questions: questions)] {
            #expect(AskDocRules.optionsPlaces(for: item).count <= 1)
        }
        #expect(AskDocRules.optionsPlaces(for: ask(options: options)) == [.bottomBar])
        #expect(AskDocRules.optionsPlaces(for: ask(questions: questions)).isEmpty)
        #expect(AskDocRules.optionsPlaces(for: ask()).isEmpty)
    }

    @Test func theDockRowsShowTheFullOptionWhileThePageHasNoDecisionCard() {
        let long = Option(id: "a", label: "Flagged first: put the flagged chats on top, newest at the top of each group.", title: "Flagged first")
        let entries = DecisionSectionView.entries(options: [long], recommendationId: "a")
        #expect(entries[0].showsLabel)
        #expect(OptionLabelFormatting.decisionBody(label: long.label, title: long.displayTitle).contains("newest at the top"))
    }

    @Test func theDecideButtonSaysWhatItDecides() {
        #expect(AskDocRules.decideLabel(choiceTitle: "Flagged first") == "Decide: Flagged first")
        #expect(AskDocRules.decideLabel(choiceTitle: nil) == "Decide")
        #expect(AskDocRules.decideLabel(choiceTitle: "") == "Decide")
        let forms = PromptBarLogic.sendPillLabels(commentCount: 0, decideTitle: "Flagged first")
        // WAG-301: a pick reads "Decide"; the option's name no longer rides on the button.
        #expect(forms == ["Decide"])
        // No comments, edits or plan words are lost: with any of them the old label rules apply.
        #expect(PromptBarLogic.sendPillLabels(commentCount: 2, decideTitle: "Flagged first") != forms)
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, decideTitle: nil) == [nil])
    }

    // MARK: Artifact cards

    @Test func oneArtifactIsOneWideCard() {
        #expect(ArtifactCardsLayout.rule(count: 1) == .wide)
    }

    @Test func twoOrThreeShareTheRow() {
        #expect(ArtifactCardsLayout.rule(count: 2) == .sideBySide(columns: 2))
        #expect(ArtifactCardsLayout.rule(count: 3) == .sideBySide(columns: 3))
    }

    @Test func moreThanThreeScrollInARow() {
        #expect(ArtifactCardsLayout.rule(count: 4) == .scrollingRow)
        #expect(ArtifactCardsLayout.rule(count: 9) == .scrollingRow)
        #expect(ArtifactCardsLayout.rule(count: 0) == .none)
    }

    @Test func aCardCarriesTypeKindVersionAndMeta() throws {
        let item = ask(questions: questions, hasArtifact: true, kind: .htmlBundle)
        let plain = try #require(ArtifactCardModel.cards(for: item, revision: 2, question: questions[0]).first)
        #expect(plain.type == .prototype && plain.kindLine == "PROTOTYPE · V2" && plain.name == "Prototype")
        let withVariants = Question(
            id: "q", title: "T", now: nil, points: questions[0].points, artifactRef: nil,
            variants: [QuestionVariant(id: "a", label: "A"), QuestionVariant(id: "b", label: "B"), QuestionVariant(id: "c", label: "C")],
            variantLabel: nil)
        let card = try #require(ArtifactCardModel.cards(for: item, revision: 1, question: withVariants).first)
        #expect(card.meta == "3 ways to compare" && card.variantCount == 3)
        #expect(ArtifactCardModel.cards(for: ask(), revision: 1).isEmpty)
    }

    @Test func eachKindHasItsTypeIcon() {
        #expect(ArtifactCardType(kind: .htmlBundle) == .prototype)
        #expect(ArtifactCardType(kind: .diagram) == .flow)
        #expect(ArtifactCardType(kind: .markdown) == .writeUp)
        #expect(ArtifactCardType(kind: .screenshot) == .screenshots && ArtifactCardType(kind: .screenshots) == .screenshots)
        let symbols = Set([ArtifactCardType.prototype, .chart, .flow, .writeUp, .screenshots].map(\.symbol))
        #expect(symbols.count == 5)
    }

    // MARK: Where it opens

    private func memory() -> OpenTargetMemory {
        let suite = "knock.test.opentarget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return OpenTargetMemory(defaults: defaults)
    }

    @Test func theDefaultFollowsTheKindOfCard() {
        #expect(memory().last(fullSize: false) == .beside)
        #expect(memory().last(fullSize: true) == .fullSize)
        let proto = ArtifactCardModel.cards(for: ask(questions: questions, hasArtifact: true, kind: .htmlBundle), revision: 1)[0]
        let write = ArtifactCardModel.cards(for: ask(questions: questions, hasArtifact: true, kind: .markdown), revision: 1)[0]
        let diagram = ArtifactCardModel.cards(for: ask(questions: questions, hasArtifact: true, kind: .diagram), revision: 1)[0]
        let image = ArtifactCardModel.cards(for: ask(questions: questions, hasArtifact: true, kind: .screenshot), revision: 1)[0]
        let set = ArtifactCardModel.cards(for: ask(questions: questions, hasArtifact: true, kind: .screenshots), revision: 1)[0]
        #expect(proto.opensFullSize && set.opensFullSize)
        #expect(!write.opensFullSize && !diagram.opensFullSize && !image.opensFullSize)
    }

    @Test func theMenuFollowsTheKindOfCard() {
        #expect(ArtifactOpenTarget.menu(fullSize: true).map(\.menuLabel) == ["Full size", "In a new window", "In the browser"])
        #expect(!ArtifactOpenTarget.menu(fullSize: true).contains(.beside))
        #expect(ArtifactOpenTarget.menu(fullSize: false).map(\.menuLabel)
            == ["Side panel", "Full Waggle page", "In a new window", "In the browser"])
    }

    @Test func theLastChoiceIsRememberedPerKind() {
        let store = memory()
        store.setLast(.browser, fullSize: true)
        store.setLast(.fullPage, fullSize: false)
        let again = OpenTargetMemory(defaults: store.defaultsForTests)
        #expect(again.last(fullSize: true) == .browser)
        #expect(again.last(fullSize: false) == .fullPage)
    }

    @Test func aSavedSidePanelForAPrototypeBecomesFullSize() {
        for saved in ["beside", "fullPage"] {
            let store = memory()
            store.defaultsForTests.set(saved, forKey: OpenTargetMemory.key)
            #expect(store.last(fullSize: true) == .fullSize)
        }
        let store = memory()
        store.defaultsForTests.set("beside", forKey: OpenTargetMemory.fullSizeKey)
        #expect(store.last(fullSize: true) == .fullSize)
        // A saved window or browser stays, and the side panel choice stays for a write-up.
        store.defaultsForTests.set("ownWindow", forKey: OpenTargetMemory.key)
        store.defaultsForTests.removeObject(forKey: OpenTargetMemory.fullSizeKey)
        #expect(store.last(fullSize: true) == .ownWindow)
        store.defaultsForTests.set("beside", forKey: OpenTargetMemory.key)
        #expect(store.last(fullSize: false) == .beside)
        // Full size is not on a write-up's menu.
        store.defaultsForTests.set("fullSize", forKey: OpenTargetMemory.panelKey)
        #expect(store.last(fullSize: false) == .beside)
    }

    @Test @MainActor func choosingATargetRemembersItAndOpensPanelOrPage() {
        let suite = "knock.test.controller.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = ask(questions: questions, hasArtifact: true, kind: .markdown)
        let controller = AskDocController(
            client: KnockClient(socketPath: "/tmp/knock-test-none.sock"), request: item, memory: OpenTargetMemory(defaults: defaults))
        let card = ArtifactCardModel.cards(for: item, revision: 1, question: questions[0])[0]
        #expect(controller.lastTarget(fullSize: false) == .beside)
        #expect(controller.choose(.beside, card: card, questionId: "q") == nil)
        #expect(controller.open?.placement == .beside)
        #expect(controller.viewer.pageFragment == "q")
        controller.close()
        #expect(controller.open == nil)
        #expect(controller.choose(.fullPage, card: card, questionId: "q") == nil)
        #expect(controller.open?.placement == .fullPage && controller.lastTarget(fullSize: false) == .fullPage)
        #expect(controller.choose(.ownWindow, card: card, questionId: "q") == .ownWindow)
        #expect(controller.lastTarget(fullSize: false) == .ownWindow)
        #expect(controller.choose(.browser, card: card, questionId: "q") == .browser)
        #expect(controller.lastTarget(fullSize: false) == .browser)
        // A prototype goes to the full size view, which the page owns.
        let proto = ArtifactCardModel.cards(for: ask(questions: questions, hasArtifact: true, kind: .htmlBundle), revision: 1)[0]
        controller.close()
        #expect(controller.choose(.fullSize, card: proto, questionId: "q") == .fullSize)
        #expect(controller.open == nil && controller.lastTarget(fullSize: true) == .fullSize)
    }

    @Test @MainActor func aVariantChoiceSetsThePagesHash() {
        let item = ask(
            questions: [Question(
                id: "q", title: "T", now: nil, points: questions[0].points, artifactRef: nil,
                variants: [QuestionVariant(id: "a", label: "A"), QuestionVariant(id: "b", label: "B")], variantLabel: nil)],
            hasArtifact: true, kind: .htmlBundle)
        let controller = AskDocController(client: KnockClient(socketPath: "/tmp/knock-test-none.sock"), request: item)
        controller.selectVariant("b", question: "q")
        #expect(controller.viewer.pageFragment == "q?variant=b")
    }

    // MARK: The browser

    @Test func theBrowserPageFramesTheBundleInASandbox() {
        let html = BrowserWrapper.html(entry: URL(fileURLWithPath: "/tmp/a b/index.html"), fragment: "q?variant=b", title: "Pick \"one\" <now>", caseId: "c1")
        #expect(html.contains("sandbox=\"allow-scripts allow-forms\""))
        #expect(!html.contains("allow-same-origin"))
        #expect(html.contains("connect-src 'none'"))
        #expect(html.contains("frame-src file:"))
        #expect(html.contains("a%20b/index.html#q?variant=b"))
        #expect(html.contains("&quot;one&quot; &lt;now&gt;"))
        // WAG-280: the page says plainly that comments need the app, with one way back.
        #expect(html.contains(BrowserWrapper.notice))
        #expect(html.contains("href=\"waggle://case/c1\""))
        #expect(!BrowserWrapper.notice.contains("\u{2014}"))
        #expect(BrowserWrapper.appURL(caseId: "c1\"><script>") == "waggle://case/c1script")
    }

    // MARK: Crumbs

    @Test func theCrumbShowsTheSessionTitleNotTheWorktreeFolder() {
        let task = KnockTask(id: "t", name: "shaded-town-51fbc404", project: "Gym OS")
        #expect(AskCrumbs.breadcrumb(task: task, sessionTitle: "Share link settings") == "Gym OS / Share link settings")
        #expect(AskCrumbs.breadcrumb(task: task, sessionTitle: nil) == "Gym OS")
        #expect(AskCrumbs.folderHelp(task) == "shaded-town-51fbc404")
        // WAG-324: a plain task name is still an internal slug, so it is left out (was "Gym OS / app").
        let named = KnockTask(id: "t", name: "app", project: "Gym OS")
        #expect(AskCrumbs.breadcrumb(task: named, sessionTitle: nil) == "Gym OS")
        let brainstorm = KnockTask(id: "t", name: "brainstorm", project: "Gym OS")
        #expect(AskCrumbs.breadcrumb(task: brainstorm, sessionTitle: nil) == "Gym OS")
        #expect(AskCrumbs.breadcrumb(task: brainstorm, sessionTitle: "") == "Gym OS")
        #expect(AskCrumbs.titlePart(task: brainstorm, sessionTitle: nil) == nil)
        #expect(AskCrumbs.breadcrumb(task: brainstorm, sessionTitle: "Share link ideas") == "Gym OS / Share link ideas")
    }

    @Test func theCrumbsAreOneGreyLine() {
        #expect(AskCrumbs.line(breadcrumb: "Gym OS", runtime: "Claude Code", askNumber: 1) == "Gym OS · Claude Code")
        #expect(AskCrumbs.line(breadcrumb: "Gym OS / app", runtime: "Claude Code", askNumber: 3) == "Gym OS / app · Claude Code · 3rd decision in this session")
    }
}
