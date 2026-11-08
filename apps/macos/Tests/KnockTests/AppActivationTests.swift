import Testing
@testable import Knock

/// HAIL-24: the "show Knock" decision logic - front an existing main window,
/// open one through a live SwiftUI root's bridge, or ask the app to reopen
/// when no SwiftUI view is alive at all - unit-tested with injected closures
/// so it never touches a real `NSWindow`/window server.
@MainActor
struct AppActivationTests {
    @Test func decideFrontsAnExistingMainWindowRegardlessOfTheBridge() {
        #expect(AppActivation.decide(hasMainWindow: true, hasOpenWindowBridge: true) == .front)
        #expect(AppActivation.decide(hasMainWindow: true, hasOpenWindowBridge: false) == .front)
    }

    @Test func decideOpensThroughTheBridgeWhenNoMainWindowExistsButARootIsAlive() {
        #expect(AppActivation.decide(hasMainWindow: false, hasOpenWindowBridge: true) == .openWindow)
    }

    @Test func decideReopensWhenNoMainWindowExistsAndNoSwiftUIRootIsAlive() {
        #expect(AppActivation.decide(hasMainWindow: false, hasOpenWindowBridge: false) == .reopen)
    }

    private final class Recorder {
        private(set) var fronted = false
        private(set) var openedIds: [String] = []
        private(set) var reopened = false

        func front() { fronted = true }
        func openWindow(_ id: String) { openedIds.append(id) }
        func reopen() { reopened = true }
    }

    @Test func showMainWindowFrontsTheExistingWindowWithoutOpeningOrReopening() {
        let recorder = Recorder()
        AppActivation.showMainWindow(
            hasMainWindow: { true },
            front: { recorder.front() },
            hasOpenWindowBridge: { true },
            openWindow: { recorder.openWindow($0) },
            reopen: { recorder.reopen() }
        )
        #expect(recorder.fronted)
        #expect(recorder.openedIds.isEmpty)
        #expect(!recorder.reopened)
    }

    @Test func showMainWindowOpensTheMainSceneIdWhenNoneExistsButABridgeIsLive() {
        let recorder = Recorder()
        AppActivation.showMainWindow(
            hasMainWindow: { false },
            front: { recorder.front() },
            hasOpenWindowBridge: { true },
            openWindow: { recorder.openWindow($0) },
            reopen: { recorder.reopen() }
        )
        #expect(!recorder.fronted)
        #expect(recorder.openedIds == [AppActivation.mainWindowSceneID])
        #expect(!recorder.reopened)
    }

    @Test func showMainWindowReopensWhenNoneExistsAndNoBridgeIsLive() {
        let recorder = Recorder()
        AppActivation.showMainWindow(
            hasMainWindow: { false },
            front: { recorder.front() },
            hasOpenWindowBridge: { false },
            openWindow: { recorder.openWindow($0) },
            reopen: { recorder.reopen() }
        )
        #expect(!recorder.fronted)
        #expect(recorder.openedIds.isEmpty)
        #expect(recorder.reopened)
    }

    @Test func showMainWindowNeverOpensASecondMainWindowWhenOneAlreadyExists() {
        // Even when a bridge happens to be available too, an existing main
        // window must win outright - `decide` never returns `.openWindow` or
        // `.reopen` alongside `hasMainWindow: true` (contract: "It never
        // creates a second main window when one exists").
        let recorder = Recorder()
        AppActivation.showMainWindow(
            hasMainWindow: { true },
            front: { recorder.front() },
            hasOpenWindowBridge: { true },
            openWindow: { recorder.openWindow($0) },
            reopen: { recorder.reopen() }
        )
        #expect(recorder.openedIds.isEmpty)
        #expect(!recorder.reopened)
    }
}
