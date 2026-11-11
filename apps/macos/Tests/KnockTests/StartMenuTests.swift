import Foundation
import Testing
@testable import Knock

// WAG-278: the shorter Start menu. Pure layout tests: no app opens, no CLI runs.

@MainActor
struct StartMenuTests {
    /// Terminal and both CLIs work; the apps, Superset, Conductor and T3 Code do not.
    private var bare: LaunchAvailability {
        var a = LaunchAvailability(claudeTerminal: true, codexTerminal: true, claudeApp: false, codexApp: false)
        a.superset = .blocked(.signIn)
        a.conductor = false
        a.t3 = .blocked(.connectT3)
        return a
    }

    @Test func allUsableKeepsPlaceOrderAndFoldsNothing() {
        let layout = StartMenuLayout.make(agent: .claude, availability: .allAvailable)
        #expect(layout.usable.map(\.place) == [.terminal, .app, .superset, .conductor, .t3])
        #expect(layout.setup.isEmpty)
        #expect(layout.foldTitle == nil)
        #expect(layout.usable.map(\.title) == ["Terminal", "Claude app", "Superset", "Conductor", "T3 Code"])
    }

    @Test func usableComesFirstAndTheRestFold() {
        var a = LaunchAvailability.allAvailable
        a.superset = .blocked(.signIn)
        let layout = StartMenuLayout.make(agent: .claude, availability: a)
        #expect(layout.usable.map(\.place) == [.terminal, .app, .conductor, .t3])
        #expect(layout.setup.map(\.place) == [.superset])
        #expect(layout.foldTitle == "1 more place to set up")
    }

    @Test func foldsPerAgentWithTheirReasons() {
        var a = bare
        a.claudeApp = true
        let claude = StartMenuLayout.make(agent: .claude, availability: a)
        #expect(claude.usable.map(\.title) == ["Terminal", "Claude app"])
        #expect(claude.setup.map(\.place) == [.superset, .conductor, .t3])
        #expect(claude.foldTitle == "3 more places to set up")
        #expect(claude.setup.map(\.reason) == ["Sign in to Superset first", "Not on this Mac", "Connect T3 Code in Settings"])

        let codex = StartMenuLayout.make(agent: .codex, availability: a)
        #expect(codex.usable.map(\.title) == ["Terminal"])
        #expect(codex.setup.map(\.title) == ["Codex app", "Superset", "Conductor", "T3 Code"])
        #expect(codex.setup.first?.reason == "Not on this Mac")
    }

    @Test func aMissingCLIFoldsTerminalWithItsOwnReason() {
        var a = bare
        a.codexTerminal = false
        let codex = StartMenuLayout.make(agent: .codex, availability: a)
        #expect(codex.setup.first { $0.place == .terminal }?.reason == "Codex not found on this Mac")
        #expect(StartMenuLayout.make(agent: .claude, availability: a).usable.map(\.place) == [.terminal])
    }

    @Test func aGreyedT3RowNamesThePlaceNotJustTheAgent() {
        let setup = StartMenuLayout.make(agent: .claude, availability: bare).setup
        let t3 = setup.first { $0.place == .t3 }
        #expect(t3?.title == "T3 Code")
        #expect(t3?.reason == "Connect T3 Code in Settings")
    }

    @Test func conductorSaysItFillsThePromptIn() {
        let row = StartMenuLayout.make(agent: .codex, availability: .allAvailable).usable.first { $0.place == .conductor }
        #expect(row?.subtitle == "Prompt filled in, you press Enter")
        #expect(StartMenuLayout.make(agent: .codex, availability: .allAvailable).usable.first?.subtitle == nil)
    }

    @Test func switchingAgentKeepsAUsablePlace() {
        var a = LaunchAvailability.allAvailable
        a.codexApp = false
        #expect(LaunchTarget.claudeSuperset.switching(to: .codex, availability: a) == .codexSuperset)
        #expect(LaunchTarget.codexT3.switching(to: .claude, availability: a) == .claudeT3)
        #expect(LaunchTarget.conductor.switching(to: .codex, availability: a) == .conductor)
    }

    @Test func switchingAgentFallsBackToTerminalWhenThePlaceCannotWork() {
        var a = LaunchAvailability.allAvailable
        a.codexApp = false
        #expect(LaunchTarget.claudeApp.switching(to: .codex, availability: a) == .codexTerminal)
        #expect(LaunchTarget.codexApp.switching(to: .claude, availability: a) == .claudeApp)
    }

    @Test func targetMappingRoundTrips() {
        for target in LaunchTarget.allCases {
            guard let agent = target.agent else { #expect(target == .conductor); continue }
            #expect(LaunchTarget.target(agent: agent, place: target.place) == target)
        }
    }

    @Test func sessionsSubmenuListsWorkingFirst() {
        func option(_ id: String, working: Bool) -> DocumentSendOption {
            DocumentSendOption(target: .session(id), name: id, isWorking: working, folder: nil)
        }
        let ordered = StartMenuSessions.ordered([option("a", working: false), option("b", working: true), option("c", working: false), option("d", working: true)])
        #expect(ordered.map(\.name) == ["b", "d", "a", "c"])
        #expect(StartMenuSessions.countText(1) == "1 session")
        #expect(StartMenuSessions.countText(4) == "4 sessions")
    }

    @Test func setUpRoutesToThePlacesOwnCard() {
        #expect(StartMenuSettingsRoute.card(for: .superset, agent: .claude) == .superset)
        #expect(StartMenuSettingsRoute.card(for: .conductor, agent: .codex) == .conductor)
        #expect(StartMenuSettingsRoute.card(for: .t3, agent: .codex) == .t3)
        #expect(StartMenuSettingsRoute.card(for: .app, agent: .claude) == .claudeApp)
        #expect(StartMenuSettingsRoute.card(for: .app, agent: .codex) == .codexApp)
        #expect(StartMenuSettingsRoute.card(for: .terminal, agent: .codex) == .runtimes)
        #expect(StartMenuSettingsRoute.card(for: nil, agent: .claude) == .runtimes)
    }

    @Test func routerSetsTheCardAndShowsTheAgentsPage() {
        let center = NotificationCenter()
        var shown = 0
        let token = center.addObserver(forName: .knockShowAgentsSettings, object: nil, queue: nil) { _ in shown += 1 }
        defer { center.removeObserver(token) }
        let router = SettingsRouter()
        router.show(.superset, center: center)
        #expect(router.card == .superset)
        #expect(shown == 1)
    }

    @Test func menuCopyHasNoEmDashes() {
        let texts = [AgentPlaceCopy.claudeApp, AgentPlaceCopy.claudeAppConnected, AgentPlaceCopy.codexPlugin,
                     AgentPlaceCopy.superset, AgentPlaceCopy.conductor, StartMenuSettingsRoute.footerTitle]
        #expect(texts.allSatisfy { !$0.contains("\u{2014}") })
    }
}
