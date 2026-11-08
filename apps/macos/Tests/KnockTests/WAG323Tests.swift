import AppKit
import Testing
@testable import Knock

/// WAG-323: flip through a screenshots set in the artifact box.
@MainActor
struct WAG323Tests {
    // MARK: Index model

    @Test func nextAndPreviousMoveOneScreen() {
        var index = ScreenSetIndex(count: 5, current: 2)
        let next = index.step(by: 1)
        #expect(next)
        #expect(index.current == 3)
        index.step(by: -1)
        index.step(by: -1)
        #expect(index.current == 1)
    }

    @Test func theEndsDoNotWrap() {
        var index = ScreenSetIndex(count: 3)
        #expect(!index.canGoPrevious)
        let backAtStart = index.step(by: -1)
        #expect(!backAtStart)
        #expect(index.current == 0)
        index.jump(to: 2)
        #expect(!index.canGoNext)
        let pastEnd = index.step(by: 1)
        #expect(!pastEnd)
        #expect(index.current == 2)
    }

    @Test func jumpGoesToThatScreenAndHoldsToTheBounds() {
        var index = ScreenSetIndex(count: 5)
        let moved = index.jump(to: 3)
        #expect(moved)
        #expect(index.current == 3)
        let same = index.jump(to: 3)
        #expect(!same)
        index.jump(to: 99)
        #expect(index.current == 4)
        index.jump(to: -4)
        #expect(index.current == 0)
    }

    @Test func anEmptySetHasNothingToStepTo() {
        var index = ScreenSetIndex(count: 0)
        #expect(!index.canGoNext && !index.canGoPrevious)
        let moved = index.step(by: 1)
        #expect(!moved)
        #expect(index.current == 0)
    }

    @Test func aNewSetKeepsThePositionHeldToTheNewCount() {
        var index = ScreenSetIndex(count: 5, current: 4)
        index.reset(count: 3)
        #expect(index.current == 2 && index.count == 3)
        index.reset(count: 8)
        #expect(index.current == 2 && index.count == 8)
    }

    // MARK: Revision reset

    private func images(_ captions: [String]) -> [(image: NSImage, caption: String?)] {
        captions.map { (image: NSImage(), caption: $0) }
    }

    /// The bug of 8 Oct: v1 had 3 screens, v3 has 4. A store that held v1 kept v1's screens when full size
    /// loaded v3, so the box and full size said "v3 · latest" over v1's three items.
    @Test func aNewRevisionOfASetReplacesTheScreensOfTheStore() {
        let store = CommentsSessionStore()
        store.addScreenshotsCaptures(images: images(["a", "b", "c"]), revision: 1)
        #expect(store.screens.count == 3)

        let added = store.addScreenshotsCaptures(images: images(["a", "b", "c", "d"]), revision: 3)

        #expect(added.count == 4)
        #expect(store.screens.count == 4)
        #expect(store.screensRevision == 3)
        #expect(store.shownStill(revision: 3) != nil)
        #expect(store.shownStill(revision: 1) == nil)
        #expect(store.screens.map { store.screenTitle(for: $0) } == ["a", "b", "c", "d"])
    }

    @Test func theSameRevisionIsNotLoadedTwice() {
        let store = CommentsSessionStore()
        store.addScreenshotsCaptures(images: images(["a", "b"]), revision: 2)
        let again = store.addScreenshotsCaptures(images: images(["a", "b"]), revision: 2)
        #expect(again.isEmpty)
        #expect(store.screens.count == 2)
    }

    @Test func aCommentedScreenOfAnOldRevisionStaysButLeavesTheSet() {
        let store = CommentsSessionStore()
        let old = store.addScreenshotsCaptures(images: images(["a", "b", "c"]), revision: 1)
        store.selectCapture(id: old[1].id)
        store.beginDraft(rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.2))
        store.updateDraftText("Tight")
        store.commitDraft()

        store.addScreenshotsCaptures(images: images(["a", "b", "c", "d"]), revision: 3)

        #expect(store.screens.count == 4)
        #expect(store.model.comments.count == 1)
        #expect(store.model.comments[0].captureId == old[1].id)
    }

    // MARK: Tab overflow rule

    @Test func tabsKeepTheirOwnWidthWhenTheyFit() {
        let widths = ArtifactTabWidths.fit(natural: [80, 90, 70], available: 300, spacing: 6)
        #expect(widths == [80, 90, 70])
    }

    @Test func tabsShrinkEvenlyWhenTheyDoNot() {
        let widths = ArtifactTabWidths.fit(natural: [200, 200, 200, 200], available: 626, spacing: 6)
        #expect(widths == [152, 152, 152, 152])
        #expect(widths.reduce(0, +) + 18 <= 626)
    }

    @Test func aShortTabKeepsItsWidthAndTheLongOnesShareTheRest() {
        let widths = ArtifactTabWidths.fit(natural: [60, 300, 300], available: 412, spacing: 6)
        #expect(widths[0] == 60)
        #expect(widths[1] == widths[2])
        #expect(abs(widths.reduce(0, +) + 12 - 412) < 0.01)
    }

    @Test func aTabNeverShrinksBelowTheFloor() {
        let widths = ArtifactTabWidths.fit(natural: [200, 200, 200, 200], available: 100, spacing: 6)
        #expect(widths.allSatisfy { $0 == ArtifactTabWidths.minimum })
    }

    // MARK: The box steps through the store

    private func box(revision: Int = 1, count: Int = 5) -> (LiveArtifactModel, CommentsSessionStore) {
        let store = CommentsSessionStore()
        store.addScreenshotsCaptures(images: images((1...count).map { "s\($0)" }), revision: revision)
        let tab = ArtifactTab(id: "name:flow", title: "Flow", revision: revision, kind: .screenshots, hasName: true, revisions: [revision])
        let model = LiveArtifactModel(
            caseId: "c1", client: KnockClient(socketPath: "/nonexistent.sock", startDaemon: {}), tabs: [tab], commentsStore: store)
        return (model, store)
    }

    @Test func theBoxStepsThroughTheSetWithoutWrapping() {
        let (model, store) = box()
        #expect(model.isFlippable(model.selectedTab))
        model.stepScreen(by: -1)
        #expect(store.shownStill(revision: 1)?.id == store.screens[0].id)
        for _ in 0..<10 { model.stepScreen(by: 1) }
        #expect(store.shownStill(revision: 1)?.id == store.screens[4].id)
        model.stepScreen(by: -1)
        #expect(store.shownStill(revision: 1)?.id == store.screens[3].id)
    }

    @Test func aSingleScreenshotIsNotFlippable() {
        let store = CommentsSessionStore()
        store.addCapture(image: NSImage(), revision: 1, isBase: true)
        let tab = ArtifactTab(id: "kind:screenshot", title: "Screenshot", revision: 1, kind: .screenshot, hasName: false, revisions: [1])
        let model = LiveArtifactModel(
            caseId: "c1", client: KnockClient(socketPath: "/nonexistent.sock", startDaemon: {}), tabs: [tab], commentsStore: store)
        #expect(!model.isFlippable(model.selectedTab))
    }

    @Test func arrowKeysWaitWhileANoteIsOpen() {
        let (model, store) = box()
        #expect(model.allowsScreenKeys)
        store.beginDraft(rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.2))
        #expect(!model.allowsScreenKeys)
    }

    @Test func aNewRevisionOfTheSameNameShowsTheNewItemsInTheBox() {
        let (model, store) = box(revision: 1, count: 3)
        let tab = ArtifactTab(id: "name:flow", title: "Flow", revision: 3, kind: .screenshots, hasName: true, revisions: [1, 3])
        model.update(tabs: [tab])
        store.addScreenshotsCaptures(images: images(["a", "b", "c", "d"]), revision: 3)
        #expect(model.selectedTab?.revision == 3)
        #expect(store.shownStill(revision: 3) != nil)
        #expect(store.screens.count == 4)
    }
}

// WAG-340: the arrows reach the box without a click in it first.
@MainActor
struct WAG340Tests {
    private func flips(
        flippable: Bool = true, notes: Bool = true, text: Bool = false, fullSize: Bool = false, sheet: Bool = false
    ) -> Bool {
        CaseScreenKeys.flips(
            isFlippable: flippable, allowsScreenKeys: notes, textInputFocused: text, fullSizeOpen: fullSize, sheetOpen: sheet)
    }

    @Test func arrowsGoToTheBoxWhenNoTextFieldHasFocus() { #expect(flips()) }
    @Test func arrowsStayWithTheComposer() { #expect(!flips(text: true)) }
    @Test func arrowsStayWithFullSize() { #expect(!flips(fullSize: true)) }
    @Test func arrowsStayWithASheet() { #expect(!flips(sheet: true)) }
    @Test func aCaseWithoutScreenshotsIgnoresArrows() { #expect(!flips(flippable: false)) }
    @Test func arrowsWaitWhileANoteIsOpen() { #expect(!flips(notes: false)) }

    @Test func onlyPlainLeftAndRightMap() {
        #expect(CaseScreenKeys.delta(keyCode: 123, modifiers: []) == -1)
        #expect(CaseScreenKeys.delta(keyCode: 124, modifiers: [.numericPad, .function]) == 1)
        #expect(CaseScreenKeys.delta(keyCode: 125, modifiers: []) == nil)
        #expect(CaseScreenKeys.delta(keyCode: 124, modifiers: .command) == nil)
    }

    /// Evidence: a simulated → on a 7-screen set at 3/7 with nothing focused moves to 4/7. Set
    /// `KNOCK_EVIDENCE_FILE` to write the before and after lines.
    @Test func rightArrowMovesThreeOfSevenToFourOfSeven() throws {
        let store = CommentsSessionStore()
        store.addScreenshotsCaptures(images: (1...7).map { (image: NSImage(), caption: "s\($0)") }, revision: 1)
        let tab = ArtifactTab(id: "name:flow", title: "Flow", revision: 1, kind: .screenshots, hasName: true, revisions: [1])
        let model = LiveArtifactModel(
            caseId: "c1", client: KnockClient(socketPath: "/nonexistent.sock", startDaemon: {}), tabs: [tab], commentsStore: store)
        store.selectCapture(id: store.screens[2].id)
        func position() -> String { "\((store.screens.firstIndex { $0.id == store.shownStill(revision: 1)?.id } ?? -1) + 1) / 7" }
        let before = position()
        if let delta = CaseScreenKeys.delta(keyCode: 124, modifiers: []),
           CaseScreenKeys.flips(isFlippable: model.isFlippable(model.selectedTab), allowsScreenKeys: model.allowsScreenKeys,
                                textInputFocused: false, fullSizeOpen: false, sheetOpen: false) {
            model.stepScreen(by: delta)
        }
        let after = position()
        #expect(before == "3 / 7")
        #expect(after == "4 / 7")
        if let path = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_FILE"] {
            try "before: \(before)\nafter right arrow, nothing focused: \(after)\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
