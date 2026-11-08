import Foundation
import Testing
@testable import Knock

/// WAG-364: each decision of a group is its own step; the group title stays as a heading.
@MainActor
struct WAG364Tests {
    // MARK: Fixtures

    private static func request(
        items: [Item] = [], questions: [Question] = [], status: CaseStatus = .needsYou
    ) -> Case {
        Case(
            id: "c1", taskId: "t", kind: .question, title: "Light avatar screens", need: "Three decisions.", why: "",
            recommendation: "", recommendationWhy: "", options: [], status: status, hasArtifact: false,
            createdAt: "2026-10-12T10:00:00Z", updatedAt: "2026-10-12T10:00:00Z",
            questions: questions, latestReplyAnswers: [], items: items)
    }

    private static let group = ItemGroup(
        id: "light", title: "Light avatar screens", now: ["Dark screens today", "One avatar"],
        variants: [QuestionVariant(id: "a", label: "A"), QuestionVariant(id: "b", label: "B")], variantLabel: "Look")

    private static func item(_ id: String, _ question: String, ref: String? = nil, group: ItemGroup? = WAG364Tests.group) -> Item {
        Item(
            id: id, question: question,
            options: [Option(id: "\(id)-1", label: "Keep", artifactRef: ref), Option(id: "\(id)-2", label: "Change", artifactRef: ref)],
            recommendation: ["\(id)-1"], group: group)
    }

    private static var operatorItems: [Item] {
        [
            item("i1", "Open on Meet your avatar?", ref: "Meet your avatar"),
            item("i2", "Show State reveal after it?", ref: "State reveal"),
            item("i3", "Show the level-up screen?"),
        ]
    }

    /// The operator's request (case c_16452899): step 3 names no artifact in its options, only in its question.
    private static var nameItems: [Item] {
        Array(operatorItems.prefix(2)) + [
            item("i3", "The \"You moved up\" screen is light today, but its picture is a hard-edged card. Do I give it the same blended form?")]
    }

    private func rev(_ n: Int, _ name: String) -> Revision {
        Revision(
            id: "r\(n)", caseId: "c1", n: n, createdAt: "2026-10-12T10:00:00Z", author: .agent, baseRevision: nil,
            name: name, kind: .screenshots)
    }

    // MARK: Steps

    @Test func eachItemOfAGroupIsOneStepInTheOrderSent() {
        let doc = QuestionsDocModel(request: Self.request(items: Self.operatorItems))
        #expect(doc.questions.map(\.id) == ["i1", "i2", "i3"])
        #expect(doc.questions.map { $0.points.count } == [1, 1, 1])
        #expect(doc.stepPills.map(\.title).last == "Send" && doc.stepPills.count == 4)
        #expect(doc.stepPills.dropLast().map(\.title) == ["Open on Meet your…", "Show State reveal…", "Show the level-up…"])
        #expect(doc.stepCrumb == "Decision 1 of 3")
    }

    @Test func mixedGroupedAndUngroupedItemsKeepOneStepEach() {
        let items = [
            Self.item("a", "First?"),
            Self.item("b", "Second?", group: nil),
            Self.item("c", "Third?", group: ItemGroup(id: "other", title: "Other")),
            Self.item("d", "Fourth?"),
        ]
        let doc = QuestionsDocModel(request: Self.request(items: items))
        #expect(doc.questions.map(\.id) == ["a", "b", "c", "d"])
        #expect(doc.questions.map(\.groupTitle) == ["Light avatar screens", nil, "Other", "Light avatar screens"])
    }

    @Test func theHeadingNowLinesAndVariantsShowOnEachStepOfTheGroup() {
        let doc = QuestionsDocModel(request: Self.request(items: Self.operatorItems))
        for question in doc.questions {
            #expect(question.groupTitle == "Light avatar screens")
            #expect(question.now == ["Dark screens today", "One avatar"])
            #expect(question.variants?.map(\.id) == ["a", "b"] && question.variantLabel == "Look")
        }
        #expect(doc.questions.map(\.title) == ["Open on Meet your avatar?", "Show State reveal after it?", "Show the level-up screen?"])
    }

    // MARK: Artifact

    @Test func theArtifactFollowsEachDecisionOfTheGroup() throws {
        var doc = QuestionsDocModel(request: Self.request(items: Self.nameItems))
        let request = Self.request(items: Self.nameItems)
        let tabs = ArtifactTabs.tabs(revisions: [rev(1, "Meet your avatar"), rev(2, "State reveal"), rev(3, "You moved up")])
        func target(current: String?) throws -> DecisionArtifactTarget? {
            let focus = try #require(DecisionFocus.make(case: request, doc: doc))
            return DecisionArtifactRule.target(for: focus, tabs: tabs, current: current) { _ in ["One"] }
        }
        #expect(try target(current: "name:you moved up")?.tabId == "name:meet your avatar")
        doc.next()
        #expect(try target(current: "name:meet your avatar")?.tabId == "name:state reveal")
        doc.next()
        // No option of step 3 names an artifact, but its question names "You moved up" (Amendment 1).
        #expect(try target(current: "name:state reveal")?.tabId == "name:you moved up")
    }

    private func focus(_ question: String?, options: [Option] = [Option(id: "a", label: "Keep")], recommended: [String] = []) -> DecisionFocus {
        DecisionFocus(index: 2, count: 3, options: options, chosen: [], recommended: recommended, question: question)
    }

    private var nameTabs: [ArtifactTab] {
        ArtifactTabs.tabs(revisions: [rev(1, "Meet your avatar"), rev(2, "State reveal"), rev(3, "You moved up")])
    }

    @Test func oneNameInTheQuestionPicksItsTab() {
        let link = DecisionArtifactRule.nameMatch(for: focus("Is  the STATE  reveal\nscreen fine?"), tabs: nameTabs)
        #expect(link?.tabId == "name:state reveal")
    }

    @Test func aNameInAnOptionTitleOrLabelMatches() {
        let option = Option(id: "a", label: "Drop the You moved up card", title: "Drop it")
        #expect(DecisionArtifactRule.nameMatch(for: focus("Which?", options: [option]), tabs: nameTabs)?.tabId == "name:you moved up")
    }

    @Test func noNameKeepsTheTab() {
        #expect(DecisionArtifactRule.nameMatch(for: focus("Is it fine?"), tabs: nameTabs) == nil)
        let doc = DecisionArtifactRule.target(for: focus("Is it fine?"), tabs: nameTabs, current: "name:state reveal") { _ in nil }
        #expect(doc == nil)
    }

    @Test func twoNamesKeepTheTab() {
        #expect(DecisionArtifactRule.nameMatch(for: focus("State reveal or You moved up?"), tabs: nameTabs) == nil)
    }

    @Test func aShortNameNeverMatches() {
        let tabs = ArtifactTabs.tabs(revisions: [rev(1, "UI"), rev(2, "Plan")])
        #expect(DecisionArtifactRule.nameMatch(for: focus("Is the UI fine?"), tabs: tabs) == nil)
    }

    @Test func anArtifactRefWinsOverTheName() {
        let option = Option(id: "a", label: "Keep", artifactRef: "Meet your avatar")
        let target = DecisionArtifactRule.target(
            for: focus("The You moved up screen?", options: [option]), tabs: nameTabs, current: nil) { _ in nil }
        #expect(target?.tabId == "name:meet your avatar")
    }

    // MARK: Variants belong to the group (Amendment 2)

    @Test func aVariantPickedOnOneStepShowsOnTheOthersOfTheGroup() throws {
        let other = ItemGroup(id: "other", title: "Other", now: nil, variants: Self.group.variants, variantLabel: nil)
        let items = Self.operatorItems + [Self.item("i4", "Another?", group: other)]
        var doc = QuestionsDocModel(request: Self.request(items: items))
        let steps = doc.questions
        #expect(doc.selectedVariant(for: steps[0]) == "a")
        doc.selectVariant("b", question: "i1")
        #expect(doc.selectedVariant(for: steps[1]) == "b" && doc.selectedVariant(for: steps[2]) == "b")
        #expect(doc.selectedVariant(for: steps[3]) == "a")
    }

    @Test func aRestoredDraftKeepsTheVariantPick() {
        var doc = QuestionsDocModel(request: Self.request(items: Self.operatorItems))
        doc.selectVariant("b", question: "i2")
        doc.refresh(with: Self.request(items: Self.operatorItems))
        #expect(doc.questions.allSatisfy { doc.selectedVariant(for: $0) == "b" })
    }

    // MARK: Reply

    @Test func theReplyKeepsOneAnswerPerItemInOrder() {
        var doc = QuestionsDocModel(request: Self.request(items: Self.operatorItems))
        for question in doc.questions { doc.choose("Change", question: question.id, point: question.points[0].id) }
        #expect(doc.itemAnswers().map(\.itemId) == ["i1", "i2", "i3"])
        #expect(doc.itemAnswers().map(\.choice) == ["i1-2", "i2-2", "i3-2"])
        doc.jump(to: doc.reviewStep)
        #expect(doc.reviewRows.map(\.picks) == [["Change"], ["Change"], ["Change"]])
    }

    // MARK: A draft from before the update

    @Test func aDraftKeptUnderTheOldGroupStepMovesToItsItem() throws {
        // Before: one step "light" with the three items as points.
        let old = Question(
            id: "light", title: "Light avatar screens", now: nil,
            points: Self.operatorItems.map { QuestionPoint(item: $0, fallbackText: "") },
            artifactRef: nil, variants: nil, variantLabel: nil)
        var doc = QuestionsDocModel(request: Self.request(questions: [old]))
        doc.choose("Change", question: "light", point: "i2")
        doc.choose("Keep", question: "light", point: "i1")
        doc.refresh(with: Self.request(items: Self.operatorItems))
        #expect(doc.questions.map(\.id) == ["i1", "i2", "i3"])
        #expect(doc.draft("i2", "i2").choice == "Change" && doc.draft("i1", "i1").choice == "Keep")
        #expect(doc.draft("i3", "i3").choice == nil)
        #expect(doc.itemAnswers().map(\.itemId) == ["i1", "i2"])
    }

    // MARK: Legacy

    @Test func theLegacyQuestionsPayloadKeepsItsPagesWithSeveralPoints() {
        let legacy = [
            Question(id: "q", title: "Q?", now: nil, points: [
                QuestionPoint(id: "p1", text: "One?", options: ["Yes", "No"]), QuestionPoint(id: "p2", text: "Two?", options: ["Yes", "No"])],
                artifactRef: nil, variants: nil, variantLabel: nil),
            Question(id: "r", title: "R?", now: nil, points: [QuestionPoint(id: "p3", text: "Three?", options: ["Yes", "No"])], artifactRef: nil, variants: nil, variantLabel: nil),
        ]
        let doc = QuestionsDocModel(request: Self.request(questions: legacy))
        #expect(doc.questions == legacy && doc.questions.map { $0.points.count } == [2, 1])
        #expect(doc.questions.allSatisfy { $0.groupTitle == nil })
    }
}
