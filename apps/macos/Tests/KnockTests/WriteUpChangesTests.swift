import XCTest
@testable import Knock

final class WriteUpChangesTests: XCTestCase {
    private func store() -> ArtifactSeenStore {
        ArtifactSeenStore(defaults: UserDefaults(suiteName: "wag320-\(UUID().uuidString)")!)
    }

    // MARK: last seen version

    func testFirstOpenKnowsNoBaseline() {
        let s = store()
        let opened = s.open(caseId: "c1", artifact: "name:spec", revision: 7, surface: "box")
        XCTAssertNil(opened.base)
        XCTAssertFalse(opened.isFirstTime)
        XCTAssertEqual(s.record(caseId: "c1", artifact: "name:spec")?.seen, 7)
    }

    func testNewVersionKeepsTheLastSeenOneAsBaseline() {
        let s = store()
        _ = s.open(caseId: "c1", artifact: "name:spec", revision: 7, surface: "box")
        let opened = s.open(caseId: "c1", artifact: "name:spec", revision: 8, surface: "box")
        XCTAssertEqual(opened.base, 7)
        XCTAssertTrue(opened.isFirstTime)
    }

    func testFirstTimeLastsUntilTheSurfaceScrolled() {
        let s = store()
        _ = s.open(caseId: "c1", artifact: "a", revision: 7, surface: "box")
        _ = s.open(caseId: "c1", artifact: "a", revision: 8, surface: "box")
        let again = s.open(caseId: "c1", artifact: "a", revision: 8, surface: "box")
        XCTAssertEqual(again.base, 7)
        XCTAssertTrue(again.isFirstTime, "opening twice must not use it up")
        s.markScrolled(caseId: "c1", artifact: "a", surface: "box")
        let after = s.open(caseId: "c1", artifact: "a", revision: 8, surface: "box")
        XCTAssertEqual(after.base, 7)
        XCTAssertFalse(after.isFirstTime)
        XCTAssertTrue(after.isOn, "scrolling once does not turn the changes off")
        let full = s.open(caseId: "c1", artifact: "a", revision: 8, surface: "full")
        XCTAssertTrue(full.isFirstTime, "another surface keeps its own state")
    }

    func testANewerVersionStartsOnChangesAgain() {
        let s = store()
        _ = s.open(caseId: "c1", artifact: "a", revision: 7, surface: "box")
        _ = s.open(caseId: "c1", artifact: "a", revision: 8, surface: "box")
        s.dismiss(caseId: "c1", artifact: "a", surface: "box")
        s.markScrolled(caseId: "c1", artifact: "a", surface: "box")
        let next = s.open(caseId: "c1", artifact: "a", revision: 9, surface: "box")
        XCTAssertEqual(next.base, 8)
        XCTAssertTrue(next.isFirstTime)
        XCTAssertTrue(next.isOn)
    }

    func testPerCaseAndPerArtifact() {
        let s = store()
        _ = s.open(caseId: "c1", artifact: "a", revision: 7, surface: "box")
        XCTAssertNil(s.open(caseId: "c2", artifact: "a", revision: 8, surface: "box").base)
        XCTAssertNil(s.open(caseId: "c1", artifact: "b", revision: 8, surface: "box").base)
    }

    func testOpeningAnOlderVersionChangesNothing() {
        let s = store()
        _ = s.open(caseId: "c1", artifact: "a", revision: 7, surface: "box")
        _ = s.open(caseId: "c1", artifact: "a", revision: 8, surface: "box")
        _ = s.open(caseId: "c1", artifact: "a", revision: 7, surface: "box")
        XCTAssertEqual(s.record(caseId: "c1", artifact: "a")?.seen, 8)
    }

    // MARK: the toggle

    func testNoToggleForOneVersion() {
        XCTAssertNil(WriteUpChangesPlan.make(revisions: [3], shown: 3, lastSeenBase: nil, isFirstTime: false))
    }

    func testNoToggleOnAnOlderVersion() {
        XCTAssertNil(WriteUpChangesPlan.make(revisions: [6, 7, 8], shown: 7, lastSeenBase: nil, isFirstTime: false))
    }

    func testUnknownLastSeenFallsBackToThePreviousVersion() {
        let plan = WriteUpChangesPlan.make(revisions: [6, 7, 8], shown: 8, lastSeenBase: nil, isFirstTime: false)
        XCTAssertEqual(plan?.base, 7)
        XCTAssertEqual(plan?.opensAtFirstChange, false)
    }

    func testLastSeenVersionIsTheBaselineAndOpensOnChangesTheFirstTime() {
        let plan = WriteUpChangesPlan.make(revisions: [5, 6, 7, 8], shown: 8, lastSeenBase: 6, isFirstTime: true)
        XCTAssertEqual(plan?.base, 6)
        XCTAssertEqual(plan?.opensAtFirstChange, true)
    }

    func testLaterOpensStartOnFullText() {
        let plan = WriteUpChangesPlan.make(revisions: [7, 8], shown: 8, lastSeenBase: 7, isFirstTime: false)
        XCTAssertEqual(plan?.opensAtFirstChange, false)
        XCTAssertEqual(plan?.base, 7)
    }

    func testAMissingBaselineVersionFallsBack() {
        let plan = WriteUpChangesPlan.make(revisions: [7, 8], shown: 8, lastSeenBase: 3, isFirstTime: true)
        XCTAssertEqual(plan?.base, 7)
    }

    // MARK: the change list

    private let oldText = "## Goal\n\nA month view.\n\n## Edge cases\n\nA URL with no month opens the current month.\n\nA month outside the limits shows the current month.\n\n## Notes\n\nOld note about the grid layout here."
    private let newText = "## Goal\n\nA month view.\n\n## Edge cases\n\nA URL with no month opens the current month.\n\nA month outside the limits shows the nearest allowed month, with a note.\n\n## Checks before release\n\nThe calendar reads at 320 px wide.\n\n## Notes"

    func testChangeListKeepsOrderAndCount() {
        let result = WriteUpDiff.diff(old: oldText, new: newText)
        let list = WriteUpChangeList(result: result)
        let kinds = list.positions.map { result.entries[$0].change }
        XCTAssertEqual(list.count, kinds.count)
        XCTAssertEqual(list.positions, list.positions.sorted())
        XCTAssertEqual(kinds.first, .changed)
        XCTAssertTrue(kinds.contains(.added))
        XCTAssertTrue(kinds.contains(.removed))
        XCTAssertFalse(kinds.contains(.unchanged))
        XCTAssertEqual(result.entries[list.positions[0]].unit.text, "A month outside the limits shows the nearest allowed month, with a note.")
    }

    func testChangeCountTitle() {
        let list = WriteUpChangeList(result: WriteUpDiff.diff(old: oldText, new: newText))
        XCTAssertEqual(list.title(since: 7), "\(list.count) changes since v7")
        let one = WriteUpChangeList(result: WriteUpDiff.diff(old: "A.\n\nB.", new: "A.\n\nB.\n\nC is a new line of text."))
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.title(since: 3), "1 change since v3")
    }

    func testNextAndPreviousWrap() {
        let list = WriteUpChangeList(result: WriteUpDiff.diff(old: oldText, new: newText))
        let n = list.count
        XCTAssertGreaterThan(n, 1)
        XCTAssertEqual(list.step(from: nil, forward: true), 0)
        XCTAssertEqual(list.step(from: nil, forward: false), n - 1)
        XCTAssertEqual(list.step(from: 0, forward: true), 1)
        XCTAssertEqual(list.step(from: n - 1, forward: true), 0)
        XCTAssertEqual(list.step(from: 0, forward: false), n - 1)
        XCTAssertEqual(list.step(from: 2, forward: false), 1)
    }

    func testNoChangeState() {
        let result = WriteUpDiff.diff(old: oldText, new: oldText)
        let list = WriteUpChangeList(result: result)
        XCTAssertEqual(list.count, 0)
        XCTAssertNil(list.step(from: nil, forward: true))
        XCTAssertNil(list.step(from: 0, forward: false))
        XCTAssertEqual(result.summary(since: 7), "Nothing changed since v7.")
    }

    @MainActor
    func testModelStepsAndWraps() {
        let result = WriteUpDiff.diff(old: oldText, new: newText)
        let plan = WriteUpChangesPlan(base: 7, opensAtFirstChange: false)
        let model = WriteUpChangesModel(plan: plan, result: result, store: store())
        let list = WriteUpChangeList(result: result)
        XCTAssertTrue(model.showsInline)
        XCTAssertEqual(model.countTitle, list.title(since: 7))
        model.next()
        XCTAssertEqual(model.scrollRequest?.entry, list.positions[0])
        XCTAssertEqual(model.flashRequest?.entry, list.positions[0])
        model.previous()
        XCTAssertEqual(model.scrollRequest?.entry, list.positions[list.count - 1], "up from the first wraps to the last")
        model.next()
        XCTAssertEqual(model.scrollRequest?.entry, list.positions[0], "down from the last wraps to the first")
    }

    @MainActor
    func testNoChangeModelShowsNoCountAndNoInline() {
        let result = WriteUpDiff.diff(old: oldText, new: oldText)
        let model = WriteUpChangesModel(plan: WriteUpChangesPlan(base: 7, opensAtFirstChange: true), result: result, store: store())
        XCTAssertFalse(model.showsInline)
        XCTAssertNil(model.countTitle)
        model.next()
        XCTAssertNil(model.scrollRequest)
    }

    @MainActor
    func testFirstSeenVersionOpensAtFirstChangeOnce() {
        let s = store()
        _ = s.open(caseId: "case", artifact: "artifact", revision: 7, surface: "box")
        let result = WriteUpDiff.diff(old: oldText, new: newText)
        let model = WriteUpChangesModel(plan: WriteUpChangesPlan(base: 7, opensAtFirstChange: true), result: result, store: s)
        model.openAtFirstChangeIfNeeded()
        XCTAssertEqual(model.scrollRequest?.entry, WriteUpChangeList(result: result).positions[0])
        let token = model.scrollRequest?.token
        model.openAtFirstChangeIfNeeded()
        XCTAssertEqual(model.scrollRequest?.token, token, "it scrolls once")
        let later = WriteUpChangesModel(plan: WriteUpChangesPlan(base: 7, opensAtFirstChange: false), result: result, store: s)
        later.openAtFirstChangeIfNeeded()
        XCTAssertNil(later.scrollRequest)
    }

    @MainActor
    func testSwitchOffHidesCountAndInlineAndOnRestores() {
        let result = WriteUpDiff.diff(old: oldText, new: newText)
        let model = WriteUpChangesModel(plan: WriteUpChangesPlan(base: 7, opensAtFirstChange: false), result: result, store: store())
        XCTAssertTrue(model.isOn)
        model.setShowChanges(false)
        XCTAssertFalse(model.showsInline)
        XCTAssertNil(model.countTitle)
        XCTAssertTrue(model.hasChanges, "the switch stays so it can go back on")
        model.setShowChanges(true)
        XCTAssertTrue(model.showsInline)
        XCTAssertNotNil(model.countTitle)
    }

    @MainActor
    func testSwitchChoiceSurvivesANewModelAndANewVersionStartsOn() {
        let s = store()
        _ = s.open(caseId: "case", artifact: "artifact", revision: 7, surface: "box")
        _ = s.open(caseId: "case", artifact: "artifact", revision: 8, surface: "box")
        let result = WriteUpDiff.diff(old: oldText, new: newText)
        let plan = WriteUpChangesPlan(base: 7, opensAtFirstChange: false)
        WriteUpChangesModel(plan: plan, result: result, store: s).setShowChanges(false)
        XCTAssertFalse(WriteUpChangesModel(plan: plan, result: result, store: s).isOn)
        XCTAssertFalse(s.open(caseId: "case", artifact: "artifact", revision: 8, surface: "box").isOn)
        WriteUpChangesModel(plan: plan, result: result, store: s).setShowChanges(true)
        XCTAssertTrue(WriteUpChangesModel(plan: plan, result: result, store: s).isOn)
        WriteUpChangesModel(plan: plan, result: result, store: s).setShowChanges(false)
        XCTAssertTrue(s.open(caseId: "case", artifact: "artifact", revision: 9, surface: "box").isOn)
    }

    @MainActor
    func testFirstOpenScrollsAndKeepsChangesOn() {
        let s = store()
        _ = s.open(caseId: "case", artifact: "artifact", revision: 7, surface: "box")
        let result = WriteUpDiff.diff(old: oldText, new: newText)
        let model = WriteUpChangesModel(plan: WriteUpChangesPlan(base: 7, opensAtFirstChange: true), result: result, store: s)
        model.openAtFirstChangeIfNeeded()
        XCTAssertNotNil(model.scrollRequest)
        XCTAssertTrue(model.showsInline)
        XCTAssertTrue(s.isOn(caseId: "case", artifact: "artifact", revision: 8, surface: "box"))
    }

    func testARecordFromBeforeTheSwitchOpensWithChangesOn() throws {
        let defaults = UserDefaults(suiteName: "wag408-\(UUID().uuidString)")!
        let old = #"{"seen":8,"base":7,"baseFor":8,"dismissed":["box"]}"#
        defaults.set(Data(old.utf8), forKey: "waggle.writeUpSeen.c1.a")
        let opened = ArtifactSeenStore(defaults: defaults).open(caseId: "c1", artifact: "a", revision: 8, surface: "box")
        XCTAssertEqual(opened.base, 7)
        XCTAssertTrue(opened.isOn)
        XCTAssertFalse(opened.isFirstTime)
    }

    // MARK: words of a changed block

    func testChangedBlockRunsPutRemovedWordsBeforeTheWordsThatReplaceThem() {
        let result = WriteUpDiff.diff(
            old: "A month outside the limits in the URL shows the current month.",
            new: "A month outside the limits in the URL shows the nearest allowed month, with a note.")
        let entry = try! XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.change, .changed)
        let runs = WriteUpWordRun.runs(for: entry)
        let firstChange = try! XCTUnwrap(runs.firstIndex { $0.kind != .plain })
        XCTAssertEqual(runs[firstChange].kind, .removed, "removed words come first")
        XCTAssertEqual(runs[firstChange].text, "current")
        let firstAdded = try! XCTUnwrap(runs.firstIndex { $0.kind == .added })
        XCTAssertGreaterThan(firstAdded, firstChange)
        XCTAssertEqual(runs[firstAdded].text, "nearest")
        XCTAssertTrue(runs[..<firstChange].allSatisfy { $0.kind == .plain })
        // The added and plain words, in order, read as the new text.
        let kept = runs.filter { $0.kind != .removed }.reduce("") { $0 + ($1.glued || $0.isEmpty ? "" : " ") + $1.text }
        XCTAssertEqual(kept, "A month outside the limits in the URL shows the nearest allowed month, with a note.")
    }

    func testAddedBlockIsAllAddedWords() {
        let result = WriteUpDiff.diff(old: "One.", new: "One.\n\nThe calendar reads at 320 px wide.")
        let added = try! XCTUnwrap(result.entries.first { $0.change == .added })
        let runs = WriteUpWordRun.runs(for: added)
        XCTAssertEqual(runs.map(\.text), ["The", "calendar", "reads", "at", "320", "px", "wide."])
        XCTAssertTrue(runs.allSatisfy { $0.kind == .added })
        XCTAssertEqual(runs.map(\.joinsPrev), [false] + Array(repeating: true, count: 6), "one highlight runs across the block")
        XCTAssertEqual(runs.map(\.joinsNext), Array(repeating: true, count: 6) + [false])
    }

    func testAPunctuationMarkSticksToTheWordBeforeIt() {
        let entry = WriteUpDiff.Entry(
            change: .changed,
            unit: WriteUpDiff.Unit(kind: .paragraph, level: 0, ordered: false, index: 0, text: "Shows March."),
            segments: [WriteUpDiff.Segment(kind: .same, text: "Shows "), WriteUpDiff.Segment(kind: .added, text: "March"),
                       WriteUpDiff.Segment(kind: .same, text: ".")])
        let runs = WriteUpWordRun.runs(for: entry)
        XCTAssertEqual(runs.map(\.text), ["Shows", "March", "."])
        XCTAssertEqual(runs.map(\.glued), [false, false, true])
    }

    func testTabsCarryTheirRevisionNumbers() {
        func rev(_ n: Int, _ name: String) -> Revision {
            Revision(id: "r\(n)", caseId: "c", n: n, createdAt: "2026-10-08T10:00:00Z", name: name, kind: .markdown)
        }
        let tabs = ArtifactTabs.tabs(revisions: [rev(1, "Spec"), rev(2, "Other"), rev(3, "Spec")])
        XCTAssertEqual(tabs.first { $0.title == "Spec" }?.revisions, [1, 3])
        XCTAssertEqual(ArtifactTabs.revisionNumbers(holding: 3, revisions: [rev(1, "Spec"), rev(2, "Other"), rev(3, "Spec")]), [1, 3])
    }
}
