import Foundation

/// The onboarding window's launch behavior (KNOCK-17 fold pass 2). KNOCK-14 found
/// that on macOS 15+ SwiftUI auto-presents `Window` scenes at launch, so an
/// already-onboarded tester saw the setup window every time.
///
/// `SceneBuilder` has no `buildEither`, so the scene cannot apply macOS 15's
/// `.defaultLaunchBehavior(.suppressed)` conditionally while still returning the
/// plain scene on macOS 14 (which would raise the floor). Instead the window
/// closes itself in `.onAppear` when this policy says so; `OnboardingLaunchGate`
/// still opens it on purpose for a fresh install or `KNOCK_SHOW_ONBOARDING=1`.
enum OnboardingLaunchPolicy {
    /// Whether the onboarding window should close itself when it appears at
    /// launch: only when the launch gate did not mean to show it (already
    /// onboarded and not forced). Pure: it does not read or change the
    /// one-shot request (see `OnboardingExplicitOpen`).
    static func shouldCloseWhenShownAtLaunch(
        explicitlyRequested: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        // "Set Up Waggle…" opened it on purpose: never close it (operator,
        // 29 Sep: "Set Up Knock is not launching the setup").
        if explicitlyRequested { return false }
        return !OnboardingState.shouldShowAtLaunch(environment: environment)
    }

    /// The app's one request tracker. Only used on the main thread.
    nonisolated(unsafe) static var explicitOpen = OnboardingExplicitOpen()

    /// Ask for the window on purpose (menu command, "Click to send another").
    static func requestExplicitOpen() { explicitOpen.request() }

    /// Called when the window is on screen. True when it must close itself.
    static func shouldCloseNow(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        shouldCloseWhenShownAtLaunch(explicitlyRequested: explicitOpen.consume(), environment: environment)
    }

    /// Called when the window closes. Later appearances are automatic again.
    static func windowDidClose() { explicitOpen.windowDidClose() }
}

/// The explicit open request as a one-shot (WAG-348). One request keeps one
/// window open. The request is consumed by the window it opened and cleared
/// when that window closes, so a later automatic presentation (macOS 15
/// scene restoration, reactivation) closes again. Before this, the flag was
/// never reset and every later presentation stayed on screen.
struct OnboardingExplicitOpen {
    private var pending = false
    private var windowHeldOpen = false

    mutating func request() { pending = true }

    /// True while the window shows because of a request.
    mutating func consume() -> Bool {
        if pending {
            pending = false
            windowHeldOpen = true
        }
        return windowHeldOpen
    }

    mutating func windowDidClose() {
        pending = false
        windowHeldOpen = false
    }
}
