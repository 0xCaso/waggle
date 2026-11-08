import Foundation
import Testing
@testable import Knock

/// WAG-316 (three blocks T6): a review is a request with two rows, Approve and Request changes, and it always
/// ends in a decision. Comments alone keep the talk going. A plan round keeps its recommendation preselected.
@Suite(.serialized)
@MainActor
struct ReviewRowsTests {
    private func decode(kind: String = "review", options: [[String: Any]] = [], recommendation: String = "", why: String = "") throws -> Case {
        var json = ItemsDecodeTests.caseJSON(extra: [
            "kind": kind, "options": options, "recommendation": recommendation, "recommendation_why": why, "has_artifact": true,
        ])
        json["status"] = "needs_you"
        return try JSONDecoder().decode(Case.self, from: ItemsDecodeTests.data(json))
    }

    private let daemonRows: [[String: Any]] = [
        ["id": "approve", "title": "Approve", "label": "Approve: ship it as it is"],
        ["id": "request_changes", "title": "Request changes", "label": "Request changes: use my comments"],
    ]

    // MARK: - Rows

    @Test func aReviewWithNoOptionsGetsTheTwoRows() throws {
        let review = try decode()
        #expect(review.options.map(\.id) == ["approve", "request_changes"])
        #expect(review.options.map(\.displayTitle) == ["Approve", "Request changes"])
    }

    @Test func theDaemonsRowsStayAsTheyCame() throws {
        let review = try decode(options: daemonRows, recommendation: "approve", why: "It matches the brief.")
        #expect(review.options.map(\.id) == ["approve", "request_changes"])
        #expect(review.recommendation == "approve")
        #expect(review.recommendations == ["approve"])
    }

    @Test func aRecommendationThatNamesARowMarksIt() throws {
        let review = try decode(recommendation: "Request changes", why: "The title is off.")
        #expect(review.recommendation == "request_changes")
        #expect(review.recommendationWhy == "The title is off.")
    }

    @Test func aFreeTextRecommendationIsTheWhyAndMarksNoRow() throws {
        let review = try decode(options: daemonRows, recommendation: "Looks fine to ship", why: "Tests pass")
        #expect(review.recommendation.isEmpty)
        #expect(review.recommendations.isEmpty)
        #expect(review.recommendationWhy == "Looks fine to ship. Tests pass")
        #expect(ComposerCardView.freeTextWhy(review, recommendationId: review.recommendation) == "Looks fine to ship. Tests pass")
    }

    @Test func theDaemonsOwnLeadIsNotDoubled() throws {
        let review = try decode(options: daemonRows, recommendation: "Looks fine to ship", why: "Looks fine to ship. Tests pass")
        #expect(review.recommendationWhy == "Looks fine to ship. Tests pass")
    }

    @Test func aRowThatIsMarkedShowsNoLooseWhy() throws {
        let review = try decode(recommendation: "approve", why: "Good.")
        #expect(ComposerCardView.freeTextWhy(review, recommendationId: review.recommendation) == nil)
    }

    @Test func aQuestionRequestIsLeftAlone() throws {
        let question = try decode(kind: "question", recommendation: "free text", why: "Because")
        #expect(question.options.isEmpty)
        #expect(question.recommendation == "free text")
    }

    // MARK: - Decide or keep talking

    @Test func noRowIsPickedOnOpen() throws {
        let composer = ComposerViewModel(knockCase: try decode(options: daemonRows, recommendation: "approve"))
        #expect(composer.isReview)
        #expect(composer.selectedOptionId == nil)
        #expect(!composer.hasPick)
    }

    @Test func withNoRowThePrimaryActionSendsAndNeverAcceptsTheRecommendation() throws {
        let composer = ComposerViewModel(knockCase: try decode(options: daemonRows, recommendation: "approve"))
        #expect(composer.footerPrimaryAction == .send)
        composer.selectOption("approve")
        #expect(composer.hasPick)
        #expect(composer.footerPrimaryAction == .acceptRecommendation)
        composer.selectOption("request_changes")
        #expect(composer.footerPrimaryAction == .sendOption(position: 2))
    }

    @Test func aFreeTextRecommendationHasNothingToAccept() throws {
        let composer = ComposerViewModel(knockCase: try decode(options: daemonRows, recommendation: "Looks fine"))
        #expect(composer.recommendationChoice == nil)
    }

    @Test func commentsOnlyReadSendCommentsAndAPickReadsDecide() {
        #expect(PromptBarLogic.sendPillLabels(commentCount: 2, sendsComments: true) == ["Send comments"])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 2, decideTitle: "Approve", sendsComments: false) == ["Decide + 2 comments", "Decide"])
        #expect(PromptBarLogic.reviewPickHint == "Pick Approve or Request changes to decide.")
    }

    // MARK: - The plan keeps its pre-pick (c_057ef9c9)

    @Test func aPlanRoundDoesNotPreselectItsRecommendation() throws {
        var json = ItemsDecodeTests.caseJSON(extra: [
            "kind": "question", "recommendation": "a", "recommendation_why": "Fastest.", "status": "needs_you",
            "options": [["id": "a", "label": "Compact"], ["id": "b", "label": "Detailed"]],
            "plan": ["stage": ["name": "approaches", "step": 1, "total": 2], "rounds": 2, "answered": 1],
        ])
        json["has_artifact"] = true
        let round2 = try JSONDecoder().decode(Case.self, from: ItemsDecodeTests.data(json))
        #expect(round2.plan != nil)
        let composer = ComposerViewModel(knockCase: round2)
        #expect(composer.selectedOptionId == nil)
        #expect(!composer.pickIsDefault)
        #expect(!composer.isReview)
    }
}
