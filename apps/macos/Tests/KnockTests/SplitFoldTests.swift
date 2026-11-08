import Foundation
import SwiftUI
import Testing
@testable import Knock

/// HAIL-84: which layout an ask gets, the fold state and how it is remembered, and the strip copy.
@MainActor
struct SplitFoldTests {
    private func makeDefaults() -> UserDefaults {
        let name = "knock.splitfold.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeCase(options: Int = 2, lock: ReplyLockState = .editable) -> Case {
        let replyState: ReplyStatus? = switch lock {
        case .editable: nil
        case .queued: .queued
        case .delivered: .delivered
        case .failed: .failed
        }
        return Case(
            id: "c1", taskId: "t1", kind: .review, title: "T", need: "N", why: "W",
            recommendation: "o0", recommendationWhy: "RW",
            options: (0..<options).map { Option(id: "o\($0)", label: "Option \($0)") },
            status: lock == .editable ? .needsYou : .waitingOnAgent, hasArtifact: true,
            latestReplyId: replyState == nil ? nil : "r1", latestReplyState: replyState,
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z")
    }

    // MARK: fold state

    @Test func startsUnfolded() {
        let fold = SplitFoldState(defaults: makeDefaults(), environment: [:])
        #expect(!fold.isQueueFolded && !fold.isAskFolded && !fold.isBothFolded)
    }

    @Test func textPageQueueFoldIsRememberedAndShareTheQueueFold() {
        let defaults = makeDefaults()
        let first = SplitFoldState(defaults: defaults, environment: [:])
        first.toggleQueueFold()
        let second = SplitFoldState(defaults: defaults, environment: [:])
        #expect(second.isQueueFolded)
        // The one page's question fold is its own.
        #expect(!second.isAskFolded)
        second.toggleQueueFold()
        #expect(!SplitFoldState(defaults: defaults, environment: [:]).isQueueFolded)
    }

    @Test func aSavedConversationFoldNoLongerMattersWAG299() {
        // The old saved fold key stays in defaults but nothing reads it: the column starts closed.
        let defaults = makeDefaults()
        defaults.set(false, forKey: "knock.split.conversationFolded")
        let fold = SplitFoldState(defaults: defaults, environment: [:])
        #expect(!fold.isQueueFolded && !fold.isAskFolded && !fold.isBothFolded)
    }

    @Test func foldsAreRememberedAcrossLaunches() {
        let defaults = makeDefaults()
        let first = SplitFoldState(defaults: defaults, environment: [:])
        first.toggleQueue()
        first.toggleAsk()
        let second = SplitFoldState(defaults: defaults, environment: [:])
        #expect(second.isQueueFolded && second.isAskFolded && !second.isBothFolded)
        second.toggleQueue()
        #expect(!SplitFoldState(defaults: defaults, environment: [:]).isQueueFolded)
    }

    @Test func expandFoldsBothSidesAndRestoresTheFoldsBeforeIt() {
        let defaults = makeDefaults()
        let fold = SplitFoldState(defaults: defaults, environment: [:])
        fold.toggleAsk()
        fold.toggleBothFolded()
        #expect(fold.isQueueFolded && fold.isAskFolded && fold.isBothFolded)
        // It is remembered too.
        let relaunched = SplitFoldState(defaults: defaults, environment: [:])
        #expect(relaunched.isBothFolded && relaunched.isQueueFolded)
        relaunched.toggleBothFolded()
        #expect(!relaunched.isQueueFolded && !relaunched.isBothFolded)
        #expect(relaunched.isAskFolded, "the question column was folded before the expand")
    }

    @Test func expandRestoresTheTextPageFoldsToo() {
        let fold = SplitFoldState(defaults: makeDefaults(), environment: [:])
        fold.toggleQueueFold()
        fold.toggleBothFolded()
        fold.toggleBothFolded()
        #expect(fold.isQueueFolded && !fold.isAskFolded && !fold.isBothFolded)
    }

    @Test func touchingASideAfterExpandEndsBothFolded() {
        let fold = SplitFoldState(defaults: makeDefaults(), environment: [:])
        fold.toggleBothFolded()
        fold.toggleQueue()
        #expect(!fold.isBothFolded && !fold.isQueueFolded && fold.isAskFolded)
        fold.toggleBothFolded()
        #expect(fold.isBothFolded)
        fold.toggleAsk()
        #expect(!fold.isBothFolded && fold.isQueueFolded)
    }

    @Test func escapeRestoresOnlyWhileBothAreFolded() {
        let fold = SplitFoldState(defaults: makeDefaults(), environment: [:])
        fold.toggleQueue()
        fold.exitBothFolded()
        #expect(fold.isQueueFolded, "Esc does nothing when the icon did not fold")
        fold.toggleBothFolded()
        fold.exitBothFolded()
        #expect(!fold.isBothFolded && fold.isQueueFolded && !fold.isAskFolded)
    }

    @Test func aSavedFullPreviewBecomesBothFolded() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: SplitFoldState.legacyFullPreviewKey)
        defaults.set(true, forKey: SplitFoldState.askKey)
        let fold = SplitFoldState(defaults: defaults, environment: [:])
        #expect(fold.isBothFolded && fold.isQueueFolded && fold.isAskFolded)
        #expect(defaults.object(forKey: SplitFoldState.legacyFullPreviewKey) == nil)
        fold.toggleBothFolded()
        #expect(!fold.isQueueFolded && fold.isAskFolded, "the folds kept under full preview come back")
    }

    @Test func expandIconCopy() {
        #expect(BothFoldedCopy.help(isBothFolded: false) == "Fold both sides (⌘\\)")
        #expect(BothFoldedCopy.help(isBothFolded: true) == "Show both sides (⌘\\)")
        #expect(BothFoldedCopy.symbol(isBothFolded: true) != BothFoldedCopy.symbol(isBothFolded: false))
    }

    @Test func evidenceHookStartsFolded() {
        #expect(SplitFoldState(defaults: makeDefaults(), environment: ["KNOCK_SPLIT_FOLD": "queue"]).isQueueFolded)
        let ask = SplitFoldState(defaults: makeDefaults(), environment: ["KNOCK_SPLIT_FOLD": "ask"])
        #expect(ask.isAskFolded && !ask.isQueueFolded)
        let both = SplitFoldState(defaults: makeDefaults(), environment: ["KNOCK_SPLIT_FOLD": "both"])
        #expect(both.isQueueFolded && both.isAskFolded && !both.isBothFolded)
        #expect(SplitFoldState(defaults: makeDefaults(), environment: ["KNOCK_SPLIT_FOLD": "full"]).isBothFolded)
    }

    // MARK: keyboard

    @Test func foldShortcutsAreDistinctAndClashWithNoOtherShortcut() {
        let fold: [KeyboardShortcut] = [
            SplitFoldShortcuts.queue, SplitFoldShortcuts.ask, SplitFoldShortcuts.bothFolded,
        ]
        #expect(SplitFoldShortcuts.queue.key.character == "[" && SplitFoldShortcuts.queue.modifiers == .command)
        #expect(SplitFoldShortcuts.ask.key.character == "]" && SplitFoldShortcuts.ask.modifiers == .command)
        #expect(SplitFoldShortcuts.bothFolded.key.character == "\\" && SplitFoldShortcuts.bothFolded.modifiers == .command)
        #expect(Set(fold.map { "\($0.key.character)" }).count == 3)
        // Taken elsewhere: zoom, send, and the composer's ⌘D.
        let taken: Set<Character> = ["0", "1", "+", "=", "-", "d", "\r"]
        #expect(fold.allSatisfy { !taken.contains($0.key.character) })
        #expect(SplitFoldShortcuts.leaveBothFolded.key == .escape)
    }

    // MARK: header reserve

    @Test func headerKeepsClearOfTheTrafficLights() {
        #expect(SplitFoldHeaderView.leadingReserve(queueOpen: true, railShown: false) == 16)
        #expect(SplitFoldHeaderView.leadingReserve(queueOpen: false, railShown: true) == Theme.Spacing.listHeaderLeadingReserve - QueueFoldedRailView.width)
        #expect(SplitFoldHeaderView.leadingReserve(queueOpen: false, railShown: false) == Theme.Spacing.listHeaderLeadingReserve)
    }

    // MARK: strip copy

    @Test func stripSaysWhatTheAnswerNeeds() {
        #expect(AskStripCopy.label(for: makeCase(options: 2)) == "Decision · 2 options")
        #expect(AskStripCopy.label(for: makeCase(options: 1)) == "Decision · 1 option")
        #expect(AskStripCopy.label(for: makeCase(options: 0)) == "Decision")
        #expect(AskStripCopy.label(for: makeCase(lock: .queued)) == "Sent · waiting for the agent")
        #expect(AskStripCopy.label(for: makeCase(lock: .delivered)) == "Delivered")
        #expect(AskStripCopy.label(for: makeCase(lock: .failed)) == "Not delivered")
    }
}

@Suite("Panel toggle icon")
struct PanelToggleIconTests {
    @Test func dividerSitsOnTheControlledSide() {
        #expect(PanelFrameShape.dividerX(edge: .leading) < PanelFrameShape.size.width / 2)
        #expect(PanelFrameShape.dividerX(edge: .trailing) > PanelFrameShape.size.width / 2)
    }

    @Test func chevronPointsTheRequestedWayInTheLargerPart() {
        let rect = CGRect(origin: .zero, size: PanelFrameShape.size)
        for (edge, right) in [(HorizontalEdge.leading, false), (.leading, true), (.trailing, true), (.trailing, false)] {
            let box = PanelChevronShape(edge: edge, pointsRight: right).path(in: rect).boundingRect
            let divider = PanelFrameShape.dividerX(edge: edge)
            if edge == .leading { #expect(box.minX > divider) } else { #expect(box.maxX < divider) }
            #expect(box.minX >= 0 && box.maxX <= rect.width)
        }
        let left = PanelChevronShape(edge: .leading, pointsRight: false).path(in: rect)
        let tipX = left.boundingRect.minX
        #expect(left.contains(CGPoint(x: tipX + 0.01, y: rect.midY)) || tipX < left.boundingRect.midX)
    }
}

struct QueueFoldTests {
    @Test func theQueueFoldsWhenNeedsYouOrAnsweredHasAnAsk() {
        #expect(QueueFold.hasContent(needsYouCount: 1, answeredCount: 0))
        #expect(QueueFold.hasContent(needsYouCount: 0, answeredCount: 2))
        #expect(QueueFold.hasContent(needsYouCount: 3, answeredCount: 1))
        #expect(!QueueFold.hasContent(needsYouCount: 0, answeredCount: 0))
    }

    @Test func aSavedFoldAppliesOnlyWhileTheQueueHasContent() {
        #expect(QueueFold.isFolded(saved: true, hasContent: true))
        #expect(!QueueFold.isFolded(saved: true, hasContent: false), "no stuck rail on an empty queue")
        #expect(!QueueFold.isFolded(saved: false, hasContent: true))
    }
}
