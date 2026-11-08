import Combine
import Testing
@testable import Knock

/// HAIL-220: a keystroke in the reply field must not invalidate the views that observe the
/// composer (the ask column with its plan rounds and markdown). The typed text is published by
/// `composer.draft` alone, which only the reply field's own views observe.
@MainActor
struct ComposerKeystrokeTests {
    private static func item() -> Case {
        Case(
            id: "k1", taskId: "t1", kind: .review, title: "Layout",
            need: "Pick one", why: "Not a technical call",
            recommendation: "a", recommendationWhy: "It is faster",
            options: [Option(id: "a", label: "A"), Option(id: "b", label: "B")],
            status: .needsYou, hasArtifact: false,
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z")
    }

    @Test func typingDoesNotPublishFromTheComposer() {
        let composer = ComposerViewModel(knockCase: Self.item())
        var composerChanges = 0
        var draftChanges = 0
        let a = composer.objectWillChange.sink { composerChanges += 1 }
        let b = composer.draft.objectWillChange.sink { draftChanges += 1 }
        for index in 1...50 { composer.draftText = String(repeating: "x", count: index) }
        #expect(composerChanges == 0)
        #expect(draftChanges == 50)
        withExtendedLifetime((a, b)) {}
    }

    @Test func otherStateStillPublishesFromTheComposer() {
        let composer = ComposerViewModel(knockCase: Self.item())
        var composerChanges = 0
        let a = composer.objectWillChange.sink { composerChanges += 1 }
        composer.selectOption("b")
        #expect(composerChanges > 0)
        withExtendedLifetime(a) {}
    }

    @Test func theDraftSurvivesInTheSharedStore() {
        let store = ComposerDraftStore()
        let first = ComposerViewModel(knockCase: Self.item(), draftStore: store)
        first.draftText = "keep me"
        let second = ComposerViewModel(knockCase: Self.item(), draftStore: store)
        #expect(second.draftText == "keep me")
        #expect(second.draft.text == "keep me")
    }
}
