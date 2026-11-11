import Foundation
import Testing
@testable import Knock

/// The one "paused" state (audit batch, task 4): the card's words, the footer's words, and the start.
@MainActor
struct PausedCardTests {
    private let banned = ["daemon", "cached", "socket", "waggle_ask", "offline", "log", "—"]

    @Test func pausedCardSaysWhyAndWhatTheButtonDoes() {
        let card = PausedCopy.card(.paused)
        #expect(card.title == "Waggle is paused")
        #expect(card.line == "Agents can't reach you right now. Start Waggle to let them ask again.")
        #expect(card.button == "Start Waggle")
        #expect(!card.isWorking)
    }

    @Test func startingCardShowsAWorkingButton() {
        let card = PausedCopy.card(.starting)
        #expect(card.title == "Waggle is paused")
        #expect(card.line == "Starting Waggle. This takes a few seconds.")
        #expect(card.button == "Starting")
        #expect(card.isWorking)
    }

    @Test func failedStartSaysSoAndOffersTheButtonAgain() {
        let card = PausedCopy.card(.startFailed)
        #expect(card.line == "Waggle did not start. Try again.")
        #expect(card.button == "Try again")
        #expect(!card.isWorking)
    }

    @Test func footerSaysPausedNeverConnected() {
        #expect(PausedCopy.footer(.paused) == "Paused")
        #expect(PausedCopy.footer(.starting) == "Starting")
        #expect(PausedCopy.footer(.startFailed) == "Paused")
        #expect(QueueFooterStatus.label(isOffline: true, phase: .starting, sessionCount: 4) == "Starting")
        #expect(QueueFooterStatus.label(isOffline: true, phase: .paused, sessionCount: 4) == "Paused")
    }

    @Test func noStateUsesAnInternalWord() {
        let texts = [PausedCopy.Phase.paused, .starting, .startFailed].flatMap { phase -> [String] in
            let card = PausedCopy.card(phase)
            return [card.title, card.line, card.button, PausedCopy.footer(phase)]
        } + [PausedCopy.answerLine]
        for text in texts {
            for word in banned { #expect(!text.lowercased().contains(word), "\"\(text)\" has \"\(word)\"") }
        }
    }

    @Test func answerLineGivesTheReason() {
        #expect(PausedCopy.answerLine == "Paused. Start Waggle to answer.")
    }

    // MARK: the start

    @Test func startReachesTheServiceAndLeavesPaused() async {
        var checks = 0
        let starter = ServiceStarter(launch: { true }, timeout: 30, pollInterval: 0.01)
        await starter.start(isReachable: { checks += 1; return checks >= 3 })
        #expect(starter.phase == .paused)
        #expect(checks >= 3)
    }

    @Test func phaseIsStartingWhileItWaits() async {
        let starter = ServiceStarter(launch: { true }, timeout: 30, pollInterval: 0.01)
        var seen: [PausedCopy.Phase] = []
        await starter.start(isReachable: { seen.append(starter.phase); return seen.count >= 2 })
        #expect(seen.allSatisfy { $0 == .starting })
    }

    @Test func aLaunchThatFailsShowsTheFailureAtOnce() async {
        var checked = false
        let starter = ServiceStarter(launch: { false }, timeout: 30, pollInterval: 0.01)
        await starter.start(isReachable: { checked = true; return true })
        #expect(starter.phase == .startFailed)
        #expect(!checked)
    }

    @Test func aServiceThatNeverAnswersFailsAtTheDeadlineAndCanBePressedAgain() async {
        var launches = 0
        let starter = ServiceStarter(launch: { launches += 1; return true }, timeout: 0.1, pollInterval: 0.01)
        await starter.start(isReachable: { false })
        #expect(starter.phase == .startFailed)
        await starter.start(isReachable: { true })
        #expect(starter.phase == .paused)
        #expect(launches == 2)
    }
}
