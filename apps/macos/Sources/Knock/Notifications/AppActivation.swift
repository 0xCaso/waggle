import AppKit
import SwiftUI

/// Brings Knock's main window to the front, creating it first when none
/// exists. Used by the setup window's Open (after `model.open(caseId:)`),
/// the menu bar "Open Knock", and a notification click (contract: "Make
/// every 'show Knock' path create the main window when none exists, then
/// bring it to the front with the right case open").
///
/// `KnockApp.body` builds `Scene`s, not `View`s, so it has no SwiftUI
/// `openWindow` environment action of its own. `MainWindowOpenBridge`
/// (KnockApp.swift) registers that action here from every live SwiftUI root
/// (main window, setup window, Settings) so this enum can reach it.
@MainActor
enum AppActivation {
    /// `WindowGroup(id: mainWindowSceneID)` in `KnockApp.body`.
    static let mainWindowSceneID = "main"

    /// Set (and cleared) by `MainWindowOpenBridge` while at least one
    /// SwiftUI root is alive.
    static var openMainWindowAction: ((String) -> Void)?

    enum Decision: Equatable {
        /// A main window already exists: front it.
        case front
        /// None exists, but a live SwiftUI root can open one.
        case openWindow
        /// None exists and no SwiftUI view is alive (only the menu bar):
        /// ask the running app to reopen, which SwiftUI then answers by
        /// creating the `WindowGroup` window itself.
        case reopen
    }

    /// The branch itself, with no AppKit/SwiftUI in the loop so it is
    /// unit-testable on its own (docs/stories/HAIL-24.md: "the decision
    /// logic ... is unit-tested with injected closures").
    static func decide(hasMainWindow: Bool, hasOpenWindowBridge: Bool) -> Decision {
        if hasMainWindow { return .front }
        return hasOpenWindowBridge ? .openWindow : .reopen
    }

    /// The live `WindowGroup(id: "main")` window, set by `MainWindowRegistrar`
    /// (KnockApp.swift) once AppKit actually creates it, and cleared the
    /// moment it closes. An earlier version of this enum instead filtered
    /// `NSApp.windows` on `$0.identifier?.rawValue == mainWindowSceneID`:
    /// SwiftUI does not document that a `WindowGroup(id:)`'s `NSWindow.identifier`
    /// mirrors the id verbatim, and in this app it does not - that lookup
    /// never matched, so `hasMainWindow` was always false (see the story's
    /// Choices ledger). A directly registered reference, the same pattern
    /// `OpaqueWhiteWindowBackground` already uses for the setup window, does
    /// not depend on that undocumented mapping, and - like that pattern -
    /// never uses `NSApp.windows.first` either (that fronted whichever
    /// window macOS happened to list first - usually the setup window, or
    /// nothing when only the menu bar item existed; see the story's report).
    fileprivate static weak var mainWindow: NSWindow?

    /// Every argument defaults to the real AppKit/SwiftUI behaviour; tests
    /// override them with recording fakes to exercise `decide` end to end
    /// without a real window server.
    static func showMainWindow(
        hasMainWindow: () -> Bool = { mainWindow != nil },
        front: () -> Void = { mainWindow?.makeKeyAndOrderFront(nil) },
        hasOpenWindowBridge: () -> Bool = { openMainWindowAction != nil },
        openWindow: (String) -> Void = { id in openMainWindowAction?(id) },
        reopen: () -> Void = {
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
        }
    ) {
        NSApplication.shared.activate()
        switch decide(hasMainWindow: hasMainWindow(), hasOpenWindowBridge: hasOpenWindowBridge()) {
        case .front:
            front()
        case .openWindow:
            openWindow(mainWindowSceneID)
        case .reopen:
            reopen()
        }
    }
}

/// Registers this root's `openWindow` environment action into
/// `AppActivation.openMainWindowAction` while it is alive, so
/// `AppActivation.showMainWindow()` can open the main window from AppKit
/// code that has no SwiftUI environment of its own. `KnockApp` embeds one of
/// these in the background of every live root (main window, setup window,
/// Settings): whichever root is alive can reach the same "main"
/// `WindowGroup`, so it does not matter which one actually opens it.
///
/// Keeps a small registry (not a single flag) keyed by each instance's own
/// id: two roots can be alive at once (e.g. the setup window still closing
/// while the main window appears), and one disappearing must hand the
/// bridge back to a still-live root rather than either clearing it early or
/// leaving it pointing at a torn-down root's closure. It only goes nil once
/// every registered root has disappeared (contract step 3, "no SwiftUI view
/// is alive").
struct MainWindowOpenBridge: View {
    @Environment(\.openWindow) private var openWindow
    private let instanceId = UUID()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { Self.register(instanceId, action: { id in openWindow(id: id) }) }
            .onDisappear { Self.unregister(instanceId) }
    }

    @MainActor
    private static var registrations: [(id: UUID, action: (String) -> Void)] = []

    @MainActor
    private static func register(_ id: UUID, action: @escaping (String) -> Void) {
        registrations.append((id, action))
        AppActivation.openMainWindowAction = action
    }

    @MainActor
    private static func unregister(_ id: UUID) {
        registrations.removeAll { $0.id == id }
        AppActivation.openMainWindowAction = registrations.last?.action
    }
}

/// Sets `AppActivation.mainWindow` to this root's own `NSWindow` once AppKit
/// creates it, and clears it again when that window closes. Lives in
/// `MainWindowView`'s background, mirroring how `OpaqueWhiteWindowBackground`
/// (OnboardingWindowView.swift) reaches the setup window's own `NSWindow`.
struct MainWindowRegistrar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in register(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        register(nsView.window)
    }

    private func register(_ window: NSWindow?) {
        guard let window, AppActivation.mainWindow !== window else { return }
        AppActivation.mainWindow = window
        Self.applyEvidenceWindowWidthIfNeeded(window)
        Self.scheduleEvidenceWindowShots(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if AppActivation.mainWindow === window {
                    AppActivation.mainWindow = nil
                }
            }
        }
    }

    /// `KNOCK_EVIDENCE_WINDOW_SHOT=<png path>[,<delay s>...]` (evidence-only,
    /// HAIL-79): draws this window's own content view to a PNG with
    /// `cacheDisplay`, once per delay (seconds after the window appears; no
    /// delay means one shot now). With several delays the file name gets a
    /// `-<delay>s` suffix. It never reads the screen or another app's
    /// windows, so it needs no Screen Recording permission.
    private static func scheduleEvidenceWindowShots(_ window: NSWindow) {
        guard let raw = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_WINDOW_SHOT"], !raw.isEmpty else { return }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let path = parts.first, !path.isEmpty else { return }
        let delays = parts.dropFirst().compactMap(Double.init)
        let base = URL(fileURLWithPath: path).deletingPathExtension().path
        for delay in delays.isEmpty ? [0] : delays {
            let file = URL(fileURLWithPath: delays.isEmpty ? path : "\(base)-\(delay)s.png")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let view = window?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
            }
        }
    }

    /// `KNOCK_EVIDENCE_WINDOW_WIDTH=<points>` (evidence-only, HAIL-49): resizes
    /// the main window to that width once, keeping its height and top-left
    /// origin. There is no accessibility permission in the evidence
    /// environment to drag a real resize, and HAIL-49's card needs a
    /// narrower window to show its preview reflow (amendment A1 evidence
    /// step "(b) again at a narrower window").
    private static func applyEvidenceWindowWidthIfNeeded(_ window: NSWindow) {
        // `<points>` resizes once. `<points>,<later points>,<seconds>` (0.1.55) resizes again after
        // that many seconds, to show a window that is widened after it was narrow.
        guard let raw = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_WINDOW_WIDTH"] else { return }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard let width = parts.first, width > 0 else { return }
        func resize(_ width: Double) {
            var frame = window.frame
            let top = frame.origin.y + frame.size.height
            frame.size.width = CGFloat(width)
            frame.origin.y = top - frame.size.height
            window.setFrame(frame, display: true)
        }
        resize(width)
        // `KNOCK_EVIDENCE_WINDOW_HEIGHT=<points>` (WAG-307): a taller window, for a page whose list runs below the fold.
        if let raw = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_WINDOW_HEIGHT"], let height = Double(raw), height > 0 {
            var frame = window.frame
            let top = frame.origin.y + frame.size.height
            frame.size.height = CGFloat(height)
            frame.origin.y = top - frame.size.height
            window.setFrame(frame, display: true)
        }
        if parts.count == 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[2]) { resize(parts[1]) }
        }
    }
}
