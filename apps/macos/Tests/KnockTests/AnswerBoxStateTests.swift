import Testing
import Foundation
@testable import Knock

/// HAIL-108: how the answer box frames the options once the agent updated the ask.
@MainActor
struct AnswerBoxStateTests {
    private static let first = [
        Option(id: "a", label: "Compact layout", title: "Compact"),
        Option(id: "b", label: "Detailed layout", title: "Detailed"),
        Option(id: "c", label: "Something else"),
    ]
    private static let newer = [
        Option(id: "x", label: "Ship the schema first", title: "Two steps"),
        Option(id: "a", label: "Ship both together", title: "One step"),
    ]

    /// A case that was answered at 10:05 and updated at 10:10.
    private static func updated(
        options: [Option]? = nil, optionsUpdatedAt: String? = nil, status: CaseStatus = .needsYou,
        updateAt: String? = "2026-09-26T10:10:00.000Z", replyAt: String? = "2026-09-26T10:05:00.000Z",
        fromFirst: Bool = false
    ) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Layout", need: "Pick", why: "Why",
            recommendation: options == nil ? "a" : "x", recommendationWhy: "Because",
            options: options ?? first, status: status, hasArtifact: false,
            latestReplyId: replyAt == nil ? nil : "r1", latestReplyAt: replyAt,
            updateCount: updateAt == nil ? nil : 1, latestUpdateAt: updateAt,
            createdAt: "2026-09-26T10:00:00.000Z", updatedAt: "2026-09-26T10:10:00.000Z",
            firstOptions: first, firstRecommendation: "a", optionsUpdatedAt: optionsUpdatedAt,
            latestReplyFromFirstOptions: fromFirst
        )
    }

    @Test func noUpdateIsTheOriginalBox() {
        let fresh = Self.updated(updateAt: nil, replyAt: nil)
        #expect(AnswerBoxState.make(for: fresh) == .original)
    }

    @Test func updateWithOptionsFramesTheNewSet() {
        let item = Self.updated(options: Self.newer, optionsUpdatedAt: "2026-09-26T10:10:00.000Z")
        guard case .updateWithOptions(let updatedAt, let firstAt) = AnswerBoxState.make(for: item) else {
            Issue.record("expected updateWithOptions")
            return
        }
        #expect(updatedAt == KnockDateFormat.date(from: "2026-09-26T10:10:00.000Z"))
        #expect(firstAt == KnockDateFormat.date(from: "2026-09-26T10:00:00.000Z"))
    }

    @Test func updateWithoutOptionsLeavesTheFirstSetCurrent() {
        #expect(AnswerBoxState.make(for: Self.updated()) == .original)
    }

    @Test func aLaterUpdateWithoutOptionsLeavesTheEarlierUpdatesSetCurrent() {
        let item = Self.updated(
            options: Self.newer, optionsUpdatedAt: "2026-09-26T10:08:00.000Z",
            updateAt: "2026-09-26T10:12:00.000Z", replyAt: "2026-09-26T10:09:00.000Z")
        #expect(AnswerBoxState.make(for: item) == .original)
    }

    @Test func aReplyAfterTheOptionsClearsTheFraming() {
        let item = Self.updated(
            options: Self.newer, optionsUpdatedAt: "2026-09-26T10:06:00.000Z", updateAt: nil,
            replyAt: "2026-09-26T10:09:00.000Z")
        #expect(AnswerBoxState.make(for: item) == .original)
    }

    @Test func aWaitingCaseIsNeverFramed() {
        let item = Self.updated(options: Self.newer, optionsUpdatedAt: "2026-09-26T10:10:00.000Z", status: .waitingOnAgent)
        #expect(AnswerBoxState.make(for: item) == .original)
    }

    @Test func anAskWithoutOptionsHasNothingToFold() {
        let item = Case(
            id: "c2", taskId: "t1", kind: .question, title: "T", need: "N", why: "W", recommendation: "r",
            recommendationWhy: "b", options: [], status: .needsYou, hasArtifact: false,
            latestReplyAt: "2026-09-26T10:05:00.000Z", updateCount: 1, latestUpdateAt: "2026-09-26T10:10:00.000Z",
            createdAt: "2026-09-26T10:00:00.000Z", updatedAt: "2026-09-26T10:10:00.000Z")
        #expect(AnswerBoxState.make(for: item) == .original)
    }

    @Test func copyMatchesTheDesign() {
        let utc = TimeZone(identifier: "UTC")!
        let at = KnockDateFormat.date(from: "2026-09-26T13:21:00.000Z")
        let firstAt = KnockDateFormat.date(from: "2026-09-26T13:02:00.000Z")
        #expect(AnswerBoxState.header(at: at, timeZone: utc) == "↻ Options from the update · 13:21")
        #expect(AnswerBoxState.firstOptionsDivider(at: firstAt, timeZone: utc) == "FIRST OPTIONS · 13:02")
        #expect(AnswerBoxState.firstOptionsLink(isOpen: false) == "First options")
    }

    // MARK: composer follows the newest set

    @Test func composerReadsTheNewestSetAfterARefresh() {
        let composer = ComposerViewModel(knockCase: Self.updated(updateAt: nil, replyAt: nil))
        #expect(composer.options.map(\.id) == ["a", "b", "c"])
        composer.refresh(Self.updated(options: Self.newer, optionsUpdatedAt: "2026-09-26T10:10:00.000Z"))
        #expect(composer.options.map(\.id) == ["x", "a"])
        #expect(composer.firstOptions.map(\.id) == ["a", "b", "c"])
        #expect(composer.recommendationChoice == "x")
    }

    @Test func keysPickTheNewestSetOnly() {
        let composer = ComposerViewModel(
            knockCase: Self.updated(options: Self.newer, optionsUpdatedAt: "2026-09-26T10:10:00.000Z"))
        composer.selectOption(atPosition: 2)
        #expect(composer.selectedOptionId == "a")
        #expect(composer.currentOptionsSet == nil)
        composer.selectOption(atPosition: 3)  // past the newest set's two options
        #expect(composer.selectedOptionId == "a")
    }

    @Test func aFirstSetPickNamesTheFirstSetEvenWhenTheIdIsReused() {
        let composer = ComposerViewModel(
            knockCase: Self.updated(options: Self.newer, optionsUpdatedAt: "2026-09-26T10:10:00.000Z"))
        composer.selectFirstOption("a")
        #expect(composer.selectedOptionId == "a")
        #expect(composer.currentChoice == "a")
        #expect(composer.currentOptionsSet == "first")
        composer.selectOption("a")  // the same id in the newest set switches sets
        #expect(composer.currentOptionsSet == nil)
        composer.selectFirstOption("b")
        composer.selectFirstOption("b")  // second tap clears
        #expect(composer.selectedOptionId == nil)
    }

    @Test func aRefreshDropsAPickNoOptionOffersAnyMore() {
        let composer = ComposerViewModel(knockCase: Self.updated(updateAt: nil, replyAt: nil))
        composer.selectOption("b")
        composer.refresh(Self.updated(options: Self.newer, optionsUpdatedAt: "2026-09-26T10:10:00.000Z"))
        #expect(composer.selectedOptionId == nil)
    }

    @Test func theRepliedSetNamesTheChoice() {
        let item = Self.updated(options: Self.newer, optionsUpdatedAt: "2026-09-26T10:10:00.000Z", fromFirst: true)
        #expect(item.repliedOptions.map(\.id) == ["a", "b", "c"])
        #expect(item.repliedRecommendation == "a")
        #expect(Self.updated(options: Self.newer, optionsUpdatedAt: "x").repliedOptions.map(\.id) == ["x", "a"])
    }

    // MARK: wire

    @Test func anOlderDaemonsCaseStillDecodesWithTheFirstSetEqualToTheNewest() throws {
        let json = #"""
        {"id":"c1","task_id":"t1","kind":"question","title":"T","need":"N","why":"W","recommendation":"a",
         "recommendation_why":"b","options":[{"id":"a","label":"A"}],"status":"needs_you","has_artifact":false,
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:00:00Z"}
        """#
        let item = try JSONDecoder().decode(Case.self, from: Data(json.utf8))
        #expect(item.firstOptions == item.options)
        #expect(item.firstRecommendation == "a")
        #expect(item.optionsUpdatedAt == nil)
        #expect(item.latestReplyFromFirstOptions == false)
    }

    @Test func theNewFieldsDecodeFromTheDaemon() throws {
        let json = #"""
        {"id":"c1","task_id":"t1","kind":"question","title":"T","need":"N","why":"W","recommendation":"x",
         "recommendation_why":"b","options":[{"id":"x","label":"X"}],
         "first_options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"first_recommendation":"a",
         "options_updated_at":"2026-09-26T10:10:00Z","latest_reply_from_first_options":true,
         "status":"needs_you","has_artifact":false,
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:00:00Z"}
        """#
        let item = try JSONDecoder().decode(Case.self, from: Data(json.utf8))
        #expect(item.firstOptions.map(\.id) == ["a", "b"])
        #expect(item.firstRecommendation == "a")
        #expect(item.optionsUpdatedAt == "2026-09-26T10:10:00Z")
        #expect(item.latestReplyFromFirstOptions)
    }

    @Test func aFirstSetReplyEncodesOptionsSet() throws {
        let params = ReplySubmitParams(
            caseId: "c1", idempotencyKey: "k", choice: "a", optionsSet: "first", message: nil,
            comments: [], captures: [], intent: .decision)
        let data = try JSONEncoder().encode(params)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["options_set"] as? String == "first")
        #expect(object["choice"] as? String == "a")
    }

    @Test func aPendingReplyKeepsItsOptionsSetAcrossARelaunch() throws {
        let reply = PendingReply(
            caseId: "c1", idempotencyKey: "k", choice: "a", message: nil, comments: [], captures: [],
            optionsSet: "first")
        let back = try JSONDecoder().decode(PendingReply.self, from: JSONEncoder().encode(reply))
        #expect(back.optionsSet == "first")
        let old = #"{"case_id":"c1","idempotency_key":"k","choice":"a","comments":[],"captures":[]}"#
        #expect(try JSONDecoder().decode(PendingReply.self, from: Data(old.utf8)).optionsSet == nil)
    }
}
