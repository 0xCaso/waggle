import AppKit
import SwiftUI
import UserNotifications

/// Title of the M1 setup window's `Window` scene below, used to find its
/// `NSWindow` from AppKit code (`KnockAppDelegate`, the app-menu command):
/// `KnockApp.body` builds `Scene`s, not `View`s, so the SwiftUI
/// `openWindow`/`dismissWindow` environment actions have nowhere to live
/// here.
let onboardingWindowTitle = "Set up Waggle"

@main
struct KnockApp: App {
    @NSApplicationDelegateAdaptor(KnockAppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var onboardingModel: OnboardingModel

    init() {
        AppAppearance.apply()
        FontRegistration.registerBundledFonts()
        let model = AppModel(client: KnockClient(socketPath: KnockClient.defaultSocketPath()))
        _model = StateObject(wrappedValue: model)
        // WAG-366: the screens with no `AppModel` report through this one reporter.
        UsageReporter.current = model.usage
        model.usage.record(.appLaunched)
        // The Knock Claude Code mod's "open" button (HAIL-134).
        model.onOpenRequested = { caseId in
            if let caseId {
                Task { await model.open(caseId: caseId) }
            } else if let next = model.needsYouCases.first {
                // "queue": the ask at the top of the queue, which is another session's.
                Task { await model.open(caseId: next.id) }
            } else {
                model.goHome()
            }
            AppActivation.showMainWindow()
        }
        let gettingStarted = GettingStartedModel()
        gettingStarted.onOpenCase = { caseId in
            Task { await model.open(caseId: caseId) }
            AppActivation.showMainWindow()
        }
        gettingStarted.onRequestNotifications = {
            // Evidence copies fake the permission: never ask the system.
            guard NotificationPermissionObserver.evidenceOverride() == nil else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: NotificationAuthorization.options) { _, _ in
                Task { @MainActor in await NotificationPermissionObserver.shared.refresh() }
            }
        }
        gettingStarted.onOpenJobPicker = { NotificationCenter.default.post(name: .knockOpenJobPicker, object: nil) }
        gettingStarted.onOpenAgents = { NotificationCenter.default.post(name: .knockShowSettingsPage, object: SettingsPage.agents) }
        gettingStarted.onOpenDesignKit = { NotificationCenter.default.post(name: .knockShowSettingsPage, object: SettingsPage.artifacts) }
        gettingStarted.observe(model)
        _onboardingModel = StateObject(wrappedValue: OnboardingModel(
            askPreferences: model.askPreferences,
            gettingStarted: gettingStarted,
            loadSessions: { (try? await model.client.sessionsList()) ?? [] },
            loadCases: {
                async let needsYou = model.client.casesList(status: .needsYou)
                async let waiting = model.client.casesList(status: .waitingOnAgent)
                return ((try? await needsYou) ?? []) + ((try? await waiting) ?? [])
            },
            sendPrompt: { sessionId, text in try await model.client.sessionSendPrompt(sessionId: sessionId, text: text) },
            markOnboarded: { OnboardingState.markOnboarded() },
            onFirstJobStarted: {
                // The short window closes and the main window opens on "Your agent is on it".
                AppActivation.showMainWindow()
                OnboardingWindowOpener.close()
            },
            onSkip: {
                AppActivation.showMainWindow()
                OnboardingWindowOpener.close()
            }
        ))
        // Start the Sparkle updater at launch so automatic checks run (KNOCK-21).
        _ = Updater.controller
        // e2e only: force one immediate background check when asked (KNOCK-21).
        Updater.checkNowIfRequested()
        // WAG-318: one check on every start, then the prompt.
        Updater.scheduleLaunchCheck()
        // The app-activation refresh (contract: "...and when the app becomes
        // active") is app-wide, not per-window, so it registers once here.
        NotificationPermissionObserver.shared.observeActivation()
        // Pays WebKit's one-time WebContent-process spin-up during launch,
        // not on the operator's first click that reveals an html_bundle
        // (HAIL-47 - see `IsolationGate.prewarmWebViewIfNeeded`).
        Task { await IsolationGate.shared.prewarmWebViewIfNeeded() }
    }

    var body: some Scene {
        WindowGroup(id: AppActivation.mainWindowSceneID) {
            MainWindowView(
                model: model, coachMarkTour: onboardingModel.coachMarkTour,
                firstRun: onboardingModel.gettingStarted, onTrySample: onboardingModel.runSample)
                .onAppear { appDelegate.attach(to: model) }
                .onOpenURL { url in
                    guard let id = AppDeepLink.caseId(from: url) else { return }
                    AppActivation.showMainWindow()
                    Task { await model.open(caseId: id) }
                }
                .background(OnboardingLaunchGate(onboardingModel: onboardingModel))
                .background(SettingsLaunchGate())
                .background(MainWindowOpenBridge())
                .background(MainWindowRegistrar())
        }
        .defaultSize(width: 1440, height: 900)
        // M3/M11 draw the traffic lights inline in the Inbox list's header,
        // not in a separate titlebar (docs/design/mvp-values.md §2.1,
        // Amendments). This keeps the real system buttons - full close/
        // minimize/zoom behaviour for free - and only asks QueueListView to
        // leave room for them instead of drawing decorative stand-ins.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // HAIL-176: the standard About panel, with the tagline as its credits line.
            CommandGroup(replacing: .appInfo) {
                Button("About Waggle") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: AppTagline.text,
                            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
                        ),
                    ])
                }
            }
            // The Help menu brings the getting started list back (WAG-338).
            CommandGroup(after: .help) {
                GettingStartedMenuCommand(gettingStarted: onboardingModel.gettingStarted)
            }
            CommandGroup(after: .appInfo) {
                OnboardingMenuCommand(onboardingModel: onboardingModel)
                // Dev builds have no update key: disable the item and say why
                // (KNOCK-17 fold pass 2). `Updater.checkForUpdates()` is a no-op
                // in that case, so this is belt-and-braces on top of the guard.
                Button(Updater.isAvailable ? "Check for Updates…" : "Updates are off in development builds") {
                    Updater.checkForUpdates()
                }
                .disabled(!Updater.isAvailable)
            }
        }

        // "In its own window" on an artifact card (WAG-257).
        WindowGroup(id: ArtifactWindowRequest.sceneID, for: ArtifactWindowRequest.self) { $request in
            if let request {
                ArtifactWindowView(request: request, client: model.client, commentsStore: model.commentsStore(forCase: request.caseId))
            }
        }
        .defaultSize(width: 900, height: 700)

        Window(onboardingWindowTitle, id: "onboarding") {
            OnboardingWindowView(model: onboardingModel)
                .background(OnboardingAutoCloseGate())
                .background(MainWindowOpenBridge())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // The ⌘, Settings window (KNOCK-17; sidebar redesign HAIL-50). SwiftUI
        // adds the "Settings…" menu item with the ⌘, shortcut for a Settings
        // scene.
        Settings {
            SettingsView(client: model.client, askPreferences: model.askPreferences, onboardingModel: onboardingModel)
                .background(MainWindowOpenBridge())
        }
    }
}

/// A `Window` scene (unlike `WindowGroup`) is not guaranteed to open
/// automatically at launch - that default is not consistent across macOS
/// versions, and this app targets macOS 14+. Requesting it explicitly
/// through SwiftUI's `openWindow` action is what actually creates and shows
/// it, rather than relying on a launch default. This invisible view sits in
/// the main window's background purely to reach that environment action
/// once, when the main window appears (contract: "Shown on first launch (no
/// `onboarded` flag)").
private struct OnboardingLaunchGate: View {
    @Environment(\.openWindow) private var openWindow
    let onboardingModel: OnboardingModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                if OnboardingState.shouldShowAtLaunch() {
                    openWindow(id: "onboarding")
                }
            }
            // "Click to send another" on the getting started list: the job picker is step 2 of the short window.
            .onReceive(NotificationCenter.default.publisher(for: .knockOpenJobPicker)) { _ in
                OnboardingLaunchPolicy.requestExplicitOpen()
                onboardingModel.showFirstJobPicker()
                NSApp.activate()
                openWindow(id: "onboarding")
            }
    }
}

/// The app-menu "Set Up Knock…" command (contract: "'Set Up Knock…' in the
/// app menu restarts it"). `Window` scenes are singletons, so opening one
/// that is already open just brings it to front - `reset()` is what makes
/// this an actual restart back to O1 rather than resuming wherever the
/// tester left off, which also covers a tester who was already onboarded
/// (so nothing opened it at launch) by both creating the window and
/// starting it fresh.
/// Not `private`: `runSetupAgain` below is reused by the Settings window's
/// Agents and Help pages (HAIL-50).
struct OnboardingMenuCommand: View {
    @ObservedObject var onboardingModel: OnboardingModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Set Up Waggle…") {
            Self.runSetupAgain(onboardingModel: onboardingModel, openWindow: openWindow)
        }
    }

    /// The app-menu "Set Up Knock…" action, factored out so the Settings
    /// window's Agents and Help pages (HAIL-50, "Run setup again") trigger
    /// the exact same restart rather than a second copy that could drift.
    @MainActor
    static func runSetupAgain(onboardingModel: OnboardingModel, openWindow: OpenWindowAction) {
        OnboardingLaunchPolicy.requestExplicitOpen()
        onboardingModel.reset()
        NSApp.activate()
        openWindow(id: "onboarding")
    }
}

/// Finds the M1 setup window's `NSWindow` by title, so the "Done" button can
/// close it after `openWindow` created it.
@MainActor
enum OnboardingWindowOpener {
    static func close() {
        NSApp.windows.first { $0.title == onboardingWindowTitle }?.close()
    }
}

/// Evidence hook: `KNOCK_OPEN_SETTINGS=1` opens the ⌘, Settings window at
/// launch (the orchestrator cannot send the ⌘, keystroke to a real app). Like
/// `OnboardingLaunchGate`, it is a zero-size view in the main window's
/// background that exists only to reach the `openSettings` environment action.
private struct SettingsLaunchGate: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                if ProcessInfo.processInfo.environment["KNOCK_OPEN_SETTINGS"] == "1" {
                    openSettings()
                }
            }
            // The list's "Add" and "Connect" lines open Settings on their page (WAG-338).
            .onReceive(NotificationCenter.default.publisher(for: .knockShowSettingsPage)) { _ in openSettings() }
    }
}

/// Keeps the onboarding window from ever coming back on its own (HAIL-92).
///
/// Cause: after a Sparkle relaunch, macOS restored (or macOS 15 auto-presented)
/// the `Window` scene. The old guard called `dismissWindow(id:)` from `.onAppear`,
/// which can run before the scene has registered the window, so the call did
/// nothing and an onboarded user saw the setup window (already past step 1,
/// because the connect steps skip themselves). This guard works on the
/// `NSWindow` itself: it turns off restoration so macOS stops bringing the
/// window back, and it closes the window directly when the launch policy says
/// nobody asked for it, retrying on the next run loop turns in case the window
/// is not yet on screen.
private struct OnboardingAutoCloseGate: NSViewRepresentable {
    final class Coordinator {
        var observed: NSWindow?
        var token: NSObjectProtocol?
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }

        /// Clears the one-shot request when the window closes.
        @MainActor
        func observe(_ window: NSWindow) {
            guard observed !== window else { return }
            if let token { NotificationCenter.default.removeObserver(token) }
            observed = window
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { OnboardingLaunchPolicy.windowDidClose() }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { coordinator.observe(window) }
            Self.guardWindow(view?.window, attempts: 3)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { context.coordinator.observe(window) }
        Self.guardWindow(nsView.window, attempts: 0)
    }

    @MainActor
    private static func guardWindow(_ window: NSWindow?, attempts: Int) {
        guard let window else { return }
        window.isRestorable = false
        if OnboardingLaunchPolicy.shouldCloseNow() {
            window.close()
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak window] in
                    guardWindow(window, attempts: attempts - 1)
                }
            }
        }
    }
}
