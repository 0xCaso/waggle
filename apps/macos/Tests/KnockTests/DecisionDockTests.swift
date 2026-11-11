import Testing
@testable import Knock

@Suite struct DecisionDockTests {
    @Test func theOptionsAreInTheDockOnEveryLayout() {
        for layout in [DecisionLayout.single, .step, .plan] {
            #expect(DecisionDock.optionsInDock(layout), "\(layout)")
        }
    }

    @Test func theReviewStepKeepsOnlySendInTheBar() {
        #expect(!DecisionDock.optionsInDock(.review))
    }

    @Test func theCapsFollowTheWindowHeight() {
        #expect(DecisionDock.cap(.step, windowHeight: 1000) == 400)
        #expect(DecisionDock.cap(.plan, windowHeight: 1000) == 450)
        #expect(DecisionDock.cap(.single, windowHeight: 1000) == nil)
        #expect(DecisionDock.cap(.step, windowHeight: 100) == DecisionDock.minCap)
    }

    @Test func theOpenMenuListsFullSizeWindowAndBrowserForAPage() {
        typealias Box = LiveArtifactBoxView
        #expect(Box.openItems(kind: .htmlBundle, hasWindow: true, hasBrowser: true) == [.fullSize, .window, .browser])
        #expect(Box.openItems(kind: .markdown, hasWindow: true, hasBrowser: true) == [.fullSize, .window])
        #expect(Box.openItems(kind: .htmlBundle, hasWindow: false, hasBrowser: false) == [.fullSize])
    }

    @Test func aLayoutIsReadFromTheDoc() {
        #expect(DecisionDock.layout(nil, hasPlanBesideArtifact: true) == .plan)
        #expect(DecisionDock.layout(nil, hasPlanBesideArtifact: false) == .single)
    }
}
