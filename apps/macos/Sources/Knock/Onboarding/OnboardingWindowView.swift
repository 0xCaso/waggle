import AppKit
import SwiftUI

/// The short setup window (WAG-338): two steps, "Connect your agent" and "What are you working on?". The
/// window is an opaque white `NSWindow` sized to its own content, no titlebar, no separate inner panel
/// border/shadow (see `OpaqueWhiteWindowBackground`). Only the content inside switches, over `model.screen`.
struct OnboardingWindowView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        // The TEST COPY strip sits on every Waggle window, this one too
        // (docs/stories/HAIL-34.md, operator report 21:51).
        VStack(spacing: 0) {
            TestCopyStripView()
            OnboardingCardView(model: model)
        }
            .background(OpaqueWhiteWindowBackground())
            .task {
                model.start()
                await Self.writeEvidenceShotIfRequested()
            }
    }

    /// `KNOCK_EVIDENCE_SETUP_SHOT=<png path>[,<delay s>]` (evidence only, HAIL-82): a few
    /// seconds after the setup window shows, draws its own content view to
    /// that path with `cacheDisplay`. It never reads the screen, so it needs
    /// no Screen Recording permission and cannot record another app.
    @MainActor
    private static func writeEvidenceShotIfRequested() async {
        guard let raw = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_SETUP_SHOT"], !raw.isEmpty else { return }
        // `<png path>[,<delay s>]`: a slow on-demand daemon start needs longer than 4 s.
        let parts = raw.split(separator: ",", maxSplits: 1).map(String.init)
        let path = parts[0]
        let delay = parts.count > 1 ? Double(parts[1]) ?? 4 : 4
        try? await Task.sleep(for: .seconds(delay))
        guard let view = NSApp.windows.first(where: { $0.title == onboardingWindowTitle })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Paints the hosting `NSWindow` itself `Theme.Colors.win` (opaque), rather
/// than leaving it transparent behind a smaller floating SwiftUI "card": a
/// transparent window sized to the card's own `.shadow()` reports that
/// shadow's blur/offset as part of its ideal size to
/// `.windowResizability(.contentSize)`, so the window ends up visibly larger
/// than the card. Painting the window itself white and letting content run
/// to its edges removes that gap outright (KNOCK-15 fold passes 2-3).
private struct OpaqueWhiteWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in configure(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        window.backgroundColor = NSColor(Theme.Colors.win)
        window.hasShadow = true
    }
}

private struct OnboardingCardView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        // The window itself is the card: the content runs to its own edges.
        VStack(alignment: .leading, spacing: 16) {
            // Step 1 names itself once, in its title: no pills above it.
            if model.screen != .connect { OnboardingProgressRow(current: model.screen.step) }
            Group {
                switch model.screen {
                case .connect:
                    OnboardingConnectView(model: model)
                case .firstJob:
                    OnboardingFirstJobView(model: model)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(EdgeInsets(top: 36, leading: 32, bottom: 24, trailing: 32))
        .frame(width: Theme.Spacing.setupWindowWidth, height: OnboardingWindowLayout.height)
        .background(Theme.Colors.win)
    }
}

/// The two pills over the header: where you are, and what is done.
struct OnboardingProgressRow: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in pill(step) }
        }
    }

    private func pill(_ step: OnboardingStep) -> some View {
        let isCurrent = step == current
        let isDone = step.rawValue < current.rawValue
        return HStack(spacing: 6) {
            ZStack {
                Circle().fill(isDone ? Theme.Colors.ok : isCurrent ? Theme.Colors.win : Theme.Colors.side)
                if isDone {
                    Image(systemName: "checkmark").font(Theme.Typography.tickMark.font).foregroundColor(Theme.Colors.win)
                } else {
                    Text("\(step.rawValue)")
                        .knockTextStyle(Theme.Typography.tagLabel10_5w500)
                        .foregroundColor(Theme.Colors.ink)
                }
            }
            .frame(width: Theme.Spacing.pinLarge - 2, height: Theme.Spacing.pinLarge - 2)
            Text(step.pillTitle)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(isCurrent ? Theme.Colors.win : Theme.Colors.ink2)
        }
        .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 10))
        .background(Capsule().fill(isCurrent ? Theme.Colors.ink : Theme.Colors.win))
        .overlay(Capsule().stroke(isCurrent ? Theme.Colors.ink : Theme.Colors.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.pillTitle)\(isDone ? ", done" : isCurrent ? ", current step" : "")")
    }
}

enum OnboardingWindowLayout {
    /// Both steps share one height, so the window does not jump between them.
    static let height: CGFloat = 660
}
