import SwiftUI

/// The toast's timer (HAIL-79), pure so tests can drive it. Hover pauses it.
/// The fade starts 2.5 s after delivery, or early enough that the toast is
/// gone by 5 s in total, whichever is first (C10: the status line keeps the state after that).
struct SentToastClock: Equatable, Sendable {
    static let cap: TimeInterval = 5
    /// The exit is 150 ms ease-out (docs/decisions/2026-11-11-ui-audit-batches.md).
    static let fadeDuration: TimeInterval = 0.15
    static let deliveredHold: TimeInterval = 2.5

    private(set) var elapsed: TimeInterval = 0
    private(set) var deliveredFor: TimeInterval?

    mutating func advance(by seconds: TimeInterval, isHovering: Bool, isDelivered: Bool) {
        guard !isHovering else { return }
        elapsed += seconds
        if isDelivered { deliveredFor = (deliveredFor ?? 0) + seconds }
    }

    var shouldFade: Bool {
        elapsed >= Self.cap - Self.fadeDuration || (deliveredFor ?? 0) >= Self.deliveredHold
    }
}

/// The copy and buttons of the toast for one phase (HAIL-79).
struct SentToastContent: Equatable {
    let headline: String
    let showsChangeAnswer: Bool

    init(phase: SentToast.Phase) {
        switch phase {
        case .queued:
            headline = "Sent · waiting for pickup"
            showsChangeAnswer = true
        case .delivered:
            headline = "Delivered · the agent has your answer"
            showsChangeAnswer = false
        case .failed:
            headline = "Not delivered · open the decision to retry"
            showsChangeAnswer = false
        }
    }

    func youLine(answer: String) -> String { answer.isEmpty ? "" : "You → \(answer)" }
}

/// The light "Sent" card in the list column, above the footer, so it covers no control of the
/// next request (HAIL-79, prototype variation 2). It follows the reply's delivery and fades itself.
struct SentToastView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var motion = MotionGate.shared
    @State private var isShown = false
    @State private var isHovering = false

    /// The card rises 8 pt from the footer as it fades in.
    private static let enterOffset: CGFloat = 8
    /// Ease-out, 280 ms: under the 300 ms limit.
    private static let enterAnimation = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.28)
    private static let exitAnimation = Animation.easeOut(duration: SentToastClock.fadeDuration)

    var body: some View {
        if let toast = model.sentToast {
            card(toast)
                .id(toast.id)
                .task(id: toast.id) { await run(toast) }
        }
    }

    private func card(_ toast: SentToast) -> some View {
        let phase = model.sentToastPhase
        let content = SentToastContent(phase: phase)
        let status: AgentStatus = phase == .delivered ? .connected : .waitingForPickup
        let youLine = content.youLine(answer: toast.answer)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                PixelStatusGrid(
                    pattern: phase == .queued ? status.pattern : .still(0.9),
                    color: phase == .failed ? Theme.Colors.accent : status.color, cell: 4
                )
                Text(content.headline)
                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    .foregroundColor(phase == .delivered ? Theme.Colors.ok : Theme.Colors.ink)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).lineLimit(1)
                if !youLine.isEmpty { Text(youLine).lineLimit(1) }
            }
            .knockTextStyle(Theme.Typography.recommendLine12w400)
            .foregroundColor(Theme.Colors.ink2)
            .padding(.leading, 21)
            HStack(spacing: 14) {
                Text("Go back")
                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    .foregroundColor(Theme.Colors.ink)
                    .contentShape(Rectangle())
                    .onTapGesture { model.goBackFromSentToast() }.pointerCursor()
                if content.showsChangeAnswer {
                    Text("Change answer")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                        .foregroundColor(Theme.Colors.ink3)
                        .contentShape(Rectangle())
                        .onTapGesture { model.changeAnswerFromSentToast() }.pointerCursor()
                }
            }
            .padding(.leading, 21)
            .padding(.top, 2)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: 340, alignment: .leading)
        .background(Theme.Colors.win)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Colors.line, lineWidth: 1))
        .shadow(
            color: Theme.Shadow.sentToast.color, radius: Theme.Shadow.sentToast.blur / 2,
            x: Theme.Shadow.sentToast.offset.width, y: Theme.Shadow.sentToast.offset.height
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .opacity(isShown ? 1 : 0)
        // Reduce Motion: the card only fades. It never moves.
        .offset(y: isShown || motion.reduceMotion ? 0 : Self.enterOffset)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }

    /// Fades in, ticks the clock, fades out, then removes the toast.
    private func run(_ toast: SentToast) async {
        isShown = false
        await Task.yield()
        withAnimation(Self.enterAnimation) { isShown = true }
        var clock = SentToastClock()
        let step: TimeInterval = 0.1
        while !clock.shouldFade {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            clock.advance(by: step, isHovering: isHovering, isDelivered: model.sentToastPhase == .delivered)
        }
        withAnimation(Self.exitAnimation) { isShown = false }
        try? await Task.sleep(for: .seconds(SentToastClock.fadeDuration))
        if Task.isCancelled { return }
        model.dismissSentToast(id: toast.id)
    }
}
